#import "LocalAudioNativeArtwork.h"

// Private, passive observations shared by the native adapter and UI trace.
void EeveeLocalArtworkTraceInstall(EeveeLocalArtworkDiagnostic _Nullable diagnostic);
void EeveeLocalArtworkTraceMetadata(NSDictionary * _Nonnull dictionary, NSString * _Nonnull trackURI);
void EeveeLocalArtworkTraceRequest(id _Nullable URL);
void EeveeLocalArtworkTraceImage(id _Nullable URL, id _Nullable image);
NSUInteger EeveeLocalArtworkTraceImageIdentifier(id _Nullable image);
void EeveeLocalArtworkTraceInstallViews(EeveeLocalArtworkDiagnostic _Nonnull diagnostic);
