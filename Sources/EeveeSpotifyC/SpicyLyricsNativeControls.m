#import "SpicyLyricsNativeControls.h"
#import <objc/runtime.h>
#import <string.h>

// Capture the same actions object that Spotify supplies to its Now Playing UI.
// Never construct a second player or a detached actions model.
static __weak id playbackActions;
static NSObject *captureLock;

static const char *unqualified(const char *type) {
    while (type && *type && strchr("rnNoORV", *type)) ++type;
    return type;
}

static BOOL isObject(const char *type) {
    return type && unqualified(type)[0] == '@';
}

static BOOL isBool(const char *type) {
    return type && (strcmp(unqualified(type), @encode(BOOL)) == 0
        || strcmp(unqualified(type), "B") == 0 || strcmp(unqualified(type), "c") == 0);
}

static NSInvocation *invocation(id target, SEL selector, NSUInteger count) {
    if (!target || ![target respondsToSelector:selector]) return nil;
    // Native Swift root classes expose Objective-C methods without NSObject's
    // methodSignatureForSelector:. Sending it aborts inside SwiftObject (not a
    // catchable NSException). Obtain the ABI from the concrete runtime method.
    Method method = class_getInstanceMethod(object_getClass(target), selector);
    const char *types = method ? method_getTypeEncoding(method) : NULL;
    if (!types || !*types) return nil;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:types];
    if (!signature || signature.numberOfArguments != count + 2) return nil;
    NSInvocation *call = [NSInvocation invocationWithMethodSignature:signature];
    call.target = target;
    call.selector = selector;
    return call;
}

static id readObject(id target, NSString *selectorName) {
    NSInvocation *call = invocation(target, NSSelectorFromString(selectorName), 0);
    if (!call || !isObject(call.methodSignature.methodReturnType)) return nil;
    [call invoke];
    __unsafe_unretained id result = nil;
    [call getReturnValue:&result];
    return result;
}

static NSNumber *readBool(id target, NSString *selectorName, id argument, BOOL takesArgument) {
    NSInvocation *call = invocation(target, NSSelectorFromString(selectorName), takesArgument ? 1 : 0);
    if (!call || !isBool(call.methodSignature.methodReturnType)) return nil;
    if (takesArgument) {
        if (!isObject([call.methodSignature getArgumentTypeAtIndex:2])) return nil;
        [call setArgument:&argument atIndex:2];
    }
    [call invoke];
    BOOL result = NO;
    [call getReturnValue:&result];
    return @(result);
}

static NSNumber *readShuffleState(id target, NSString *selectorName, id argument) {
    if (!argument) return nil;
    NSInvocation *call = invocation(target, NSSelectorFromString(selectorName), 1);
    if (!call || strcmp(unqualified(call.methodSignature.methodReturnType), "Q") != 0
        || !isObject([call.methodSignature getArgumentTypeAtIndex:2])) return nil;
    [call setArgument:&argument atIndex:2];
    [call invoke];
    NSUInteger mode = 0;
    [call getReturnValue:&mode];
    return mode <= 2 ? @(mode) : nil;
}

static id currentActions(void) {
    @synchronized(captureLock) { return playbackActions; }
}

static id shuffleContext(id state) {
    // SPTPlayerState uses contextURI. contextURL exists on other app objects,
    // but asking only for that makes this adapter silently fall back to binary shuffle.
    return readObject(state, @"contextURI") ?: readObject(state, @"contextURL");
}

static void capture(id candidate) {
    if (![candidate respondsToSelector:NSSelectorFromString(@"playPause")]
        || ![candidate respondsToSelector:NSSelectorFromString(@"toggleRepeat")]) return;
    @synchronized(captureLock) { playbackActions = candidate; }
}

static void captureObjectMethod(NSString *className, NSString *selectorName, BOOL returnedObject) {
    Class cls = NSClassFromString(className);
    SEL selector = NSSelectorFromString(selectorName);
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 2) return;
    char *returnType = method_copyReturnType(method);
    BOOL compatible = isObject(returnType);
    free(returnType);
    if (!compatible) return;
    IMP original = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^id(id target) {
        id result = ((id (*)(id, SEL))original)(target, selector);
        capture(returnedObject ? result : target);
        return result;
    });
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) {
        method_setImplementation(method, replacement);
    }
}

void EeveeSpicyInstallPlaybackControls(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        captureLock = [NSObject new];
        captureObjectMethod(@"NowPlaying_ViewImpl.NowPlayingServiceImplementation",
                            @"providePlaybackActionsHandler", YES);
        captureObjectMethod(@"NowPlaying_ViewImpl.SPTNowPlayingServiceImplementation",
                            @"providePlaybackActionsHandler", YES);
        // Some app configurations keep the provider behind Swift dispatch.
        // Its actions model is still read by Spotify's native control methods.
        captureObjectMethod(@"SPTNowPlayingPlaybackActionsHandlerImplementation", @"model", NO);
    });
}

NSDictionary<NSString *, id> *EeveeSpicyReadControls(id state) {
    NSCAssert([NSThread isMainThread], @"Playback controls require main thread");
    @try {
        id actions = currentActions();
        if (!actions) return @{};
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        NSDictionary *getters = @{
            @"canPause": @"isPausingAllowed", @"canResume": @"isResumingAllowed",
            @"canGoNext": @"isSkippingToNextTrackAllowed",
            @"canGoPrevious": @"isSkippingToPreviousTrackAllowed",
            @"canToggleShuffle": @"isShufflingAllowed"
        };
        for (NSString *key in getters) {
            NSNumber *value = readBool(actions, getters[key], nil, NO);
            if (value) result[key] = value;
        }
        id smart = readObject(actions, @"smartShuffleHandler");
        id context = shuffleContext(state);
        // Use Spotify's complete state for this player snapshot. Its native
        // implementation handles the in-flight Smart Shuffle state machine;
        // an entity recommendation flag plus a separate boolean does not.
        NSNumber *mode = context ? readShuffleState(smart, @"shuffleStateWithPlayerState:", state) : nil;
        if (!mode && context) mode = readShuffleState(smart, @"shuffleStateWithEntityURL:", context);
        NSNumber *enabled = mode ? @(mode.unsignedIntegerValue == 2)
            : (context ? readBool(smart, @"checkIsEntitySmartShuffled:", context, YES) : nil);
        NSNumber *supported = readBool(actions, @"isSmartShuffleSupported", nil, NO);
        if (enabled) result[@"smartShuffleEnabled"] = enabled;
        if (mode) {
            result[@"shuffleMode"] = @[@"off", @"shuffle", @"smart"][mode.unsignedIntegerValue];
            result[@"shuffleEnabled"] = @(mode.unsignedIntegerValue != 0);
        }
        if (supported) result[@"smartShuffleAvailable"] = supported;
        return result;
    } @catch (NSException *exception) {
        NSLog(@"[SpicyControls] state unavailable: %@", exception.name);
        return @{};
    }
}

// Spotify 9.1.76's automatic toggle takes a two-state path when picker UI is
// disabled. Use its explicit state setter instead. The supplied binary's
// shuffleStateWithEntityURL: and setShuffleState: implementations establish
// 0 = off, 1 = shuffle, 2 = smart; the native setter owns async recommendations
// and disabling Smart Shuffle. Never emulate that work with a boolean option.
static BOOL cycleShuffle(id actions, id state) {
    id smart = readObject(actions, @"smartShuffleHandler");
    id context = shuffleContext(state);
    if (!context) return NO;
    NSInvocation *read = invocation(smart, NSSelectorFromString(@"shuffleStateWithEntityURL:"), 1);
    if (!read || strcmp(unqualified(read.methodSignature.methodReturnType), "Q") != 0
        || !isObject([read.methodSignature getArgumentTypeAtIndex:2])) return NO;
    [read setArgument:&context atIndex:2];
    [read invoke];
    NSUInteger current = 0;
    [read getReturnValue:&current];
    if (current > 2) return NO;
    BOOL supported = readBool(actions, @"isSmartShuffleSupported", nil, NO).boolValue;
    NSUInteger next = current == 0 ? 1 : (current == 1 && supported ? 2 : 0);
    NSInvocation *call = invocation(smart, NSSelectorFromString(
        @"setShuffleState:for:showConfirmationUI:completion:"), 4);
    if (!call || strcmp(unqualified(call.methodSignature.methodReturnType), "v") != 0) return NO;
    NSMethodSignature *signature = call.methodSignature;
    if (strcmp(unqualified([signature getArgumentTypeAtIndex:2]), "Q") != 0
        || !isObject([signature getArgumentTypeAtIndex:3])
        || !isBool([signature getArgumentTypeAtIndex:4])
        || strcmp(unqualified([signature getArgumentTypeAtIndex:5]), "@?") != 0) return NO;
    BOOL showUI = NO;
    // Swift's ObjC-exposed SmartShuffleToggleResult is an integer enum.
    // Completion does not assert success; the next observed state does that.
    void (^completion)(NSInteger) = ^(NSInteger result) {
        NSLog(@"[SpicyControls] shuffle callback=%ld", (long)result);
    };
    [call setArgument:&next atIndex:2];
    [call setArgument:&context atIndex:3];
    [call setArgument:&showUI atIndex:4];
    [call setArgument:&completion atIndex:5];
    [call retainArguments];
    [call invoke];
    return YES;
}

NSInteger EeveeSpicyPerformControl(NSString *command, id state) {
    NSCAssert([NSThread isMainThread], @"Playback controls require main thread");
    @try {
        id actions = currentActions();
        if (!actions) return -1;
        NSDictionary *selectors = @{
            @"togglePlay": @"playPause", @"play": @"playPause", @"pause": @"playPause",
            @"next": @"skipToNext", @"previous": @"skipToPrevious",
            @"cycleRepeat": @"toggleRepeat", @"toggleShuffle": @"toggleShuffle"
        };
        NSString *name = selectors[command];
        if (!name) return -1;
        NSNumber *pauseState = readBool(actions, @"isPaused", nil, NO);
        if ([name isEqualToString:@"playPause"] && !pauseState) return -1;
        BOOL paused = pauseState.boolValue;
        if (([command isEqualToString:@"play"] && !paused)
            || ([command isEqualToString:@"pause"] && paused)) return 1;
        NSString *permission = nil;
        if ([name isEqualToString:@"playPause"]) permission = paused ? @"isResumingAllowed" : @"isPausingAllowed";
        else if ([command isEqualToString:@"next"]) permission = @"isSkippingToNextTrackAllowed";
        else if ([command isEqualToString:@"previous"]) permission = @"isSkippingToPreviousTrackAllowed";
        else if ([command isEqualToString:@"toggleShuffle"]) permission = @"isShufflingAllowed";
        NSNumber *allowed = permission ? readBool(actions, permission, nil, NO) : nil;
        if (allowed && !allowed.boolValue) return 0;
        if ([command isEqualToString:@"toggleShuffle"] && cycleShuffle(actions, state)) return 1;
        // Avoid opening an inaccessible native picker when the Smart Shuffle
        // adapter is not supported by this app build.
        if ([command isEqualToString:@"toggleShuffle"]) return -1;
        NSInvocation *call = invocation(actions, NSSelectorFromString(name), 0);
        if (!call || strcmp(unqualified(call.methodSignature.methodReturnType), "v") != 0) return -1;
        [call invoke];
        return 1;
    } @catch (NSException *exception) {
        NSLog(@"[SpicyControls] %@ rejected: %@", command, exception.name);
        return 0;
    }
}

BOOL EeveeSpicySetBooleanOption(id target, SEL selector, BOOL value) {
    @try {
        NSInvocation *call = invocation(target, selector, 1);
        if (!call) return NO;
        const char *type = [call.methodSignature getArgumentTypeAtIndex:2];
        NSNumber *boxed = @(value);
        if (isBool(type)) [call setArgument:&value atIndex:2];
        else if (isObject(type)) [call setArgument:&boxed atIndex:2];
        else return NO;
        [call invoke];
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"[SpicyControls] boolean option rejected: %@", exception.name);
        return NO;
    }
}
