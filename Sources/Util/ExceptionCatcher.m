#import "ExceptionCatcher.h"

NSError * _Nullable zvonCatchNSException(void (NS_NOESCAPE ^ block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSString *msg = exception.reason ?: exception.name ?: @"Audio error";
        return [NSError errorWithDomain:@"ZVON.ObjCException"
                                   code:0
                               userInfo:@{ NSLocalizedDescriptionKey: msg }];
    }
}
