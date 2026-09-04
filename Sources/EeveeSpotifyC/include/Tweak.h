#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

void EeveeSBInvokeSeekDouble(id target, SEL selector, double argument);
void EeveeInvokeVoidNoArg(id target, SEL selector);
void EeveeInvokeBoolArg(id target, SEL selector, BOOL argument);
void EeveeInvokeObjectArg(id target, SEL selector, id _Nullable argument);
NSString *EeveeJBRootPath(NSString *path);

NS_ASSUME_NONNULL_END
