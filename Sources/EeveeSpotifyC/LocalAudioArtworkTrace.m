#import "LocalAudioArtworkTrace.h"
#import <objc/runtime.h>
#import <string.h>

static char metadataTrackKey, loadedImageKey;

@interface EeveeArtworkTraceState : NSObject
@property (nonatomic, copy) EeveeLocalArtworkDiagnostic diagnostic;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *identities;
- (NSUInteger)identity:(NSString *)value;
@end
@implementation EeveeArtworkTraceState
- (NSUInteger)identity:(NSString *)value {
    if (!value.length || [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 16384) return 0;
    @synchronized(self.identities) {
        NSNumber *existing = self.identities[value];
        if (existing) return existing.unsignedIntegerValue;
        // No eviction/reuse: an exhausted session reports unknown, never a
        // recycled identifier that could falsely join two different covers.
        if (self.identities.count >= 128) return 0;
        NSUInteger next = self.identities.count + 1;
        self.identities[[value copy]] = @(next);
        return next;
    }
}
@end

static EeveeArtworkTraceState *traceState;

static NSString *URLString(id value) {
    if ([value isKindOfClass:NSURL.class]) return [value absoluteString];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSUInteger imageIdentity(id URL) {
    NSString *raw = URLString(URL);
    return [raw hasPrefix:@"spotify:localfileimage:"] ? [traceState identity:raw] : 0;
}

static NSString *bindingRoute(id URL) {
    NSString *raw = URLString(URL);
    if (!raw.length) return @"missing";
    if ([raw hasPrefix:@"spotify:localfileimage:"]) return @"local";
    if ([raw hasPrefix:@"spotify:image:"] || [raw hasPrefix:@"https:"] || [raw hasPrefix:@"http:"]) return @"catalog";
    return @"other";
}

static BOOL exact(Method method, const char *encoding) {
    return method && strcmp(method_getTypeEncoding(method), encoding) == 0;
}

static void observe(Class cls, SEL selector, Method method, id block) {
    IMP replacement = imp_implementationWithBlock(block);
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) {
        method_setImplementation(method, replacement);
    }
}

void EeveeLocalArtworkTraceMetadata(NSDictionary *dictionary, NSString *trackURI) {
    if (!traceState || ![trackURI hasPrefix:@"spotify:local:"]) return;
    NSUInteger identity = [traceState identity:trackURI];
    if (identity) objc_setAssociatedObject(dictionary, &metadataTrackKey, @(identity), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void EeveeLocalArtworkTraceRequest(id URL) {
    NSUInteger identity = imageIdentity(URL);
    if (identity) traceState.diagnostic([NSString stringWithFormat:@"native display stage=request image=%lu", (unsigned long)identity]);
}

static void imageResult(NSString *stage, id URL, id image) {
    NSUInteger identity = imageIdentity(URL);
    if (!identity) return;
    // UIKit is intentionally optional for the Foundation-only boundary tests.
    // Never attach state to arbitrary, potentially tagged native return values.
    Class imageClass = NSClassFromString(@"UIImage");
    if (imageClass && [image isKindOfClass:imageClass]) {
        objc_setAssociatedObject(image, &loadedImageKey, @(identity), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    traceState.diagnostic([NSString stringWithFormat:@"native display stage=%@ image=%lu present=%d",
                           stage, (unsigned long)identity, image != nil]);
}

void EeveeLocalArtworkTraceImage(id URL, id image) { imageResult(@"remote-image", URL, image); }

static BOOL installGetter(NSString *name, NSString *kind) {
    Class cls = NSDictionary.class;
    SEL selector = NSSelectorFromString(name);
    Method method = class_getInstanceMethod(cls, selector);
    if (!exact(method, "@16@0:8")) return NO;
    IMP original = method_getImplementation(method);
    observe(cls, selector, method, ^id(id dictionary) {
        id result = ((id (*)(id, SEL))original)(dictionary, selector);
        NSUInteger track = [objc_getAssociatedObject(dictionary, &metadataTrackKey) unsignedIntegerValue];
        traceState.diagnostic([NSString stringWithFormat:@"native binding kind=%@ track=%lu image=%lu route=%@",
            kind, (unsigned long)track, (unsigned long)imageIdentity(result), bindingRoute(result)]);
        return result;
    });
    return YES;
}

static BOOL installConsumer(void) {
    Class cls = NSClassFromString(@"_TtC26ImageLoader_ImageLoaderKitP33_33D7ABF6E4C3EC1F400BFD35180212B719ImageLoaderDelegate");
    SEL successSelector = NSSelectorFromString(@"imageLoader:didLoadImage:forURL:loadTime:context:");
    SEL errorSelector = NSSelectorFromString(@"imageLoader:didFailToLoadImageForURL:error:context:");
    Method success = class_getInstanceMethod(cls, successSelector), error = class_getInstanceMethod(cls, errorSelector);
    if (!exact(success, "v56@0:8@16@24@32d40@48") || !exact(error, "v48@0:8@16@24@32@40")) return NO;
    IMP originalSuccess = method_getImplementation(success), originalError = method_getImplementation(error);
    observe(cls, successSelector, success, ^(id target, id loader, id image, id URL, double time, id context) {
        imageResult(@"consumer-image", URL, image);
        ((void (*)(id, SEL, id, id, id, double, id))originalSuccess)(target, successSelector, loader, image, URL, time, context);
    });
    observe(cls, errorSelector, error, ^(id target, id loader, id URL, id error, id context) {
        NSUInteger identity = imageIdentity(URL);
        if (identity) {
            NSInteger code = [error isKindOfClass:NSError.class] ? [error code] : 0;
            traceState.diagnostic([NSString stringWithFormat:@"native display stage=consumer-error image=%lu code=%ld",
                                   (unsigned long)identity, (long)code]);
        }
        ((void (*)(id, SEL, id, id, id, id))originalError)(target, errorSelector, loader, URL, error, context);
    });
    return YES;
}

void EeveeLocalArtworkTraceInstall(EeveeLocalArtworkDiagnostic diagnostic) {
    if (!diagnostic) return;
    traceState = [EeveeArtworkTraceState new];
    traceState.diagnostic = diagnostic;
    traceState.identities = [NSMutableDictionary new];
    NSUInteger getters = installGetter(@"spt_metadata_coverArtURL", @"standard") +
        installGetter(@"spt_metadata_coverArtURLLarge", @"large") + installGetter(@"spt_metadata_coverArtURLXLarge", @"xlarge");
    BOOL consumer = installConsumer();
    diagnostic([NSString stringWithFormat:@"native display install getters=%lu consumer=%d", (unsigned long)getters, consumer]);
}
