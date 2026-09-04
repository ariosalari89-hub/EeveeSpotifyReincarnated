#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

void EeveeSpicyInstallPlaybackControls(void);
NSDictionary<NSString *, id> *EeveeSpicyReadControls(id _Nullable playerState);
// -1: no compatible native action; 0: rejected; 1: dispatched, not confirmed.
NSInteger EeveeSpicyPerformControl(NSString *command, id _Nullable playerState);
BOOL EeveeSpicySetBooleanOption(id target, SEL selector, BOOL value);

NS_ASSUME_NONNULL_END
