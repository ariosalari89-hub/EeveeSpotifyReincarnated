#import <Foundation/Foundation.h>
#import "Tweak.h"

// Metadata tests must not issue playback commands to the external player.
// Fail loudly if either unrelated command path is accidentally exercised.
void EeveeSBInvokeSeekDouble(id target, SEL selector, double argument) { abort(); }
void EeveeInvokeObjectArg(id target, SEL selector, id argument) { abort(); }
