#import "Fixtures.h"

#ifdef EEVEE_ARTWORK_INVALID_DISPLAY
typedef NSInteger EeveeFixtureLoadTime;
#else
typedef double EeveeFixtureLoadTime;
#endif

// These external-system methods and types are extracted independently from
// Spotify 9.1.76. No shipping display implementation is replaced by a fixture.
@interface NSDictionary (EeveeArtworkDisplayFixture)
- (NSURL *)spt_metadata_coverArtURL;
- (NSURL *)spt_metadata_coverArtURLLarge;
- (NSURL *)spt_metadata_coverArtURLXLarge;
@end
@implementation NSDictionary (EeveeArtworkDisplayFixture)
- (NSURL *)spt_metadata_coverArtURL { return self[@"image_url"] ? [NSURL URLWithString:self[@"image_url"]] : nil; }
- (NSURL *)spt_metadata_coverArtURLLarge { return self[@"image_large_url"] ? [NSURL URLWithString:self[@"image_large_url"]] : nil; }
- (NSURL *)spt_metadata_coverArtURLXLarge { return self[@"image_xlarge_url"] ? [NSURL URLWithString:self[@"image_xlarge_url"]] : nil; }
@end

@interface _TtC26ImageLoader_ImageLoaderKitP33_33D7ABF6E4C3EC1F400BFD35180212B719ImageLoaderDelegate : NSObject
@property NSArray *arguments;
- (void)imageLoader:(id)loader didLoadImage:(id)image forURL:(NSURL *)URL loadTime:(EeveeFixtureLoadTime)time context:(id)context;
- (void)imageLoader:(id)loader didFailToLoadImageForURL:(NSURL *)URL error:(NSError *)error context:(id)context;
@end
@implementation _TtC26ImageLoader_ImageLoaderKitP33_33D7ABF6E4C3EC1F400BFD35180212B719ImageLoaderDelegate
- (void)imageLoader:(id)loader didLoadImage:(id)image forURL:(NSURL *)URL loadTime:(EeveeFixtureLoadTime)time context:(id)context {
    self.arguments = @[loader, image ?: NSNull.null, URL, @(time), context];
}
- (void)imageLoader:(id)loader didFailToLoadImageForURL:(NSURL *)URL error:(NSError *)error context:(id)context {
    self.arguments = @[loader, URL, error, context];
}
@end

NSURL *EeveeArtworkFixtureCoverURL(id track, NSInteger size) {
    NSDictionary *metadata = EeveeArtworkFixtureMetadata(track);
    if (size == 1) return [metadata spt_metadata_coverArtURLLarge];
    if (size == 2) return [metadata spt_metadata_coverArtURLXLarge];
    return [metadata spt_metadata_coverArtURL];
}

BOOL EeveeArtworkFixtureConsumerForwarding(NSURL *URL, id image, NSError *error) {
    _TtC26ImageLoader_ImageLoaderKitP33_33D7ABF6E4C3EC1F400BFD35180212B719ImageLoaderDelegate *delegate =
        [_TtC26ImageLoader_ImageLoaderKitP33_33D7ABF6E4C3EC1F400BFD35180212B719ImageLoaderDelegate new];
    id loader = [NSObject new], context = @"PrivateCanary-consumer-context";
    EeveeFixtureLoadTime firstTime = (EeveeFixtureLoadTime)37.5, emptyTime = (EeveeFixtureLoadTime)4.25;
    [delegate imageLoader:loader didLoadImage:image forURL:URL loadTime:firstTime context:context];
    if (![delegate.arguments isEqual:@[loader, image, URL, @(firstTime), context]]) return NO;
    [delegate imageLoader:loader didLoadImage:nil forURL:URL loadTime:emptyTime context:context];
    if (![delegate.arguments isEqual:@[loader, NSNull.null, URL, @(emptyTime), context]]) return NO;
    [delegate imageLoader:loader didFailToLoadImageForURL:URL error:error context:context];
    return [delegate.arguments isEqual:@[loader, URL, error, context]];
}
