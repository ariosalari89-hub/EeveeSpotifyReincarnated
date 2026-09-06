#import "LocalAudioNativeArtwork.h"
#import <objc/runtime.h>
#import <string.h>

static BOOL compatible(Method method, char result, NSUInteger count, BOOL objectArgument) {
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (signature.numberOfArguments != count + 2) return NO;
    const char *type = signature.methodReturnType;
    while (*type && strchr("rnNoORV", *type)) type++;
    if (result == 'B' ? (*type != 'B' && *type != 'c') : *type != result) return NO;
    return !objectArgument || [signature getArgumentTypeAtIndex:2][0] == '@';
}

static id objectValue(id target, SEL selector) {
    Method method = class_getInstanceMethod(object_getClass(target), selector);
    if (!compatible(method, '@', 0, NO)) return nil;
    return ((id (*)(id, SEL))method_getImplementation(method))(target, selector);
}

static BOOL cancelled(id request) {
    SEL selector = NSSelectorFromString(@"cancelled");
    Method method = class_getInstanceMethod(object_getClass(request), selector);
    if (!compatible(method, 'B', 0, NO)) return YES;
    return ((BOOL (*)(id, SEL))method_getImplementation(method))(request, selector);
}

static void replace(Class cls, SEL selector, Method method, IMP implementation) {
    if (!class_addMethod(cls, selector, implementation, method_getTypeEncoding(method))) {
        method_setImplementation(method, implementation);
    }
}

static char requestGenerationKey;

BOOL EeveeLocalAudioInstallArtwork(EeveeLocalArtworkURLProvider provider, EeveeLocalArtworkLoader loader) {
    static dispatch_once_t once;
    static BOOL installed = NO;
    dispatch_once(&once, ^{
        Class trackClass = NSClassFromString(@"SPTPlayerTrack");
        Class requestClass = NSClassFromString(@"SPTLocalAVAssetImageLoaderRequest");
        SEL metadataSelector = NSSelectorFromString(@"metadata");
        SEL uriSelector = NSSelectorFromString(@"URI");
        SEL urlSelector = NSSelectorFromString(@"URL");
        SEL loadSelector = NSSelectorFromString(@"loadLocalFileImage");
        SEL successSelector = NSSelectorFromString(@"dispatchSuccess:");
        SEL errorSelector = NSSelectorFromString(@"dispatchError:");
        Method metadata = class_getInstanceMethod(trackClass, metadataSelector);
        Method load = class_getInstanceMethod(requestClass, loadSelector);
        if (!provider || !loader || !compatible(metadata, '@', 0, NO) ||
            !compatible(class_getInstanceMethod(trackClass, uriSelector), '@', 0, NO) ||
            !compatible(load, 'v', 0, NO) ||
            !compatible(class_getInstanceMethod(requestClass, urlSelector), '@', 0, NO) ||
            !compatible(class_getInstanceMethod(requestClass, NSSelectorFromString(@"cancelled")), 'B', 0, NO) ||
            !compatible(class_getInstanceMethod(requestClass, successSelector), 'v', 1, YES) ||
            !compatible(class_getInstanceMethod(requestClass, errorSelector), 'v', 1, YES)) return;

        IMP originalLoad = method_getImplementation(load);
        IMP originalMetadata = method_getImplementation(metadata);
        IMP loadReplacement = imp_implementationWithBlock(^(id request) {
            NSURL *url = objectValue(request, urlSelector);
            if (![url isKindOfClass:NSURL.class]) { ((void (*)(id, SEL))originalLoad)(request, loadSelector); return; }
            NSObject *generation = [NSObject new];
            NSObject *replyLock = [NSObject new];
            __block BOOL replied = NO;
            objc_setAssociatedObject(request, &requestGenerationKey, generation, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            BOOL (^obsolete)(void) = ^BOOL {
                return cancelled(request) || objc_getAssociatedObject(request, &requestGenerationKey) != generation ||
                    ![objectValue(request, urlSelector) isEqual:url];
            };
            BOOL owned = loader(url, obsolete, ^(NSData *data) {
                @synchronized(replyLock) { if (replied) return; replied = YES; }
                if (obsolete()) return;
                if (data.length) {
                    Method success = class_getInstanceMethod(object_getClass(request), successSelector);
                    if (compatible(success, 'v', 1, YES)) {
                        ((void (*)(id, SEL, id))method_getImplementation(success))(request, successSelector, data);
                    }
                } else {
                    Method failure = class_getInstanceMethod(object_getClass(request), errorSelector);
                    if (compatible(failure, 'v', 1, YES)) {
                        NSError *error = [NSError errorWithDomain:@"EeveeSpotify.LocalArtwork" code:1
                            userInfo:@{NSLocalizedDescriptionKey: @"Embedded artwork is unavailable."}];
                        ((void (*)(id, SEL, id))method_getImplementation(failure))(request, errorSelector, error);
                    }
                }
            });
            if (!owned) ((void (*)(id, SEL))originalLoad)(request, loadSelector);
        });
        IMP metadataReplacement = imp_implementationWithBlock(^id(id track) {
            id original = ((id (*)(id, SEL))originalMetadata)(track, metadataSelector);
            if (![original isKindOfClass:NSDictionary.class]) return original;
            id rawURI = objectValue(track, uriSelector);
            NSString *uri = [rawURI isKindOfClass:NSURL.class] ? [rawURI absoluteString] : rawURI;
            if (![uri isKindOfClass:NSString.class] || ![uri hasPrefix:@"spotify:local:"]) return original;
            NSString *imageURL = provider(uri);
            if (!imageURL.length) return original;
            NSMutableDictionary *result = [original mutableCopy];
            for (NSString *key in @[@"image_url", @"thumbnail_image_url", @"image_large_url", @"image_xlarge_url"]) {
                id value = result[key];
                // Preserve existing native art routes, including iPod-library
                // and catalog-backed local images that this adapter doesn't own.
                if (!value || value == NSNull.null || ([value isKindOfClass:NSString.class] && ![value length])) {
                    result[key] = imageURL;
                }
            }
            return [result copy];
        });
        // Register the loader first: a newly supplied URL always has a handler.
        replace(requestClass, loadSelector, load, loadReplacement);
        replace(trackClass, metadataSelector, metadata, metadataReplacement);
        installed = YES;
    });
    return installed;
}
