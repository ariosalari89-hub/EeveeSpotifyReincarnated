#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "SpicyLyricsNativeControls.h"

static void require(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}

@interface FakeSmartShuffle : NSObject
@property NSInteger mode;
@property BOOL offeredPicker;
@end
@implementation FakeSmartShuffle
- (BOOL)checkIsEntitySmartShuffled:(NSURL *)url { return self.mode == 2; }
- (void)toggleNextShuffleStateForEntityURL:(NSURL *)url showConfirmationUI:(BOOL)confirmation
    showPickerUI:(BOOL)picker parentAbsoluteLocation:(id)location completion:(void (^)(NSInteger))completion {
    require([url.absoluteString isEqualToString:@"spotify:playlist:test"], @"shuffle context lost");
    self.offeredPicker = picker || confirmation;
    self.mode = (self.mode + 1) % 3;
    completion(0);
}
@end

@interface FakeState : NSObject
@property NSURL *contextURL;
@end
@implementation FakeState
@end

@interface FakeActions : NSObject
@property BOOL paused;
@property BOOL allowed;
@property BOOL pauseStateUnavailable;
@property NSInteger trackNumber;
@property NSInteger repeatMode;
@property FakeSmartShuffle *smartShuffleHandler;
@end
@implementation FakeActions
- (BOOL)respondsToSelector:(SEL)selector {
    if (selector == @selector(isPaused) && self.pauseStateUnavailable) return NO;
    return [super respondsToSelector:selector];
}
- (id)model { return self; }
- (BOOL)isPaused { return self.paused; }
- (BOOL)isPausingAllowed { return self.allowed; }
- (BOOL)isResumingAllowed { return self.allowed; }
- (BOOL)isShufflingAllowed { return self.allowed; }
- (BOOL)isSkippingToNextTrackAllowed { return self.allowed; }
- (BOOL)isSkippingToPreviousTrackAllowed { return self.allowed; }
- (BOOL)isSmartShuffleSupported { return YES; }
- (void)playPause { self.paused = !self.paused; }
- (void)skipToNext { self.trackNumber += 1; }
- (void)skipToPrevious { self.trackNumber -= 1; }
- (void)toggleRepeat { self.repeatMode = (self.repeatMode + 1) % 3; }
@end

@interface BoolOptions : NSObject
@property BOOL enabled;
@end
@implementation BoolOptions
- (void)setPrimitive:(BOOL)value { self.enabled = value; }
- (void)setBoxed:(NSNumber *)value { self.enabled = value.boolValue; }
- (void)setWrongType:(double)value { abort(); }
- (void)setThrowing:(BOOL)value { [NSException raise:@"Unavailable" format:@"Not supported"]; }
@end

int main(void) {
    @autoreleasepool {
        Class cls = objc_allocateClassPair(FakeActions.class, "SPTNowPlayingPlaybackActionsHandlerImplementation", 0);
        objc_registerClassPair(cls);
        EeveeSpicyInstallPlaybackControls();
        FakeState *state = [FakeState new];
        state.contextURL = [NSURL URLWithString:@"spotify:playlist:test"];
        require(EeveeSpicyPerformControl(@"pause", state) == -1, @"missing native handler must be unavailable");
        FakeActions *actions = [cls new];
        actions.allowed = YES;
        actions.smartShuffleHandler = [FakeSmartShuffle new];
        [actions model]; // actual capture hook, no test-only setter

        require(EeveeSpicyPerformControl(@"pause", state) == 1 && actions.paused, @"pause must pause running audio");
        require(EeveeSpicyPerformControl(@"pause", state) == 1 && actions.paused, @"duplicate pause must not resume");
        require(EeveeSpicyPerformControl(@"play", state) == 1 && !actions.paused, @"play must resume paused audio");
        require(EeveeSpicyPerformControl(@"play", state) == 1 && !actions.paused, @"duplicate play must not pause");
        require(EeveeSpicyPerformControl(@"togglePlay", state) == 1 && actions.paused, @"toggle must invert playback");
        actions.pauseStateUnavailable = YES;
        require(EeveeSpicyPerformControl(@"play", state) == -1 && actions.paused, @"unknown playback state must not report success");
        actions.pauseStateUnavailable = NO;
        require(EeveeSpicyPerformControl(@"next", state) == 1 && actions.trackNumber == 1, @"next must reach actions");
        require(EeveeSpicyPerformControl(@"previous", state) == 1 && actions.trackNumber == 0, @"previous must reach actions");
        for (NSInteger expected = 1; expected <= 3; ++expected) {
            require(EeveeSpicyPerformControl(@"cycleRepeat", state) == 1, @"repeat dispatch failed");
            require(actions.repeatMode == expected % 3, @"repeat cycle failed");
            require(EeveeSpicyPerformControl(@"toggleShuffle", state) == 1, @"shuffle dispatch failed");
            require(actions.smartShuffleHandler.mode == expected % 3, @"shuffle cycle failed");
            NSDictionary *controls = EeveeSpicyReadControls(state);
            require([controls[@"smartShuffleEnabled"] boolValue] == (expected == 2), @"observed smart shuffle mismatch");
            require([controls[@"smartShuffleAvailable"] boolValue], @"native smart shuffle capability missing");
        }
        require(!actions.smartShuffleHandler.offeredPicker, @"lyrics must not open a picker behind its screen");
        actions.allowed = NO;
        require(EeveeSpicyPerformControl(@"play", state) == 0 && actions.paused, @"restriction must reject resume");
        require(EeveeSpicyPerformControl(@"next", state) == 0 && actions.trackNumber == 0, @"restriction must reject skip");
        require(![EeveeSpicyReadControls(state)[@"canPause"] boolValue], @"restriction must reach renderer");
        require(EeveeSpicyPerformControl(@"seek", state) == -1, @"seek must keep its existing path");

        BoolOptions *options = [BoolOptions new];
        for (NSNumber *value in @[@YES, @NO, @YES]) {
            require(EeveeSpicySetBooleanOption(options, @selector(setPrimitive:), value.boolValue), @"primitive BOOL dispatch failed");
            require(options.enabled == value.boolValue, @"primitive value corrupted");
            require(EeveeSpicySetBooleanOption(options, @selector(setBoxed:), !value.boolValue), @"boxed BOOL dispatch failed");
            require(options.enabled == !value.boolValue, @"boxed value corrupted");
        }
        require(!EeveeSpicySetBooleanOption(options, @selector(setWrongType:), YES), @"wrong ABI must be rejected");
        require(!EeveeSpicySetBooleanOption(options, @selector(setThrowing:), YES), @"native exception must not crash app");
        NSLog(@"PASS native control capture, pause/resume, skips, repeat, smart shuffle, restrictions and ABI");
    }
    return 0;
}
