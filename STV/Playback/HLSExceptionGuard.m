#import "HLSExceptionGuard.h"

bool HLSGuardExceptions(NSString *tag, NSString * _Nullable * _Nullable reasonOut, void (^block)(void)) {
    @try {
        block();
        return true;
    } @catch (NSException *exception) {
        NSLog(@"[HG] HLS resource-loader swallowed %@ (%@): %@", exception.name,
              tag, exception.reason ?: @"no reason");
        if (reasonOut) {
            *reasonOut = [NSString stringWithFormat:@"%@: %@", exception.name,
                          exception.reason ?: @"no reason"];
        }
        return false;
    }
}
