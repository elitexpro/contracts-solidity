pragma solidity ^0.4.21;
import './interfaces/IBancorConverter.sol';
import './interfaces/IBancorFormula.sol';
import '../IBancorNetwork.sol';
import '../ContractIds.sol';
import '../utility/Managed.sol';
import '../utility/Utils.sol';
import '../utility/interfaces/IContractRegistry.sol';
import '../utility/interfaces/IContractFeatures.sol';
import '../token/SmartTokenController.sol';
import '../token/interfaces/ISmartToken.sol';
import '../token/interfaces/IEtherToken.sol';

/*
    Bancor Converter v0.9

    The Bancor version of the token converter, allows conversion between a smart token and other ERC20 tokens and between different ERC20 tokens and themselves.

    ERC20 connector balance can be virtual, meaning that the calculations are based on the virtual balance instead of relying on
    the actual connector balance. This is a security mechanism that prevents the need to keep a very large (and valuable) balance in a single contract.

    The converter is upgradable (just like any SmartTokenController).

    WARNING: It is NOT RECOMMENDED to use the converter with Smart Tokens that have less than 8 decimal digits
             or with very small numbers because of precision loss

    Open issues:
    - Front-running attacks are currently mitigated by the following mechanisms:
        - minimum return argument for each conversion provides a way to define a minimum/maximum price for the transaction
        - gas price limit prevents users from having control over the order of execution
        - gas price limit check can be skipped if the transaction comes from a trusted, whitelisted signer
      Other potential solutions might include a commit/reveal based schemes
    - Possibly add getters for the connector fields so that the client won't need to rely on the order in the struct
*/
contract BancorConverter is IBancorConverter, SmartTokenController, Managed, ContractIds {
    uint32 private constant MAX_WEIGHT = 1000000;
    uint32 private constant MAX_CONVERSION_FEE = 1000000;

    struct Connector {
        uint256 virtualBalance;         // connector virtual balance
        uint32 weight;                  // connector weight, represented in ppm, 1-1000000
        bool isVirtualBalanceEnabled;   // true if virtual balance is enabled, false if not
        bool isPurchaseEnabled;         // is purchase of the smart token enabled with the connector, can be set by the owner
        bool isSet;                     // used to tell if the mapping element is defined
    }

    string public version = '0.9';
    string public converterType = 'bancor';

    IContractRegistry public registry;                  // contract registry contract
    IWhitelist public conversionWhitelist;              // whitelist contract with list of addresses that are allowed to use the converter
    IERC20Token[] public connectorTokens;               // ERC20 standard token addresses
    IERC20Token[] public quickBuyPath;                  // conversion path that's used in order to buy the token with ETH
    mapping (address => Connector) public connectors;   // connector token addresses -> connector data
    uint32 private totalConnectorWeight = 0;            // used to efficiently prevent increasing the total connector weight above 100%
    uint32 public maxConversionFee = 0;                 // maximum conversion fee for the lifetime of the contract, represented in ppm, 0...1000000 (0 = no fee, 100 = 0.01%, 1000000 = 100%)
    uint32 public conversionFee = 0;                    // current conversion fee, represented in ppm, 0...maxConversionFee
    bool public conversionsEnabled = true;              // true if token conversions is enabled, false if not
    IERC20Token[] private convertPath;

    // triggered when a conversion between two tokens occurs (TokenConverter event)
    event Conversion(address indexed _fromToken,
        address indexed _toToken,
        address indexed _trader,
        uint256 _amount,
        uint256 _return,
        int256 _conversionFee,
        uint256 _currentPriceN,
        uint256 _currentPriceD
    );
    // triggered when the conversion fee is updated
    event ConversionFeeUpdate(uint32 _prevFee, uint32 _newFee);

    /**
        @dev constructor

        @param  _token              smart token governed by the converter
        @param  _registry           address of a contract registry contract
        @param  _maxConversionFee   maximum conversion fee, represented in ppm
        @param  _connectorToken     optional, initial connector, allows defining the first connector at deployment time
        @param  _connectorWeight    optional, weight for the initial connector
    */
    function BancorConverter(
        ISmartToken _token,
        IContractRegistry _registry,
        uint32 _maxConversionFee,
        IERC20Token _connectorToken,
        uint32 _connectorWeight
    )
        public
        SmartTokenController(_token)
        validAddress(_registry)
        validMaxConversionFee(_maxConversionFee)
    {
        registry = _registry;
        IContractFeatures features = IContractFeatures(registry.getAddress(ContractIds.CONTRACT_FEATURES));

        // initialize supported features
        if (features != address(0))
            features.enableFeatures(FEATURE_CONVERSION_WHITELIST, true);

        maxConversionFee = _maxConversionFee;

        if (_connectorToken != address(0))
            addConnector(_connectorToken, _connectorWeight, false);
    }

    // validates a connector token address - verifies that the address belongs to one of the connector tokens
    modifier validConnector(IERC20Token _address) {
        require(connectors[_address].isSet);
        _;
    }

    // validates a token address - verifies that the address belongs to one of the convertible tokens
    modifier validToken(IERC20Token _address) {
        require(_address == token || connectors[_address].isSet);
        _;
    }

    // validates maximum conversion fee
    modifier validMaxConversionFee(uint32 _conversionFee) {
        require(_conversionFee >= 0 && _conversionFee <= MAX_CONVERSION_FEE);
        _;
    }

    // validates conversion fee
    modifier validConversionFee(uint32 _conversionFee) {
        require(_conversionFee >= 0 && _conversionFee <= maxConversionFee);
        _;
    }

    // validates connector weight range
    modifier validConnectorWeight(uint32 _weight) {
        require(_weight > 0 && _weight <= MAX_WEIGHT);
        _;
    }

    // validates a conversion path - verifies that the number of elements is odd and that maximum number of 'hops' is 10
    modifier validConversionPath(IERC20Token[] _path) {
        require(_path.length > 2 && _path.length <= (1 + 2 * 10) && _path.length % 2 == 1);
        _;
    }

    // allows execution only when conversions aren't disabled
    modifier conversionsAllowed {
        assert(conversionsEnabled);
        _;
    }

    // allows execution by the BancorNetwork contract only
    modifier bancorNetworkOnly {
        IBancorNetwork bancorNetwork = IBancorNetwork(registry.getAddress(ContractIds.BANCOR_NETWORK));
        require(msg.sender == address(bancorNetwork));
        _;
    }

    /**
        @dev returns the number of connector tokens defined

        @return number of connector tokens
    */
    function connectorTokenCount() public view returns (uint16) {
        return uint16(connectorTokens.length);
    }

    /*
        @dev allows the owner to update the registry contract address

        @param _registry    address of a bancor converter registry contract
    */
    function setRegistry(IContractRegistry _registry)
        public
        ownerOnly
        validAddress(_registry)
        notThis(_registry)
    {
        registry = _registry;
    }

    /*
        @dev allows the owner to update & enable the conversion whitelist contract address
        when set, only addresses that are whitelisted are actually allowed to use the converter
        note that the whitelist check is actually done by the BancorNetwork contract

        @param _whitelist    address of a whitelist contract
    */
    function setConversionWhitelist(IWhitelist _whitelist)
        public
        ownerOnly
        notThis(_whitelist)
    {
        conversionWhitelist = _whitelist;
    }

    /*
        @dev allows the manager to update the quick buy path

        @param _path    new quick buy path, see conversion path format in the bancorNetwork contract
    */
    function setQuickBuyPath(IERC20Token[] _path)
        public
        ownerOnly
        validConversionPath(_path)
    {
        quickBuyPath = _path;
    }

    /*
        @dev allows the manager to clear the quick buy path
    */
    function clearQuickBuyPath() public ownerOnly {
        quickBuyPath.length = 0;
    }

    /**
        @dev returns the length of the quick buy path array

        @return quick buy path length
    */
    function getQuickBuyPathLength() public view returns (uint256) {
        return quickBuyPath.length;
    }

    /**
        @dev disables the entire conversion functionality
        this is a safety mechanism in case of a emergency
        can only be called by the manager

        @param _disable true to disable conversions, false to re-enable them
    */
    function disableConversions(bool _disable) public ownerOrManagerOnly {
        conversionsEnabled = !_disable;
    }

    /**
        @dev updates the current conversion fee
        can only be called by the manager

        @param _conversionFee new conversion fee, represented in ppm
    */
    function setConversionFee(uint32 _conversionFee)
        public
        ownerOrManagerOnly
        validConversionFee(_conversionFee)
    {
        emit ConversionFeeUpdate(conversionFee, _conversionFee);
        conversionFee = _conversionFee;
    }

    /*
        @dev returns the conversion fee amount for a given return amount

        @return conversion fee amount
    */
    function getConversionFeeAmount(uint256 _amount) public view returns (uint256) {
        return safeMul(_amount, conversionFee) / MAX_CONVERSION_FEE;
    }

    /**
        @dev defines a new connector for the token
        can only be called by the owner while the converter is inactive

        @param _token                  address of the connector token
        @param _weight                 constant connector weight, represented in ppm, 1-1000000
        @param _enableVirtualBalance   true to enable virtual balance for the connector, false to disable it
    */
    function addConnector(IERC20Token _token, uint32 _weight, bool _enableVirtualBalance)
        public
        ownerOnly
        inactive
        validAddress(_token)
        notThis(_token)
        validConnectorWeight(_weight)
    {
        require(_token != token && !connectors[_token].isSet && totalConnectorWeight + _weight <= MAX_WEIGHT); // validate input

        connectors[_token].virtualBalance = 0;
        connectors[_token].weight = _weight;
        connectors[_token].isVirtualBalanceEnabled = _enableVirtualBalance;
        connectors[_token].isPurchaseEnabled = true;
        connectors[_token].isSet = true;
        connectorTokens.push(_token);
        totalConnectorWeight += _weight;
    }

    /**
        @dev updates one of the token connectors
        can only be called by the owner

        @param _connectorToken         address of the connector token
        @param _weight                 constant connector weight, represented in ppm, 1-1000000
        @param _enableVirtualBalance   true to enable virtual balance for the connector, false to disable it
        @param _virtualBalance         new connector's virtual balance
    */
    function updateConnector(IERC20Token _connectorToken, uint32 _weight, bool _enableVirtualBalance, uint256 _virtualBalance)
        public
        ownerOnly
        validConnector(_connectorToken)
        validConnectorWeight(_weight)
    {
        Connector storage connector = connectors[_connectorToken];
        require(totalConnectorWeight - connector.weight + _weight <= MAX_WEIGHT); // validate input

        totalConnectorWeight = totalConnectorWeight - connector.weight + _weight;
        connector.weight = _weight;
        connector.isVirtualBalanceEnabled = _enableVirtualBalance;
        connector.virtualBalance = _virtualBalance;
    }

    /**
        @dev disables purchasing with the given connector token in case the connector token got compromised
        can only be called by the owner
        note that selling is still enabled regardless of this flag and it cannot be disabled by the owner

        @param _connectorToken  connector token contract address
        @param _disable         true to disable the token, false to re-enable it
    */
    function disableConnectorPurchases(IERC20Token _connectorToken, bool _disable)
        public
        ownerOnly
        validConnector(_connectorToken)
    {
        connectors[_connectorToken].isPurchaseEnabled = !_disable;
    }

    /**
        @dev returns the connector's virtual balance if one is defined, otherwise returns the actual balance

        @param _connectorToken  connector token contract address

        @return connector balance
    */
    function getConnectorBalance(IERC20Token _connectorToken)
        public
        view
        validConnector(_connectorToken)
        returns (uint256)
    {
        Connector storage connector = connectors[_connectorToken];
        return connector.isVirtualBalanceEnabled ? connector.virtualBalance : _connectorToken.balanceOf(this);
    }

    /**
        @dev returns the expected return for converting a specific amount of _fromToken to _toToken

        @param _fromToken  ERC20 token to convert from
        @param _toToken    ERC20 token to convert to
        @param _amount     amount to convert, in fromToken

        @return expected conversion return amount
    */
    function getReturn(IERC20Token _fromToken, IERC20Token _toToken, uint256 _amount) public view returns (uint256) {
        require(_fromToken != _toToken); // validate input

        // conversion between the token and one of its connectors
        if (_toToken == token)
            return getPurchaseReturn(_fromToken, _amount);
        else if (_fromToken == token)
            return getSaleReturn(_toToken, _amount);

        // conversion between 2 connectors
        uint256 purchaseReturnAmount = getPurchaseReturn(_fromToken, _amount);
        return getSaleReturn(_toToken, purchaseReturnAmount, safeAdd(token.totalSupply(), purchaseReturnAmount));
    }

    /**
        @dev returns the expected return for buying the token for a connector token

        @param _connectorToken  connector token contract address
        @param _depositAmount   amount to deposit (in the connector token)

        @return expected purchase return amount
    */
    function getPurchaseReturn(IERC20Token _connectorToken, uint256 _depositAmount)
        public
        view
        active
        validConnector(_connectorToken)
        returns (uint256)
    {
        Connector storage connector = connectors[_connectorToken];
        require(connector.isPurchaseEnabled); // validate input

        uint256 tokenSupply = token.totalSupply();
        uint256 connectorBalance = getConnectorBalance(_connectorToken);
        IBancorFormula formula = IBancorFormula(registry.getAddress(ContractIds.BANCOR_FORMULA));
        uint256 amount = formula.calculatePurchaseReturn(tokenSupply, connectorBalance, connector.weight, _depositAmount);

        // deduct the fee from the return amount
        uint256 feeAmount = getConversionFeeAmount(amount);
        return safeSub(amount, feeAmount);
    }

    /**
        @dev returns the expected return for selling the token for one of its connector tokens

        @param _connectorToken  connector token contract address
        @param _sellAmount      amount to sell (in the smart token)

        @return expected sale return amount
    */
    function getSaleReturn(IERC20Token _connectorToken, uint256 _sellAmount) public view returns (uint256) {
        return getSaleReturn(_connectorToken, _sellAmount, token.totalSupply());
    }

    /**
        @dev converts a specific amount of _fromToken to _toToken

        @param _fromToken  ERC20 token to convert from
        @param _toToken    ERC20 token to convert to
        @param _amount     amount to convert, in fromToken
        @param _minReturn  if the conversion results in an amount smaller than the minimum return - it is cancelled, must be nonzero

        @return conversion return amount
    */
    function convertInternal(IERC20Token _fromToken, IERC20Token _toToken, uint256 _amount, uint256 _minReturn) public bancorNetworkOnly returns (uint256) {
        require(_fromToken != _toToken); // validate input

        // conversion between the token and one of its connectors
        if (_toToken == token)
            return buy(_fromToken, _amount, _minReturn);
        else if (_fromToken == token)
            return sell(_toToken, _amount, _minReturn);

        // conversion between 2 connectors
        uint256 purchaseAmount = buy(_fromToken, _amount, 1);
        return sell(_toToken, purchaseAmount, _minReturn);
    }

    /**
        @dev converts a specific amount of _fromToken to _toToken

        @param _fromToken  ERC20 token to convert from
        @param _toToken    ERC20 token to convert to
        @param _amount     amount to convert, in fromToken
        @param _minReturn  if the conversion results in an amount smaller than the minimum return - it is cancelled, must be nonzero

        @return conversion return amount
    */
    function convert(IERC20Token _fromToken, IERC20Token _toToken, uint256 _amount, uint256 _minReturn) public returns (uint256) {
        convertPath = [_fromToken, token, _toToken];
        return quickConvert(convertPath, _amount, _minReturn);
    }

    /**
        @dev buys the token by depositing one of its connector tokens

        @param _connectorToken  connector token contract address
        @param _depositAmount   amount to deposit (in the connector token)
        @param _minReturn       if the conversion results in an amount smaller than the minimum return - it is cancelled, must be nonzero

        @return buy return amount
    */
    function buy(IERC20Token _connectorToken, uint256 _depositAmount, uint256 _minReturn)
        internal
        conversionsAllowed
        greaterThanZero(_minReturn)
        returns (uint256)
    {
        uint256 amount = getPurchaseReturn(_connectorToken, _depositAmount);
        require(amount != 0 && amount >= _minReturn); // ensure the trade gives something in return and meets the minimum requested amount

        // update virtual balance if relevant
        Connector storage connector = connectors[_connectorToken];
        if (connector.isVirtualBalanceEnabled)
            connector.virtualBalance = safeAdd(connector.virtualBalance, _depositAmount);

        // transfer _depositAmount funds from the caller in the connector token
        assert(_connectorToken.transferFrom(msg.sender, this, _depositAmount));
        // issue new funds to the caller in the smart token
        token.issue(msg.sender, amount);

        dispatchConversionEvent(_connectorToken, _depositAmount, amount, true);
        return amount;
    }

    /**
        @dev sells the token by withdrawing from one of its connector tokens

        @param _connectorToken  connector token contract address
        @param _sellAmount      amount to sell (in the smart token)
        @param _minReturn       if the conversion results in an amount smaller the minimum return - it is cancelled, must be nonzero

        @return sell return amount
    */
    function sell(IERC20Token _connectorToken, uint256 _sellAmount, uint256 _minReturn)
        internal
        conversionsAllowed
        greaterThanZero(_minReturn)
        returns (uint256)
    {
        require(_sellAmount <= token.balanceOf(msg.sender)); // validate input

        uint256 amount = getSaleReturn(_connectorToken, _sellAmount);
        require(amount != 0 && amount >= _minReturn); // ensure the trade gives something in return and meets the minimum requested amount

        uint256 tokenSupply = token.totalSupply();
        uint256 connectorBalance = getConnectorBalance(_connectorToken);
        // ensure that the trade will only deplete the connector if the total supply is depleted as well
        assert(amount < connectorBalance || (amount == connectorBalance && _sellAmount == tokenSupply));

        // update virtual balance if relevant
        Connector storage connector = connectors[_connectorToken];
        if (connector.isVirtualBalanceEnabled)
            connector.virtualBalance = safeSub(connector.virtualBalance, amount);

        // destroy _sellAmount from the caller's balance in the smart token
        token.destroy(msg.sender, _sellAmount);
        // transfer funds to the caller in the connector token
        // the transfer might fail if the actual connector balance is smaller than the virtual balance
        assert(_connectorToken.transfer(msg.sender, amount));

        dispatchConversionEvent(_connectorToken, _sellAmount, amount, false);
        return amount;
    }

    /**
        @dev converts the token to any other token in the bancor network by following a predefined conversion path
        note that when converting from an ERC20 token (as opposed to a smart token), allowance must be set beforehand

        @param _path        conversion path, see conversion path format in the BancorNetwork contract
        @param _amount      amount to convert from (in the initial source token)
        @param _minReturn   if the conversion results in an amount smaller than the minimum return - it is cancelled, must be nonzero

        @return tokens issued in return
    */
    function quickConvert(IERC20Token[] _path, uint256 _amount, uint256 _minReturn)
        public
        payable
        validConversionPath(_path)
        returns (uint256)
    {
        return quickConvertPrioritized(_path, _amount, _minReturn, 0x0, 0x0, 0x0, 0x0, 0x0);
    }

    /**
        @dev converts the token to any other token in the bancor network by following a predefined conversion path
        note that when converting from an ERC20 token (as opposed to a smart token), allowance must be set beforehand

        @param _path        conversion path, see conversion path format in the BancorNetwork contract
        @param _amount      amount to convert from (in the initial source token)
        @param _minReturn   if the conversion results in an amount smaller than the minimum return - it is cancelled, must be nonzero
        @param _block       if the current block exceeded the given parameter - it is cancelled
        @param _nonce       the nonce of the sender address
        @param _v           parameter that can be parsed from the transaction signature
        @param _r           parameter that can be parsed from the transaction signature
        @param _s           parameter that can be parsed from the transaction signature

        @return tokens issued in return
    */
    function quickConvertPrioritized(IERC20Token[] _path, uint256 _amount, uint256 _minReturn, uint256 _block, uint256 _nonce, uint8 _v, bytes32 _r, bytes32 _s)
        public
        payable
        validConversionPath(_path)
        returns (uint256)
    {
        IERC20Token fromToken = _path[0];
        IBancorNetwork bancorNetwork = IBancorNetwork(registry.getAddress(ContractIds.BANCOR_NETWORK));

        // we need to transfer the source tokens from the caller to the BancorNetwork contract,
        // so it can execute the conversion on behalf of the caller
        if (msg.value == 0) {
            // not ETH, send the source tokens to the BancorNetwork contract
            // if the token is the smart token, no allowance is required - destroy the tokens
            // from the caller and issue them to the BancorNetwork contract
            if (fromToken == token) {
                token.destroy(msg.sender, _amount); // destroy _amount tokens from the caller's balance in the smart token
                token.issue(bancorNetwork, _amount); // issue _amount new tokens to the BancorNetwork contract
            } else {
                // otherwise, we assume we already have allowance, transfer the tokens directly to the BancorNetwork contract
                assert(fromToken.transferFrom(msg.sender, bancorNetwork, _amount));
            }
        }

        // execute the conversion and pass on the ETH with the call
        return bancorNetwork.convertForPrioritized.value(msg.value)(_path, _amount, _minReturn, msg.sender, _block, _nonce, _v, _r, _s);
    }

    // deprecated, backward compatibility
    function change(IERC20Token _fromToken, IERC20Token _toToken, uint256 _amount, uint256 _minReturn) public returns (uint256) {
        return convertInternal(_fromToken, _toToken, _amount, _minReturn);
    }

    /**
        @dev utility, returns the expected return for selling the token for one of its connector tokens, given a total supply override

        @param _connectorToken  connector token contract address
        @param _sellAmount      amount to sell (in the smart token)
        @param _totalSupply     total token supply, overrides the actual token total supply when calculating the return

        @return sale return amount
    */
    function getSaleReturn(IERC20Token _connectorToken, uint256 _sellAmount, uint256 _totalSupply)
        private
        view
        active
        validConnector(_connectorToken)
        greaterThanZero(_totalSupply)
        returns (uint256)
    {
        Connector storage connector = connectors[_connectorToken];
        uint256 connectorBalance = getConnectorBalance(_connectorToken);
        IBancorFormula formula = IBancorFormula(registry.getAddress(ContractIds.BANCOR_FORMULA));
        uint256 amount = formula.calculateSaleReturn(_totalSupply, connectorBalance, connector.weight, _sellAmount);

        // deduct the fee from the return amount
        uint256 feeAmount = getConversionFeeAmount(amount);
        return safeSub(amount, feeAmount);
    }

    /**
        @dev helper, dispatches the Conversion event
        The function also takes the tokens' decimals into account when calculating the current price

        @param _connectorToken  connector token contract address
        @param _amount          amount purchased/sold (in the source token)
        @param _returnAmount    amount returned (in the target token)
        @param isPurchase       true if it's a purchase, false if it's a sale
    */
    function dispatchConversionEvent(IERC20Token _connectorToken, uint256 _amount, uint256 _returnAmount, bool isPurchase) private {
        Connector storage connector = connectors[_connectorToken];

        // calculate the new price using the simple price formula
        // price = connector balance / (supply * weight)
        // weight is represented in ppm, so multiplying by 1000000
        uint256 connectorAmount = safeMul(getConnectorBalance(_connectorToken), MAX_WEIGHT);
        uint256 tokenAmount = safeMul(token.totalSupply(), connector.weight);

        // normalize values
        uint8 tokenDecimals = token.decimals();
        uint8 connectorTokenDecimals = _connectorToken.decimals();
        if (tokenDecimals != connectorTokenDecimals) {
            if (tokenDecimals > connectorTokenDecimals)
                connectorAmount = safeMul(connectorAmount, 10 ** uint256(tokenDecimals - connectorTokenDecimals));
            else
                tokenAmount = safeMul(tokenAmount, 10 ** uint256(connectorTokenDecimals - tokenDecimals));
        }

        uint256 feeAmount = getConversionFeeAmount(_returnAmount);
        // ensure that the fee is capped at 255 bits to prevent overflow when converting it to a signed int
        assert(feeAmount <= 2 ** 255);

        if (isPurchase)
            emit Conversion(_connectorToken, token, msg.sender, _amount, _returnAmount, int256(feeAmount), connectorAmount, tokenAmount);
        else
            emit Conversion(token, _connectorToken, msg.sender, _amount, _returnAmount, int256(feeAmount), tokenAmount, connectorAmount);
    }

    /**
        @dev fallback, buys the smart token with ETH
        note that the purchase will use the price at the time of the purchase
    */
    function() payable public {
        quickConvert(quickBuyPath, msg.value, 1);
    }
}
