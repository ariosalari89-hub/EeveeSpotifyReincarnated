#import "Fixtures.h"

// These external-system methods and types are extracted independently from
// Spotify 9.1.76. No shipping display implementation is replaced by a fixture.
@interface NSDictionary (EeveeArtworkDisplayFixture)
- (NSURL *)spt_metadata_coverArtURL;
- (NSURL *)spt_metadata_coverArtURLLarge;
- (NSURL *)spt_metadata_coverArtURLXLarge;
@end
@implementation NSDictionary (EeveeArtworkDisplayFixture)
- (NSURL *)spt_metadata_coverArtURL { return [NSURL URLWithString:self[@"image_url"]]; }
- (NSURL *)spt_metadata_coverArtURLLarge { return [NSURL URLWithString:self[@"image_large_url"]]; }
- (NSURL *)spt_metadata_coverArtURLXLarge { return [NSURL URLWithString:self[@"image_xlarge_url"]]; }
@end

@interface _TtC26ImageLoader_ImageLoaderKitP33_33D7ABF6E4C3EC1F400BFD35180212B719ImageLoaderDelegate : NSObject
@property NSArray *arguments;
- (void)imageLoader:(id)loader didLoadImage:(id)image forURL:(NSURL *)URL loadTime:(double)time context:(id)context;
- (void)imageLoader:(id)loader didFailToLoadImageForURL:(NSURL *)URL error:(NSError *)error context:(id)context;
@end
@implementation _TtC26ImageLoader_ImageLoaderKitP33_33D7ABF6E4C3EC1F400BFD35180212B719ImageLoaderDelegate
- (void)imageLoader:(id)loader didLoadImage:(id)image forURL:(NSURL *)URL loadTime:(double)time context:(id)context {
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
    [delegate imageLoader:loader didLoadImage:image forURL:URL loadTime:37.5 context:context];
    if (![delegate.arguments isEqual:@[loader, image, URL, @37.5, context]]) return NO;
    [delegate imageLoader:loader didLoadImage:nil forURL:URL loadTime:4.25 context:context];
    if (![delegate.arguments isEqual:@[loader, NSNull.null, URL, @4.25, context]]) return NO;
    [delegate imageLoader:loader didFailToLoadImageForURL:URL error:error context:context];
    return [delegate.arguments isEqual:@[loader, URL, error, context]];
}
