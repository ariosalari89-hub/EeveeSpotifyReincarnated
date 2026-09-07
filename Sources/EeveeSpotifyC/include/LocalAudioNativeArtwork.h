#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef NSString * _Nullable (^EeveeLocalArtworkURLProvider)(NSString *trackURI);
typedef BOOL (^EeveeLocalArtworkLoader)(NSURL *imageURL, BOOL (^isCancelled)(void), void (^completion)(NSData * _Nullable));
typedef void (^EeveeLocalArtworkDiagnostic)(NSString *event);

BOOL EeveeLocalAudioInstallArtwork(EeveeLocalArtworkURLProvider provider, EeveeLocalArtworkLoader loader);
BOOL EeveeLocalAudioInstallArtworkWithDiagnostics(EeveeLocalArtworkURLProvider provider, EeveeLocalArtworkLoader loader,
                                                  EeveeLocalArtworkDiagnostic _Nullable diagnostic);
NS_ASSUME_NONNULL_END
