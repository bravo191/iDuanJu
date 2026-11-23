#import <Foundation/Foundation.h>
#import <stdbool.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, swallowing any NSException. AVFCore throws NSInternalInconsistencyException
/// from `-[AVAssetResourceLoadingRequest finishLoadingWithError:]` when a request is finished
/// twice or after cancellation; the exception escapes the dispatch block on the loader queue and
/// terminates the process (std::terminate, SIGABRT). Swift cannot catch NSException, so the
/// guard lives here. The exception name and reason are logged with `tag` before returning.
/// Returns YES when the block ran cleanly, NO when an exception was swallowed.
bool HLSGuardExceptions(NSString *tag, void (^block)(void));

NS_ASSUME_NONNULL_END
