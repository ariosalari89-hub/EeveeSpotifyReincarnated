#import "LocalAudioNativeArtwork.h"

// Private, passive observations shared by the native adapter and UI trace.
void EeveeLocalArtworkTraceInstall(EeveeLocalArtworkDiagnostic _Nullable diagnostic);
void EeveeLocalArtworkTraceMetadata(NSDictionary *dictionary, NSString *trackURI);
void EeveeLocalArtworkTraceRequest(id _Nullable URL);
void EeveeLocalArtworkTraceImage(id _Nullable URL, id _Nullable image);
