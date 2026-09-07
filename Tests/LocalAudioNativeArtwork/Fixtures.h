#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
id EeveeArtworkFixtureTrack(NSString *URI, NSDictionary<NSString *, id> *metadata);
NSDictionary<NSString *, id> *EeveeArtworkFixtureMetadata(id track);
NSURL * _Nullable EeveeArtworkFixtureImageURL(id track);
id EeveeArtworkFixtureRequest(NSURL *URL);
id EeveeArtworkFixtureCoreRequest(NSURL *URL, NSData * _Nullable nativeData);
void EeveeArtworkFixtureLoad(id request);
void EeveeArtworkFixtureCancel(id request);
void EeveeArtworkFixtureSetURL(id request, NSURL *URL);
NSData * _Nullable EeveeArtworkFixtureData(id request);
NSInteger EeveeArtworkFixtureOriginalLoads(id request);
NSInteger EeveeArtworkFixtureErrors(id request);
NSInteger EeveeArtworkFixtureSuccesses(id request);
NSError * _Nullable EeveeArtworkFixtureError(id request);
NSString * _Nullable EeveeArtworkFixtureEncoding(NSString *className, NSString *selector);
BOOL EeveeArtworkFixtureRemoteForwarding(NSURL *URL, id request, NSData *data, NSError *error);
NSURL * _Nullable EeveeArtworkFixtureCoverURL(id track, NSInteger size);
BOOL EeveeArtworkFixtureConsumerForwarding(NSURL *URL, id image, NSError *error);
BOOL EeveeArtworkFixtureViewStates(NSURL *URL, NSError *error);
BOOL EeveeArtworkFixtureSharedImage(NSURL *firstURL, NSURL *secondURL, NSError *error);
BOOL EeveeArtworkFixtureViewLifetime(void);
BOOL EeveeArtworkFixtureUnsupportedViews(void);
NS_ASSUME_NONNULL_END
