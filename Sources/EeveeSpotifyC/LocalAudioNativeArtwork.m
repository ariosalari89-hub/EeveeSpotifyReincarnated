#import "LocalAudioNativeArtwork.h"
#import "LocalAudioArtworkTrace.h"
#import <objc/runtime.h>
#import <string.h>
#import <CoreGraphics/CGGeometry.h>

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

// Only closed route categories cross the diagnostic boundary. Never include
// URL payloads, source/context/cache keys, track fields or NSError descriptions.
static NSString *artworkRoute(id value) {
    NSString *raw = [value isKindOfClass:NSURL.class] ? [value absoluteString] : value;
    if (!raw || raw == (id)NSNull.null) return @"missing";
    if (![raw isKindOfClass:NSString.class]) return @"non-string";
    if (!raw.length) return @"missing";
    if (raw.length > 16384) return @"oversized";
    if ([raw hasPrefix:@"spotify:localfileimage:"]) {
        NSArray<NSString *> *parts = [raw componentsSeparatedByString:@":"];
        if (parts.count == 6) return @"local-v2";
        if (parts.count != 3) return @"local-invalid";
        NSString *payload = parts[2].stringByRemovingPercentEncoding;
        if ([payload hasPrefix:@"/.eevee-local-artwork-v1/"]) return @"local-owned";
        if ([payload hasPrefix:@"/"]) return @"local-file";
        if ([payload containsString:@"ipod-library"]) return @"local-ipod";
        return @"local-other";
    }
    if ([raw hasPrefix:@"spotify:image:"]) return @"catalog";
    if ([raw hasPrefix:@"http:"] || [raw hasPrefix:@"https:"]) return @"http";
    if ([raw hasPrefix:@"file:"]) return @"file";
    return @"other";
}

static NSString *requestRoute(id request) {
    return artworkRoute(objectValue(request, NSSelectorFromString(@"URL")));
}

static NSUInteger imageByteCount(id data) {
    return [data isKindOfClass:NSData.class] ? [data length] : 0;
}

static BOOL exactEncoding(Method method, const char *encoding) {
    return method && strcmp(method_getTypeEncoding(method), encoding) == 0;
}

static BOOL installRemoteObserver(EeveeLocalArtworkDiagnostic diagnostic) {
    if (!diagnostic) return NO;
    Class cls = NSClassFromString(@"SPTImageLoaderRemoteImplementation");
    SEL requestSelector = NSSelectorFromString(@"loadImageForURL:sourceIdentifier:size:scale:allowUpscaling:context:callback:persistenceKey:");
    SEL loadSelector = NSSelectorFromString(@"loadRequest:");
    SEL dataSelector = NSSelectorFromString(@"imageLoaderRequest:didLoadImageData:");
    SEL imageSelector = NSSelectorFromString(@"completeRequest:withImage:source:");
    SEL errorSelector = NSSelectorFromString(@"completeRequest:withError:source:");
    Method request = class_getInstanceMethod(cls, requestSelector);
    Method load = class_getInstanceMethod(cls, loadSelector);
    Method data = class_getInstanceMethod(cls, dataSelector);
    Method image = class_getInstanceMethod(cls, imageSelector);
    Method error = class_getInstanceMethod(cls, errorSelector);
    // Exact 9.1.76 signatures include the struct/floating-point argument layout.
    // An unavailable observer never prevents the existing artwork adapter.
    if (!exactEncoding(request, "@84@0:8@16@24{CGSize=dd}32d48B56@60@68@76") ||
        !exactEncoding(load, "v24@0:8@16") || !exactEncoding(data, "v32@0:8@16@24") ||
        !exactEncoding(image, "v40@0:8@16@24@32") || !exactEncoding(error, "v40@0:8@16@24@32")) return NO;
    IMP originalRequest = method_getImplementation(request), originalLoad = method_getImplementation(load);
    IMP originalData = method_getImplementation(data), originalImage = method_getImplementation(image);
    IMP originalError = method_getImplementation(error);
    replace(cls, requestSelector, request, imp_implementationWithBlock(^id(id target, id URL, id source, CGSize size,
                                                                         double scale, BOOL upscaling, id context, id callback, id key) {
        diagnostic([@"native remote request route=" stringByAppendingString:artworkRoute(URL)]);
        EeveeLocalArtworkTraceRequest(URL);
        return ((id (*)(id, SEL, id, id, CGSize, double, BOOL, id, id, id))originalRequest)
            (target, requestSelector, URL, source, size, scale, upscaling, context, callback, key);
    }));
    replace(cls, loadSelector, load, imp_implementationWithBlock(^(id target, id imageRequest) {
        NSString *name = imageRequest ? NSStringFromClass(object_getClass(imageRequest)) : @"missing";
        if (name.length > 128) name = @"other";
        diagnostic([NSString stringWithFormat:@"native remote load class=%@ route=%@", name, requestRoute(imageRequest)]);
        ((void (*)(id, SEL, id))originalLoad)(target, loadSelector, imageRequest);
    }));
    replace(cls, dataSelector, data, imp_implementationWithBlock(^(id target, id imageRequest, id bytes) {
        NSString *route = requestRoute(imageRequest);
        diagnostic([route hasPrefix:@"local-"]
            ? [NSString stringWithFormat:@"native remote bytes route=%@ bytes=%lu", route, (unsigned long)imageByteCount(bytes)]
            : [@"native remote bytes route=" stringByAppendingString:route]);
        ((void (*)(id, SEL, id, id))originalData)(target, dataSelector, imageRequest, bytes);
    }));
    replace(cls, imageSelector, image, imp_implementationWithBlock(^(id target, id imageRequest, id loadedImage, id source) {
        diagnostic([NSString stringWithFormat:@"native remote complete=image route=%@ present=%d", requestRoute(imageRequest), loadedImage != nil]);
        EeveeLocalArtworkTraceImage(objectValue(imageRequest, NSSelectorFromString(@"URL")), loadedImage);
        ((void (*)(id, SEL, id, id, id))originalImage)(target, imageSelector, imageRequest, loadedImage, source);
    }));
    replace(cls, errorSelector, error, imp_implementationWithBlock(^(id target, id imageRequest, id nativeError, id source) {
        NSString *route = requestRoute(imageRequest);
        NSInteger code = [nativeError isKindOfClass:NSError.class] ? [nativeError code] : 0;
        diagnostic([route hasPrefix:@"local-"]
            ? [NSString stringWithFormat:@"native remote complete=error route=%@ code=%ld", route, (long)code]
            : [@"native remote complete=error route=" stringByAppendingString:route]);
        ((void (*)(id, SEL, id, id, id))originalError)(target, errorSelector, imageRequest, nativeError, source);
    }));
    return YES;
}

static char requestGenerationKey;
static char coreFallbackKey;

static BOOL installCoreFallback(EeveeLocalArtworkLoader loader, EeveeLocalArtworkDiagnostic diagnostic) {
    Class cls = NSClassFromString(@"SPTCoreImageLoaderRequest");
    SEL loadSelector = NSSelectorFromString(@"load");
    SEL urlSelector = NSSelectorFromString(@"URL");
    SEL errorSelector = NSSelectorFromString(@"dispatchError:");
    SEL successSelector = NSSelectorFromString(@"dispatchSuccess:");
    Method load = class_getInstanceMethod(cls, loadSelector);
    Method error = class_getInstanceMethod(cls, errorSelector);
    if (!compatible(load, 'v', 0, NO) || !compatible(error, 'v', 1, YES) ||
        !compatible(class_getInstanceMethod(cls, urlSelector), '@', 0, NO) ||
        !compatible(class_getInstanceMethod(cls, NSSelectorFromString(@"cancelled")), 'B', 0, NO) ||
        !compatible(class_getInstanceMethod(cls, successSelector), 'v', 1, YES)) return NO;

    IMP originalLoad = method_getImplementation(load);
    IMP originalError = method_getImplementation(error);
    IMP loadReplacement = imp_implementationWithBlock(^(id request) {
        if (diagnostic) diagnostic([@"native core load route=" stringByAppendingString:requestRoute(request)]);
        @synchronized(request) {
            objc_setAssociatedObject(request, &requestGenerationKey, [NSObject new], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(request, &coreFallbackKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        ((void (*)(id, SEL))originalLoad)(request, loadSelector);
    });
    IMP errorReplacement = imp_implementationWithBlock(^(id request, NSError *nativeError) {
        NSURL *url = objectValue(request, urlSelector);
        if (diagnostic) {
            NSString *route = artworkRoute(url);
            NSInteger code = [nativeError isKindOfClass:NSError.class] ? nativeError.code : 0;
            diagnostic([route hasPrefix:@"local-"]
                ? [NSString stringWithFormat:@"native core result=error route=%@ code=%ld", route, (long)code]
                : [@"native core result=error route=" stringByAppendingString:route]);
        }
        if (![url isKindOfClass:NSURL.class] || ![url.absoluteString hasPrefix:@"spotify:localfileimage:"]) {
            ((void (*)(id, SEL, id))originalError)(request, errorSelector, nativeError);
            return;
        }
        NSObject *generation;
        @synchronized(request) {
            if (objc_getAssociatedObject(request, &coreFallbackKey)) return;
            generation = objc_getAssociatedObject(request, &requestGenerationKey) ?: [NSObject new];
            objc_setAssociatedObject(request, &requestGenerationKey, generation, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(request, &coreFallbackKey, generation, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        BOOL (^obsolete)(void) = ^BOOL {
            return cancelled(request) || objc_getAssociatedObject(request, &requestGenerationKey) != generation ||
                ![objectValue(request, urlSelector) isEqual:url];
        };
        NSObject *replyLock = [NSObject new];
        __block BOOL replied = NO;
        BOOL owned = loader(url, obsolete, ^(NSData *data) {
            @synchronized(replyLock) { if (replied) return; replied = YES; }
            if (obsolete()) { if (diagnostic) diagnostic(@"native core fallback result=obsolete"); return; }
            if (data.length) {
                if (diagnostic) diagnostic([NSString stringWithFormat:@"native core fallback result=artwork bytes=%lu", (unsigned long)data.length]);
                Method success = class_getInstanceMethod(object_getClass(request), successSelector);
                if (compatible(success, 'v', 1, YES)) {
                    ((void (*)(id, SEL, id))method_getImplementation(success))(request, successSelector, data);
                }
            } else {
                if (diagnostic) diagnostic(@"native core fallback result=no-artwork");
                ((void (*)(id, SEL, id))originalError)(request, errorSelector, nativeError);
            }
        });
        if (diagnostic) diagnostic([NSString stringWithFormat:@"native core fallback owned=%d", owned]);
        if (!owned) {
            objc_setAssociatedObject(request, &coreFallbackKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ((void (*)(id, SEL, id))originalError)(request, errorSelector, nativeError);
        }
    });
    // Native successes stay native. Only a failed owned local request reaches
    // the embedded reader, then returns through Spotify's original callbacks.
    replace(cls, errorSelector, error, errorReplacement);
    replace(cls, loadSelector, load, loadReplacement);
    if (diagnostic) {
        Method success = class_getInstanceMethod(cls, successSelector);
        IMP originalSuccess = method_getImplementation(success);
        replace(cls, successSelector, success, imp_implementationWithBlock(^(id request, id data) {
            NSString *route = requestRoute(request);
            diagnostic([route hasPrefix:@"local-"]
                ? [NSString stringWithFormat:@"native core result=success route=%@ bytes=%lu", route, (unsigned long)imageByteCount(data)]
                : [@"native core result=success route=" stringByAppendingString:route]);
            ((void (*)(id, SEL, id))originalSuccess)(request, successSelector, data);
        }));
    }
    return YES;
}

BOOL EeveeLocalAudioInstallArtworkWithDiagnostics(EeveeLocalArtworkURLProvider provider, EeveeLocalArtworkLoader loader,
                                                  EeveeLocalArtworkDiagnostic diagnostic) {
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
            !compatible(class_getInstanceMethod(requestClass, errorSelector), 'v', 1, YES)) {
            if (diagnostic) diagnostic(@"native install metadata=0 legacy=0 core=0 remote=0");
            return;
        }

        EeveeLocalArtworkTraceInstall(diagnostic);
        IMP originalLoad = method_getImplementation(load);
        IMP originalMetadata = method_getImplementation(metadata);
        IMP loadReplacement = imp_implementationWithBlock(^(id request) {
            NSURL *url = objectValue(request, urlSelector);
            if (diagnostic) diagnostic([@"native legacy load route=" stringByAppendingString:artworkRoute(url)]);
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
                if (obsolete()) { if (diagnostic) diagnostic(@"native legacy result=obsolete"); return; }
                if (data.length) {
                    if (diagnostic) diagnostic([NSString stringWithFormat:@"native legacy result=artwork bytes=%lu", (unsigned long)data.length]);
                    Method success = class_getInstanceMethod(object_getClass(request), successSelector);
                    if (compatible(success, 'v', 1, YES)) {
                        ((void (*)(id, SEL, id))method_getImplementation(success))(request, successSelector, data);
                    }
                } else {
                    if (diagnostic) diagnostic(@"native legacy result=no-artwork");
                    Method failure = class_getInstanceMethod(object_getClass(request), errorSelector);
                    if (compatible(failure, 'v', 1, YES)) {
                        NSError *error = [NSError errorWithDomain:@"EeveeSpotify.LocalArtwork" code:1
                            userInfo:@{NSLocalizedDescriptionKey: @"Embedded artwork is unavailable."}];
                        ((void (*)(id, SEL, id))method_getImplementation(failure))(request, errorSelector, error);
                    }
                }
            });
            if (diagnostic) diagnostic([NSString stringWithFormat:@"native legacy owned=%d", owned]);
            if (!owned) ((void (*)(id, SEL))originalLoad)(request, loadSelector);
        });
        IMP metadataReplacement = imp_implementationWithBlock(^id(id track) {
            id original = ((id (*)(id, SEL))originalMetadata)(track, metadataSelector);
            if (![original isKindOfClass:NSDictionary.class]) {
                if (diagnostic) diagnostic(@"native metadata dictionary=0");
                return original;
            }
            id rawURI = objectValue(track, uriSelector);
            NSString *uri = [rawURI isKindOfClass:NSURL.class] ? [rawURI absoluteString] : rawURI;
            if (![uri isKindOfClass:NSString.class] || ![uri hasPrefix:@"spotify:local:"]) {
                if (diagnostic) diagnostic(@"native metadata uri=nonlocal");
                return original;
            }
            NSString *imageURL = provider(uri);
            if (diagnostic) diagnostic([NSString stringWithFormat:@"native metadata uri=local image=%@ thumbnail=%@ large=%@ xlarge=%@ supplied=%d",
                artworkRoute(original[@"image_url"]), artworkRoute(original[@"thumbnail_image_url"]),
                artworkRoute(original[@"image_large_url"]), artworkRoute(original[@"image_xlarge_url"]), imageURL.length > 0]);
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
            NSDictionary *metadata = [result copy];
            EeveeLocalArtworkTraceMetadata(metadata, uri);
            return metadata;
        });
        // Register the loader first: a newly supplied URL always has a handler.
        replace(requestClass, loadSelector, load, loadReplacement);
        replace(trackClass, metadataSelector, metadata, metadataReplacement);
        BOOL core = installCoreFallback(loader, diagnostic);
        BOOL remote = installRemoteObserver(diagnostic);
        if (diagnostic) diagnostic([NSString stringWithFormat:@"native install metadata=1 legacy=1 core=%d remote=%d", core, remote]);
        installed = YES;
    });
    return installed;
}

BOOL EeveeLocalAudioInstallArtwork(EeveeLocalArtworkURLProvider provider, EeveeLocalArtworkLoader loader) {
    return EeveeLocalAudioInstallArtworkWithDiagnostics(provider, loader, nil);
}
