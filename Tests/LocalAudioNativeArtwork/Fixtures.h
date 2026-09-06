#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
id EeveeArtworkFixtureTrack(NSString *URI, NSDictionary<NSString *, id> *metadata);
NSDictionary<NSString *, id> *EeveeArtworkFixtureMetadata(id track);
NSURL * _Nullable EeveeArtworkFixtureImageURL(id track);
id EeveeArtworkFixtureRequest(NSURL *URL);
void EeveeArtworkFixtureLoad(id request);
void EeveeArtworkFixtureCancel(id request);
void EeveeArtworkFixtureSetURL(id request, NSURL *URL);
NSData * _Nullable EeveeArtworkFixtureData(id request);
NSInteger EeveeArtworkFixtureOriginalLoads(id request);
NSInteger EeveeArtworkFixtureErrors(id request);
NSInteger EeveeArtworkFixtureSuccesses(id request);
NS_ASSUME_NONNULL_END
