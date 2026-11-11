#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 执行一段可能抛 ObjC 异常的代码（AVFoundation 在参数不合法时会抛
/// NSInvalidArgumentException，Swift 的 do/catch 接不住，只能靠 @try/@catch）。
/// 返回 YES 表示正常跑完，NO 表示被 catch（原因会打到控制台）。
FOUNDATION_EXPORT BOOL PLTryCatch(void (^block)(void));

NS_ASSUME_NONNULL_END
