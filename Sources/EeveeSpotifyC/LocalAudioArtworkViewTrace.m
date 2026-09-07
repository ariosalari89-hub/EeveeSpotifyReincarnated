#import "LocalAudioArtworkTrace.h"
#import <CoreGraphics/CGGeometry.h>
#import <objc/runtime.h>
#import <math.h>
#import <string.h>

// Optional, read-only UIKit observations. No Swift storage, global image setter,
// forced layout, view mutation, or retained player/view hierarchy is involved.
static char ownerKey, rootKey;
static NSUInteger nextView;
static Class viewClass, imageViewClass, encoreClass;
static EeveeLocalArtworkDiagnostic viewDiagnostic;

@interface EeveeArtworkViewObservation : NSObject
@property (nonatomic, weak) id owner;
@property (nonatomic, weak) id root;
@property (nonatomic, copy) NSString *surface;
@property (nonatomic, copy) NSString *lastSnapshot;
@property (nonatomic) NSUInteger identifier;
@property (nonatomic) BOOL active;
@end
@implementation EeveeArtworkViewObservation @end

static BOOL exact(Method method, const char *encoding) {
    return method && strcmp(method_getTypeEncoding(method), encoding) == 0;
}

static Method getter(id object, const char *name) {
    return class_getInstanceMethod(object_getClass(object), sel_registerName(name));
}

static id objectValue(id object, const char *name, BOOL *readable) {
    Method method = getter(object, name);
    if (!exact(method, "@16@0:8")) { *readable = NO; return nil; }
    return ((id (*)(id, SEL))method_getImplementation(method))(object, sel_registerName(name));
}

typedef struct { BOOL readable, mounted, hidden, sized; } ViewStatus;

static ViewStatus status(id view) {
    ViewStatus result = { YES, NO, NO, NO };
    Method hidden = getter(view, "isHidden"), alpha = getter(view, "alpha"), bounds = getter(view, "bounds");
    if ((!exact(hidden, "B16@0:8") && !exact(hidden, "c16@0:8")) || !exact(alpha, "d16@0:8") ||
        !exact(bounds, "{CGRect={CGPoint=dd}{CGSize=dd}}16@0:8")) {
        result.readable = NO;
        return result;
    }
    BOOL isHidden = ((BOOL (*)(id, SEL))method_getImplementation(hidden))(view, sel_registerName("isHidden"));
    double opacity = ((double (*)(id, SEL))method_getImplementation(alpha))(view, sel_registerName("alpha"));
    CGRect rectangle = ((CGRect (*)(id, SEL))method_getImplementation(bounds))(view, sel_registerName("bounds"));
    result.mounted = objectValue(view, "window", &result.readable) != nil;
    result.hidden = isHidden || !isfinite(opacity) || opacity <= 0;
    result.sized = isfinite(rectangle.size.width) && isfinite(rectangle.size.height) &&
        rectangle.size.width > 0 && rectangle.size.height > 0;
    return result;
}

typedef struct { NSUInteger nodes, images, filled, visible, linked; BOOL complete; } ViewCounts;

static void inspect(id view, NSUInteger depth, BOOL ancestorsVisible, EeveeArtworkViewObservation *observation,
                    ViewCounts *counts, NSMutableArray<NSString *> *imageEvents) {
    if (depth > 8 || counts->nodes >= 64 || ![view isKindOfClass:viewClass]) { counts->complete = NO; return; }
    counts->nodes += 1;
    ViewStatus flags = status(view);
    if (!flags.readable) { counts->complete = NO; return; }
    BOOL visible = ancestorsVisible && flags.mounted && !flags.hidden && flags.sized;
    if (imageViewClass && [view isKindOfClass:imageViewClass]) {
        BOOL readable = YES;
        id image = objectValue(view, "image", &readable);
        if (!readable) { counts->complete = NO; return; }
        NSUInteger identity = EeveeLocalArtworkTraceImageIdentifier(image);
        counts->images += 1;
        counts->filled += image != nil;
        counts->visible += image != nil && visible;
        counts->linked += identity != 0;
        if (imageEvents.count < 8) {
            [imageEvents addObject:[NSString stringWithFormat:
                @"native view-image surface=%@ view=%lu slot=%lu image=%lu present=%d visible=%d sized=%d",
                observation.surface, (unsigned long)observation.identifier, (unsigned long)counts->images,
                (unsigned long)identity, image != nil, image != nil && visible, flags.sized]];
        }
    }
    BOOL readable = YES;
    id children = objectValue(view, "subviews", &readable);
    if (!readable || ![children isKindOfClass:NSArray.class]) { counts->complete = NO; return; }
    for (id child in children) {
        if (counts->nodes >= 64) { counts->complete = NO; break; }
        inspect(child, depth + 1, visible, observation, counts, imageEvents);
    }
}

static void snapshot(EeveeArtworkViewObservation *observation) {
    if (!NSThread.isMainThread || !observation.active) return;
    id owner = observation.owner, root = observation.root;
    if (!owner || !root || objc_getAssociatedObject(owner, &ownerKey) != observation ||
        objc_getAssociatedObject(root, &rootKey) != observation) return;
    ViewStatus flags = status(root);
    if (!flags.readable) return;
    BOOL readable = YES, ancestorVisible = YES;
    id ancestor = objectValue(root, "superview", &readable);
    NSUInteger depth = 0;
    while (ancestor && readable && depth++ < 16) {
        if (![ancestor isKindOfClass:viewClass]) { readable = NO; break; }
        ViewStatus parent = status(ancestor);
        readable = parent.readable;
        flags.hidden |= parent.hidden;
        ancestorVisible &= parent.readable && parent.mounted && !parent.hidden && parent.sized;
        ancestor = objectValue(ancestor, "superview", &readable);
    }
    if (ancestor) readable = NO;
    ViewCounts counts = { 0, 0, 0, 0, 0, readable };
    NSMutableArray<NSString *> *events = [NSMutableArray new];
    inspect(root, 0, readable && ancestorVisible, observation, &counts, events);
    NSString *kind = encoreClass && [root isKindOfClass:encoreClass] ? @"encore" :
        (imageViewClass && [root isKindOfClass:imageViewClass] ? @"image" : @"other");
    NSString *summary = [NSString stringWithFormat:
        @"native view surface=%@ view=%lu kind=%@ complete=%d mounted=%d hidden=%d sized=%d images=%lu filled=%lu visible=%lu linked=%lu",
        observation.surface, (unsigned long)observation.identifier, kind, counts.complete, flags.mounted, flags.hidden,
        flags.sized, (unsigned long)counts.images, (unsigned long)counts.filled, (unsigned long)counts.visible, (unsigned long)counts.linked];
    [events insertObject:summary atIndex:0];
    NSString *signature = [events componentsJoinedByString:@"\n"];
    if ([signature isEqualToString:observation.lastSnapshot]) return;
    observation.lastSnapshot = signature;
    for (NSString *event in events) viewDiagnostic(event);
}

static void capture(id owner, id root, NSString *surface) {
    if (!NSThread.isMainThread || ![root isKindOfClass:viewClass]) return;
    EeveeArtworkViewObservation *previous = objc_getAssociatedObject(owner, &ownerKey);
    if (previous.active && previous.root == root) { snapshot(previous); return; }
    previous.active = NO;
    if (nextView >= 64) return; // Session-local IDs are never recycled.
    EeveeArtworkViewObservation *oldRoot = objc_getAssociatedObject(root, &rootKey);
    oldRoot.active = NO;
    EeveeArtworkViewObservation *observation = [EeveeArtworkViewObservation new];
    observation.owner = owner; observation.root = root; observation.surface = surface;
    observation.identifier = ++nextView; observation.active = YES;
    objc_setAssociatedObject(owner, &ownerKey, observation, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(root, &rootKey, observation, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    snapshot(observation);
    // Catch deferred native configuration without retaining the cell or view.
    __weak EeveeArtworkViewObservation *pending = observation;
    dispatch_async(dispatch_get_main_queue(), ^{ snapshot(pending); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ snapshot(pending); });
}

static void observe(Class cls, SEL selector, Method method, id block) {
    IMP replacement = imp_implementationWithBlock(block);
    // An inherited UIKit method must only be replaced on the named subclass.
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) method_setImplementation(method, replacement);
}

static BOOL installCover(NSString *name, NSString *surface) {
    Class cls = NSClassFromString(name);
    SEL coverSelector = NSSelectorFromString(@"coverArtView"), layoutSelector = NSSelectorFromString(@"layoutSubviews");
    SEL reuseSelector = NSSelectorFromString(@"prepareForReuse");
    Method cover = class_getInstanceMethod(cls, coverSelector), layout = class_getInstanceMethod(cls, layoutSelector);
    Method reuse = class_getInstanceMethod(cls, reuseSelector);
    if (!exact(cover, "@16@0:8") || !exact(layout, "v16@0:8") || !exact(reuse, "v16@0:8")) return NO;
    IMP originalCover = method_getImplementation(cover), originalLayout = method_getImplementation(layout), originalReuse = method_getImplementation(reuse);
    observe(cls, coverSelector, cover, ^id(id owner) {
        id root = ((id (*)(id, SEL))originalCover)(owner, coverSelector);
        capture(owner, root, surface);
        return root;
    });
    observe(cls, layoutSelector, layout, ^(id owner) {
        ((void (*)(id, SEL))originalLayout)(owner, layoutSelector);
        if (NSThread.isMainThread) snapshot(objc_getAssociatedObject(owner, &ownerKey));
    });
    observe(cls, reuseSelector, reuse, ^(id owner) {
        if (NSThread.isMainThread) {
            EeveeArtworkViewObservation *observation = objc_getAssociatedObject(owner, &ownerKey);
            observation.active = NO;
            objc_setAssociatedObject(owner, &ownerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        ((void (*)(id, SEL))originalReuse)(owner, reuseSelector);
    });
    return YES;
}

static BOOL installBar(void) {
    Class cls = NSClassFromString(@"_TtC18NowPlaying_BarImpl25BarCoverArtViewController");
    SEL selector = NSSelectorFromString(@"viewDidLoad");
    Method method = class_getInstanceMethod(cls, selector);
    if (!exact(method, "v16@0:8")) return NO;
    IMP original = method_getImplementation(method);
    observe(cls, selector, method, ^(id owner) {
        ((void (*)(id, SEL))original)(owner, selector);
        if (!NSThread.isMainThread) return;
        BOOL readable = YES;
        id root = objectValue(owner, "view", &readable);
        if (readable) capture(owner, root, @"bar");
    });
    return YES;
}

static BOOL installEncore(void) {
    SEL selector = NSSelectorFromString(@"layoutSubviews");
    Method method = class_getInstanceMethod(encoreClass, selector);
    if (!exact(method, "v16@0:8")) return NO;
    IMP original = method_getImplementation(method);
    observe(encoreClass, selector, method, ^(id view) {
        ((void (*)(id, SEL))original)(view, selector);
        if (!NSThread.isMainThread) return;
        id root = view;
        for (NSUInteger depth = 0; root && depth < 16; depth++) {
            EeveeArtworkViewObservation *observation = objc_getAssociatedObject(root, &rootKey);
            if (observation.active) { snapshot(observation); break; }
            BOOL readable = YES;
            root = objectValue(root, "superview", &readable);
            if (!readable) break;
        }
    });
    return YES;
}

void EeveeLocalArtworkTraceInstallViews(EeveeLocalArtworkDiagnostic diagnostic) {
    viewClass = NSClassFromString(@"UIView"); imageViewClass = NSClassFromString(@"UIImageView");
    encoreClass = NSClassFromString(@"_TtCE15Encore_MediaKitO16EncoreFoundation6Encore9ImageView");
    viewDiagnostic = [diagnostic copy];
    BOOL cover = NO, legacy = NO, bar = NO, encore = NO;
    if (viewClass) {
        cover = installCover(@"_TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl", @"cover");
        legacy = installCover(@"_TtC28NowPlaying_ContentLayersImpl22LegacyCoverArtCellImpl", @"legacy-cover");
        bar = installBar(); encore = installEncore();
    }
    diagnostic([NSString stringWithFormat:@"native view install cover=%d legacy=%d bar=%d encore=%d", cover, legacy, bar, encore]);
}
