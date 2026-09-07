#import "Fixtures.h"
#import <CoreGraphics/CGGeometry.h>

// Foundation-only external UI fixtures. These compile only into the macOS
// boundary test executable, never the tweak or the iOS simulator application.
@interface UIImage : NSObject @end
@implementation UIImage @end
@interface UIView : NSObject
@property (nonatomic, strong) NSArray *subviews;
@property (nonatomic, weak) UIView *superview;
@property (nonatomic, strong) id window;
@property (nonatomic, getter=isHidden) BOOL hidden;
@property (nonatomic) double alpha;
@property (nonatomic) CGRect bounds;
@property (nonatomic) NSUInteger layouts;
- (void)layoutSubviews;
@end
@implementation UIView
- (instancetype)init {
    if ((self = [super init])) { _subviews = @[]; _alpha = 1; _bounds = CGRectMake(0, 0, 64, 64); }
    return self;
}
- (void)layoutSubviews { self.layouts += 1; }
@end
@interface UIImageView : UIView
@property (nonatomic, strong) UIImage *image;
@end
@implementation UIImageView @end
@interface _TtCE15Encore_MediaKitO16EncoreFoundation6Encore9ImageView : UIView @end
@implementation _TtCE15Encore_MediaKitO16EncoreFoundation6Encore9ImageView
- (void)layoutSubviews { [super layoutSubviews]; }
@end
@interface EeveeArtworkFixtureCoverBase : UIView
@property (nonatomic, strong) UIView *storedCover;
@property (nonatomic) NSUInteger reuses;
#ifdef EEVEE_ARTWORK_INVALID_DISPLAY
- (NSInteger)coverArtView;
#else
- (UIView *)coverArtView;
#endif
- (void)prepareForReuse;
@end
@implementation EeveeArtworkFixtureCoverBase
#ifdef EEVEE_ARTWORK_INVALID_DISPLAY
- (NSInteger)coverArtView { return 17; }
#else
- (UIView *)coverArtView { return self.storedCover; }
#endif
- (void)prepareForReuse { self.reuses += 1; }
@end
@interface _TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl : EeveeArtworkFixtureCoverBase @end
@implementation _TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl @end
@interface _TtC28NowPlaying_ContentLayersImpl22LegacyCoverArtCellImpl : EeveeArtworkFixtureCoverBase @end
@implementation _TtC28NowPlaying_ContentLayersImpl22LegacyCoverArtCellImpl @end
@interface _TtC18NowPlaying_BarImpl25BarCoverArtViewController : NSObject
@property (nonatomic, strong) UIView *view;
@property (nonatomic) NSUInteger loads;
- (void)viewDidLoad;
@end
@implementation _TtC18NowPlaying_BarImpl25BarCoverArtViewController
- (void)viewDidLoad { self.loads += 1; }
@end

#ifndef EEVEE_ARTWORK_INVALID_DISPLAY
BOOL EeveeArtworkFixtureViewStates(NSURL *URL, NSError *error) {
    UIImage *image = [UIImage new];
    if (!EeveeArtworkFixtureConsumerForwarding(URL, image, error)) return NO;
    for (Class cls in @[_TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl.class,
                        _TtC28NowPlaying_ContentLayersImpl22LegacyCoverArtCellImpl.class]) {
        EeveeArtworkFixtureCoverBase *cell = [cls new];
        UIView *root = [_TtCE15Encore_MediaKitO16EncoreFoundation6Encore9ImageView new];
        UIImageView *imageView = [UIImageView new];
        root.subviews = @[imageView]; imageView.superview = root;
        root.window = [NSObject new]; imageView.window = root.window;
        cell.storedCover = root;
        if ([cell coverArtView] != root) return NO;
        [cell layoutSubviews];
        imageView.image = image;
        [root layoutSubviews];
        root.hidden = YES;
        [root layoutSubviews];
        root.hidden = NO;
        imageView.bounds = CGRectZero;
        [root layoutSubviews];
        if (cell.layouts != 1 || root.layouts != 3 || imageView.image != image || root.hidden ||
            !CGRectEqualToRect(imageView.bounds, CGRectZero) || root.alpha != 1 || root.subviews.count != 1) return NO;
        [cell prepareForReuse];
        if (cell.reuses != 1) return NO;
        // Layout after reuse must not be attributed to the old cover owner.
        root.bounds = CGRectZero;
        [root layoutSubviews];
    }
    _TtC18NowPlaying_BarImpl25BarCoverArtViewController *bar = [_TtC18NowPlaying_BarImpl25BarCoverArtViewController new];
    UIImageView *barImage = [UIImageView new];
    barImage.window = [NSObject new]; barImage.image = image;
    bar.view = barImage;
    [bar viewDidLoad];
    return bar.loads == 1 && bar.view == barImage && barImage.image == image && barImage.layouts == 0;
}

BOOL EeveeArtworkFixtureSharedImage(NSURL *firstURL, NSURL *secondURL, NSError *error) {
    UIImage *shared = [UIImage new];
    if (!EeveeArtworkFixtureConsumerForwarding(firstURL, shared, error) ||
        !EeveeArtworkFixtureConsumerForwarding(secondURL, shared, error)) return NO;
    EeveeArtworkFixtureCoverBase *cell = [_TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl new];
    UIImageView *root = [UIImageView new];
    root.window = [NSObject new]; root.image = shared; cell.storedCover = root;
    return [cell coverArtView] == root && root.image == shared && root.layouts == 0;
}

BOOL EeveeArtworkFixtureViewLifetime(void) {
    __weak id releasedOwner, releasedRoot;
    @autoreleasepool {
        EeveeArtworkFixtureCoverBase *cell = [_TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl new];
        UIImageView *root = [UIImageView new];
        root.window = [NSObject new]; cell.storedCover = root;
        releasedOwner = cell; releasedRoot = root;
        if ([cell coverArtView] != root) return NO;
        [cell prepareForReuse];
    }
    // Delayed observation blocks are still pending on the main queue here.
    return releasedOwner == nil && releasedRoot == nil;
}
#else
BOOL EeveeArtworkFixtureUnsupportedViews(void) {
    for (Class cls in @[_TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl.class,
                        _TtC28NowPlaying_ContentLayersImpl22LegacyCoverArtCellImpl.class]) {
        EeveeArtworkFixtureCoverBase *cell = [cls new];
        UIView *root = [_TtCE15Encore_MediaKitO16EncoreFoundation6Encore9ImageView new];
        cell.storedCover = root;
        if ([cell coverArtView] != 17) return NO;
        [cell layoutSubviews]; [cell prepareForReuse];
        if (cell.layouts != 1 || cell.reuses != 1 || root.layouts != 0) return NO;
    }
    return YES;
}
#endif
