#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "SpicyLyricsNativeControls.h"

extern void *SpicyQAMakeSwiftSmartShuffle(void);

static void require(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}

@protocol QASmartShuffle
@property NSInteger mode;
@property BOOL offeredPicker;
@property BOOL rejectChange;
@property NSUInteger explicitCalls;
@end

@interface FakeSmartShuffle : NSObject <QASmartShuffle>
@property NSInteger mode;
@property BOOL offeredPicker;
@property BOOL rejectChange;
@property NSUInteger explicitCalls;
@property BOOL staleSmartFlag;
@property BOOL staleEntityMode;
@end
@implementation FakeSmartShuffle
- (BOOL)checkIsEntitySmartShuffled:(NSURL *)url { return self.staleSmartFlag || self.mode == 2; }
- (NSUInteger)shuffleStateWithEntityURL:(NSURL *)url { return self.staleEntityMode ? 2 : self.mode; }
- (NSUInteger)shuffleStateWithPlayerState:(id)state { return self.mode; }
- (void)setShuffleState:(NSUInteger)mode for:(NSURL *)url showConfirmationUI:(BOOL)confirmation
    completion:(void (^)(NSInteger))completion {
    require([url.absoluteString isEqualToString:@"spotify:playlist:test"], @"shuffle context lost");
    self.offeredPicker = confirmation;
    self.explicitCalls += 1;
    if (!self.rejectChange) self.mode = mode;
    completion(self.rejectChange ? 1 : 0);
}
- (void)toggleNextShuffleStateForEntityURL:(NSURL *)url showConfirmationUI:(BOOL)confirmation
    showPickerUI:(BOOL)picker parentAbsoluteLocation:(id)location completion:(void (^)(NSInteger))completion {
    require([url.absoluteString isEqualToString:@"spotify:playlist:test"], @"shuffle context lost");
    self.offeredPicker = picker || confirmation;
    // Native's picker-disabled path does NOT offer Smart Shuffle.
    self.mode = self.mode == 0 ? 1 : 0;
    completion(0);
}
@end

@interface FakeState : NSObject
// Actual SPTPlayerState surface, not the similarly named contextURL elsewhere.
@property NSURL *contextURI;
@end
@implementation FakeState
@end

@interface FakeActions : NSObject
@property BOOL paused;
@property BOOL allowed;
@property BOOL pauseStateUnavailable;
@property BOOL smartUnavailable;
@property NSInteger trackNumber;
@property NSInteger repeatMode;
@property id<QASmartShuffle> smartShuffleHandler;
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
- (BOOL)isSmartShuffleSupported { return !self.smartUnavailable; }
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
        state.contextURI = [NSURL URLWithString:@"spotify:playlist:test"];
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
        require(actions.smartShuffleHandler.explicitCalls == 3, @"must use explicit native modes, not binary auto-toggle");
        actions.smartUnavailable = YES;
        require(EeveeSpicyPerformControl(@"toggleShuffle", state) == 1 && actions.smartShuffleHandler.mode == 1, @"regular shuffle available without smart");
        require(EeveeSpicyPerformControl(@"toggleShuffle", state) == 1 && actions.smartShuffleHandler.mode == 0, @"unsupported smart must not be selected");
        actions.smartUnavailable = NO;
        actions.smartShuffleHandler.rejectChange = YES;
        require(EeveeSpicyPerformControl(@"toggleShuffle", state) == 1, @"dispatch is distinct from async result");
        require(![EeveeSpicyReadControls(state)[@"smartShuffleEnabled"] boolValue], @"rejected mode must not be optimistically displayed");
        actions.smartShuffleHandler.rejectChange = NO;
        // Spotify owns a three-state answer for the current player snapshot.
        // Its entity recommendation flag can lag the completed mode change.
        // The presentation must not splice that flag into another snapshot.
        actions.smartShuffleHandler.mode = 0;
        ((FakeSmartShuffle *)actions.smartShuffleHandler).staleSmartFlag = YES;
        NSDictionary *settledOff = EeveeSpicyReadControls(state);
        require([settledOff[@"shuffleMode"] isEqual:@"off"]
                && [settledOff[@"shuffleEnabled"] isEqual:@NO]
                && [settledOff[@"smartShuffleEnabled"] isEqual:@NO],
                @"confirmed native Off must stay Off while an entity smart flag lags");
        ((FakeSmartShuffle *)actions.smartShuffleHandler).staleSmartFlag = NO;
        // Dispatch must use the same authoritative state as presentation. An
        // entity cache still reporting Smart after Off must not consume the
        // next click by asking for Off a second time.
        ((FakeSmartShuffle *)actions.smartShuffleHandler).staleEntityMode = YES;
        NSUInteger callsBeforeNext = actions.smartShuffleHandler.explicitCalls;
        require(EeveeSpicyPerformControl(@"toggleShuffle", state) == 1
                && actions.smartShuffleHandler.mode == 1
                && actions.smartShuffleHandler.explicitCalls == callsBeforeNext + 1,
                @"next click after confirmed Off must select Shuffle even while entity mode lags");
        ((FakeSmartShuffle *)actions.smartShuffleHandler).staleEntityMode = NO;
        actions.smartShuffleHandler.mode = 0;
        actions.allowed = NO;
        require(EeveeSpicyPerformControl(@"play", state) == 0 && actions.paused, @"restriction must reject resume");
        require(EeveeSpicyPerformControl(@"next", state) == 0 && actions.trackNumber == 0, @"restriction must reject skip");
        require(![EeveeSpicyReadControls(state)[@"canPause"] boolValue], @"restriction must reach renderer");
        require(EeveeSpicyPerformControl(@"seek", state) == -1, @"seek must keep its existing path");

        id<QASmartShuffle> swiftSmart = CFBridgingRelease(SpicyQAMakeSwiftSmartShuffle());
        require(![(id)swiftSmart isKindOfClass:NSObject.class], @"Swift boundary must not inherit NSObject");
        require(![(id)swiftSmart respondsToSelector:@selector(methodSignatureForSelector:)],
                @"Swift boundary must reproduce the missing reflection method");
        actions.smartShuffleHandler = swiftSmart;
        actions.allowed = YES;
        NSLog(@"Reading controls with Spotify-shaped native Swift handler");
        NSDictionary *swiftControls = EeveeSpicyReadControls(state);
        require([swiftControls[@"smartShuffleEnabled"] isEqual:@NO]
                && [swiftControls[@"smartShuffleAvailable"] isEqual:@YES],
                @"opening the song page must read native Swift controls without aborting");
        for (NSNumber *expected in @[@1, @2, @0]) {
            require(EeveeSpicyPerformControl(@"toggleShuffle", state) == 1,
                    @"native Swift shuffle dispatch must succeed");
            require(swiftSmart.mode == expected.integerValue, @"native Swift shuffle must cycle through all three modes");
            require([EeveeSpicyReadControls(state)[@"smartShuffleEnabled"] isEqual:@(expected.integerValue == 2)],
                    @"native Swift shuffle observation must confirm its actual mode");
        }
        require(!swiftSmart.offeredPicker && swiftSmart.explicitCalls == 3,
                @"native Swift mode setter must preserve direct, picker-free dispatch");
        actions.smartUnavailable = YES;
        require(EeveeSpicyPerformControl(@"toggleShuffle", state) == 1 && swiftSmart.mode == 1,
                @"native Swift handler must allow normal shuffle in unsupported contexts");
        require(EeveeSpicyPerformControl(@"toggleShuffle", state) == 1 && swiftSmart.mode == 0,
                @"native Swift handler must not select unsupported Smart Shuffle");
        actions.smartUnavailable = NO;
        swiftSmart.rejectChange = YES;
        require(EeveeSpicyPerformControl(@"toggleShuffle", state) == 1 && swiftSmart.mode == 0,
                @"native Swift rejection must not be interpreted as a successful state change");
        require([EeveeSpicyReadControls(state)[@"smartShuffleEnabled"] isEqual:@NO],
                @"rejected native Swift mode must stay unselected");
        swiftSmart.rejectChange = NO;
        state.contextURI = nil;
        require(!EeveeSpicyReadControls(state)[@"smartShuffleEnabled"]
                && EeveeSpicyPerformControl(@"toggleShuffle", state) == -1,
                @"missing context must leave Smart Shuffle unknown and unavailable");
        state.contextURI = [NSURL URLWithString:@"spotify:playlist:test"];
        actions.smartShuffleHandler = nil;
        require(!EeveeSpicyReadControls(state)[@"smartShuffleEnabled"]
                && EeveeSpicyPerformControl(@"toggleShuffle", state) == -1,
                @"missing native handler must remain nonfatal and unavailable");
        require([EeveeSpicyReadControls(state)[@"canPause"] isEqual:@YES],
                @"missing optional shuffle handler must not break other controls");
        NSLog(@"PASS native Swift read, three-state shuffle, unsupported context, rejection and missing handler");

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
