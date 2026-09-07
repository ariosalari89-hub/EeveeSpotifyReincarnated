#import "Fixtures.h"
#import <objc/runtime.h>
#import <CoreGraphics/CGGeometry.h>

// System-boundary fixtures reproduce the observed Spotify 9.1.76 selectors
// and Objective-C types. They do not replace any shipping artwork component.
@interface SPTPlayerTrack : NSObject
@property NSURL *URI;
@property NSDictionary *metadata;
- (NSURL *)imageURL;
@end
@implementation SPTPlayerTrack
- (NSURL *)imageURL { return [NSURL URLWithString:self.metadata[@"image_url"]]; }
@end

@interface SPTLocalAVAssetImageLoaderRequest : NSObject
@property NSURL *URL;
@property BOOL cancelled;
@property NSData *data;
@property NSInteger originalLoads;
@property NSInteger errors;
@property NSInteger successes;
@property NSError *error;
#ifdef EEVEE_ARTWORK_INVALID_LOAD
- (id)loadLocalFileImage;
#else
- (void)loadLocalFileImage;
#endif
- (void)dispatchSuccess:(NSData *)data;
- (void)dispatchError:(NSError *)error;
@end
@implementation SPTLocalAVAssetImageLoaderRequest
#ifdef EEVEE_ARTWORK_INVALID_LOAD
- (id)loadLocalFileImage { self.originalLoads += 1; return nil; }
#else
- (void)loadLocalFileImage { self.originalLoads += 1; }
#endif
- (void)dispatchSuccess:(NSData *)data { if (!self.cancelled) { self.data = data; self.successes += 1; } }
- (void)dispatchError:(NSError *)error { if (!self.cancelled) { self.error = error; self.errors += 1; } }
@end

@interface SPTCoreImageLoaderRequest : NSObject
@property NSURL *URL;
@property BOOL cancelled;
@property NSData *data;
@property NSData *nativeData;
@property NSInteger originalLoads;
@property NSInteger errors;
@property NSInteger successes;
@property NSError *error;
- (void)load;
- (void)dispatchSuccess:(NSData *)data;
- (void)dispatchError:(NSError *)error;
@end
@implementation SPTCoreImageLoaderRequest
- (void)load {
    self.originalLoads += 1;
    if (self.nativeData) [self dispatchSuccess:self.nativeData];
    else [self dispatchError:[NSError errorWithDomain:@"NativeImageFixture" code:404 userInfo:nil]];
}
- (void)dispatchSuccess:(NSData *)data { if (!self.cancelled) { self.data = data; self.successes += 1; } }
- (void)dispatchError:(NSError *)error { if (!self.cancelled) { self.error = error; self.errors += 1; } }
@end

@interface SPTImageLoaderRemoteImplementation : NSObject
@property id returnedRequest;
@property NSArray *arguments;
- (id)loadImageForURL:(NSURL *)URL sourceIdentifier:(id)source size:(CGSize)size scale:(double)scale
      allowUpscaling:(BOOL)upscaling context:(id)context callback:(id)callback persistenceKey:(id)key;
- (void)loadRequest:(id)request;
- (void)imageLoaderRequest:(id)request didLoadImageData:(NSData *)data;
- (void)completeRequest:(id)request withImage:(id)image source:(id)source;
- (void)completeRequest:(id)request withError:(NSError *)error source:(id)source;
@end
@implementation SPTImageLoaderRemoteImplementation
- (id)loadImageForURL:(NSURL *)URL sourceIdentifier:(id)source size:(CGSize)size scale:(double)scale
      allowUpscaling:(BOOL)upscaling context:(id)context callback:(id)callback persistenceKey:(id)key {
    self.arguments = @[URL, source, @(size.width), @(size.height), @(scale), @(upscaling), context, callback, key];
    return self.returnedRequest;
}
- (void)loadRequest:(id)request { self.arguments = @[request]; }
- (void)imageLoaderRequest:(id)request didLoadImageData:(NSData *)data { self.arguments = @[request, data]; }
- (void)completeRequest:(id)request withImage:(id)image source:(id)source { self.arguments = @[request, image ?: NSNull.null, source]; }
- (void)completeRequest:(id)request withError:(NSError *)error source:(id)source { self.arguments = @[request, error, source]; }
@end

BOOL EeveeArtworkFixtureRemoteForwarding(NSURL *URL, id request, NSData *data, NSError *error) {
    SPTImageLoaderRemoteImplementation *remote = [SPTImageLoaderRemoteImplementation new];
    remote.returnedRequest = request;
    id source = @"PrivateCanary-source", context = @"PrivateCanary-context";
    id callback = [NSObject new], key = @"PrivateCanary-cache-key", image = [NSObject new];
    id result = [remote loadImageForURL:URL sourceIdentifier:source size:CGSizeMake(31, 47) scale:3.0
                        allowUpscaling:YES context:context callback:callback persistenceKey:key];
    if (result != request || ![remote.arguments isEqual:@[URL, source, @31, @47, @3, @YES, context, callback, key]]) return NO;
    [remote loadRequest:request];
    if (![remote.arguments isEqual:@[request]]) return NO;
    [remote imageLoaderRequest:request didLoadImageData:data];
    if (![remote.arguments isEqual:@[request, data]]) return NO;
    [remote completeRequest:request withImage:image source:source];
    if (![remote.arguments isEqual:@[request, image, source]]) return NO;
    [remote completeRequest:request withImage:nil source:source];
    if (![remote.arguments isEqual:@[request, NSNull.null, source]]) return NO;
    [remote completeRequest:request withError:error source:source];
    return [remote.arguments isEqual:@[request, error, source]];
}

id EeveeArtworkFixtureTrack(NSString *URI, NSDictionary *metadata) {
    SPTPlayerTrack *track = [SPTPlayerTrack new]; track.URI = [NSURL URLWithString:URI]; track.metadata = metadata; return track;
}
NSDictionary *EeveeArtworkFixtureMetadata(id track) { return [track metadata]; }
NSURL *EeveeArtworkFixtureImageURL(id track) { return [track imageURL]; }
id EeveeArtworkFixtureRequest(NSURL *URL) {
    SPTLocalAVAssetImageLoaderRequest *request = [SPTLocalAVAssetImageLoaderRequest new]; request.URL = URL; return request;
}
id EeveeArtworkFixtureCoreRequest(NSURL *URL, NSData *nativeData) {
    SPTCoreImageLoaderRequest *request = [SPTCoreImageLoaderRequest new];
    request.URL = URL; request.nativeData = nativeData; return request;
}
void EeveeArtworkFixtureLoad(id request) {
    if ([request isKindOfClass:SPTCoreImageLoaderRequest.class]) [(SPTCoreImageLoaderRequest *)request load];
    else [request loadLocalFileImage];
}
void EeveeArtworkFixtureCancel(id request) { [request setCancelled:YES]; }
void EeveeArtworkFixtureSetURL(id request, NSURL *URL) { [request setURL:URL]; }
NSData *EeveeArtworkFixtureData(id request) { return [request data]; }
NSInteger EeveeArtworkFixtureOriginalLoads(id request) { return [request originalLoads]; }
NSInteger EeveeArtworkFixtureErrors(id request) { return [request errors]; }
NSInteger EeveeArtworkFixtureSuccesses(id request) { return [request successes]; }
NSError *EeveeArtworkFixtureError(id request) { return [request error]; }
NSString *EeveeArtworkFixtureEncoding(NSString *className, NSString *selector) {
    Method method = class_getInstanceMethod(NSClassFromString(className), NSSelectorFromString(selector));
    return method ? [NSString stringWithUTF8String:method_getTypeEncoding(method)] : nil;
}
