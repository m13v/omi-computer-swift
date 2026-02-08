#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ObjCExceptionCatcher : NSObject

/// Executes the given block and catches any ObjC NSException.
/// Returns the exception if one was thrown, or nil on success.
+ (nullable NSException *)tryBlock:(void (NS_NOESCAPE ^)(void))block;

@end

NS_ASSUME_NONNULL_END
