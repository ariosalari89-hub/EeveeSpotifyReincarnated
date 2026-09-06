#import "Fixtures.h"
#import <objc/runtime.h>

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

id EeveeArtworkFixtureTrack(NSString *URI, NSDictionary *metadata) {
    SPTPlayerTrack *track = [SPTPlayerTrack new]; track.URI = [NSURL URLWithString:URI]; track.metadata = metadata; return track;
}
NSDictionary *EeveeArtworkFixtureMetadata(id track) { return [track metadata]; }
NSURL *EeveeArtworkFixtureImageURL(id track) { return [track imageURL]; }
id EeveeArtworkFixtureRequest(NSURL *URL) {
    SPTLocalAVAssetImageLoaderRequest *request = [SPTLocalAVAssetImageLoaderRequest new]; request.URL = URL; return request;
}
void EeveeArtworkFixtureLoad(id request) { [request loadLocalFileImage]; }
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
