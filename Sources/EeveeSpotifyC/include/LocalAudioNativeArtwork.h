#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef NSString * _Nullable (^EeveeLocalArtworkURLProvider)(NSString *trackURI);
typedef BOOL (^EeveeLocalArtworkLoader)(NSURL *imageURL, BOOL (^isCancelled)(void), void (^completion)(NSData * _Nullable));

BOOL EeveeLocalAudioInstallArtwork(EeveeLocalArtworkURLProvider provider, EeveeLocalArtworkLoader loader);
NS_ASSUME_NONNULL_END
