#import <Foundation/Foundation.h>
#import <stdbool.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, swallowing any NSException. AVFCore throws NSInternalInconsistencyException
/// from `-[AVAssetResourceLoadingRequest finishLoadingWithError:]` when a request is finished
/// twice or after cancellation; the exception escapes the dispatch block on the loader queue and
/// terminates the process (std::terminate, SIGABRT). Swift cannot catch NSException, so the
/// guard lives here. Returns YES when the block ran cleanly. When an exception was swallowed,
/// NO is returned and `reasonOut` (if provided) receives "Name: reason" for reporting.
bool HLSGuardExceptions(NSString *tag, NSString * _Nullable * _Nullable reasonOut, void (^block)(void));

NS_ASSUME_NONNULL_END
