#import "HLSExceptionGuard.h"

bool HLSGuardExceptions(NSString *tag, void (^block)(void)) {
    @try {
        block();
        return true;
    } @catch (NSException *exception) {
        NSLog(@"[HG] HLS resource-loader swallowed %@ (%@): %@", exception.name,
              tag, exception.reason ?: @"no reason");
        return false;
    }
}
