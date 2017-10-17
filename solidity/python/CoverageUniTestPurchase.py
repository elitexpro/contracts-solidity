import InputGenerator
import FormulaSolidityPort
import FormulaNativePython


MINIMUM_VALUE_SUPPLY  = 100
MAXIMUM_VALUE_SUPPLY  = 10**34
SAMPLES_COUNT_SUPPLY  = 150


MINIMUM_VALUE_BALANCE = 100
MAXIMUM_VALUE_BALANCE = 10**34
SAMPLES_COUNT_BALANCE = 150


MINIMUM_VALUE_RATIO   = 100000
MAXIMUM_VALUE_RATIO   = 900000
SAMPLES_COUNT_RATIO   = 10


MINIMUM_VALUE_AMOUNT  = 1
MAXIMUM_VALUE_AMOUNT  = 10**34
SAMPLES_COUNT_AMOUNT  = 150


def Main():    
    range_supply  = InputGenerator.UniformDistribution(MINIMUM_VALUE_SUPPLY ,MAXIMUM_VALUE_SUPPLY ,SAMPLES_COUNT_SUPPLY )
    range_balance = InputGenerator.UniformDistribution(MINIMUM_VALUE_BALANCE,MAXIMUM_VALUE_BALANCE,SAMPLES_COUNT_BALANCE)
    range_ratio   = InputGenerator.UniformDistribution(MINIMUM_VALUE_RATIO  ,MAXIMUM_VALUE_RATIO  ,SAMPLES_COUNT_RATIO  )
    range_amount  = InputGenerator.UniformDistribution(MINIMUM_VALUE_AMOUNT ,MAXIMUM_VALUE_AMOUNT ,SAMPLES_COUNT_AMOUNT )
    
    testNum = 0
    numOfTests = len(range_supply)*len(range_balance)*len(range_ratio)*len(range_amount)
    
    worstAbsoluteLoss = Record(range_supply[0],range_balance[0],range_ratio[0],range_amount[0],0,0.0)
    worstRelativeLoss = Record(range_supply[0],range_balance[0],range_ratio[0],range_amount[0],0,0.0)
    
    failureTransactionCount = 0
    invalidTransactionCount = 0
    
    try:
        for             supply  in range_supply :
            for         balance in range_balance:
                for     ratio   in range_ratio  :
                    for amount  in range_amount :
                        testNum += 1
                        if True:
                            resultSolidityPort = Run(FormulaSolidityPort,supply,balance,ratio,amount)
                            resultNativePython = Run(FormulaNativePython,supply,balance,ratio,amount)
                            if resultNativePython < 0:
                                invalidTransactionCount += 1
                            elif resultSolidityPort < 0:
                                failureTransactionCount += 1
                            elif resultNativePython < resultSolidityPort:
                                print 'Implementation Error:',Record(supply,balance,ratio,amount,resultSolidityPort,resultNativePython)
                                return
                            else: # 0 <= resultSolidityPort <= resultNativePython
                                absoluteLoss = resultNativePython-resultSolidityPort
                                relativeLoss = 1-resultSolidityPort/resultNativePython
                                worstAbsoluteLoss.Update(supply,balance,ratio,amount,resultSolidityPort,resultNativePython,absoluteLoss,relativeLoss)
                                worstRelativeLoss.Update(supply,balance,ratio,amount,resultSolidityPort,resultNativePython,relativeLoss,absoluteLoss)
                                worstAbsoluteLossStr = 'worstAbsoluteLoss = {:.0f} (relativeLoss = {:.0f}%)'.format(worstAbsoluteLoss.major,worstAbsoluteLoss.minor*100)
                                worstRelativeLossStr = 'worstRelativeLoss = {:.0f}% (absoluteLoss = {:.0f})'.format(worstRelativeLoss.major*100,worstRelativeLoss.minor)
                                print 'Test {} out of {}: {}, {}'.format(testNum,numOfTests,worstAbsoluteLossStr,worstRelativeLossStr)
    except KeyboardInterrupt:
        print 'Process aborted by user request'
    
    print 'worstAbsoluteLoss:',worstAbsoluteLoss
    print 'worstRelativeLoss:',worstRelativeLoss
    
    print 'failureTransactionCount:',failureTransactionCount
    print 'invalidTransactionCount:',invalidTransactionCount


def Run(module,supply,balance,ratio,amount):
    try:
        return module.calculatePurchaseReturn(supply,balance,ratio,amount)
    except Exception:
        return -1


class Record():
    def __init__(self,supply,balance,ratio,amount,resultSolidityPort,resultNativePython,major=0.0,minor=0.0):
        self._set(supply,balance,ratio,amount,resultSolidityPort,resultNativePython,major,minor)
    def __str__(self):
        return ''.join(['\n\t{} = {}'.format(var,vars(self)[var]) for var in 'supply,balance,ratio,amount,resultSolidityPort,resultNativePython'.split(',')])
    def Update(self,supply,balance,ratio,amount,resultSolidityPort,resultNativePython,major,minor):
        if self.major < major or (self.major == major and self.minor < minor):
            self._set(supply,balance,ratio,amount,resultSolidityPort,resultNativePython,major,minor)
    def _set(self,supply,balance,ratio,amount,resultSolidityPort,resultNativePython,major,minor):
        self.__dict__.update({key:val for key,val in locals().iteritems() if key != 'self'})


Main()
