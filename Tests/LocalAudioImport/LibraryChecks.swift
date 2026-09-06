import Foundation
import AVFoundation

func runLocalAudioLibraryChecks() throws {
    try withDirectories { input, output in
        let original = input.appendingPathComponent("Imported song.wav")
        try makeAudio(at: original)
        let imported = LocalAudioImporter(directory: output).importFiles([original])
        guard let copied = imported.first?.fileURL else {
            throw TestFailure(description: "library scenario needs a completed audio import")
        }
        let files = try LocalAudioLibrary(directory: output).files()
        try expect(files.count == 1 && files[0].fileURL == copied,
                   "the imported-files library must list the existing native Documents copy")
        let reopened = try LocalAudioLibrary(directory: output).files()
        try expect(files == reopened && files[0].name == "Imported song.wav" && files[0].size > 0,
                   "reopening the library must retain the file's identity, name and size")
        let originalBytes = try Data(contentsOf: original)
        let copyBytes = try Data(contentsOf: files[0].fileURL)
        try expect(originalBytes == copyBytes && tryAudioFrames(files[0].fileURL) == 4_410,
                   "listing imports must preserve the original and its playable copy")
        print("PASS: imported-file inventory survives re-entry without changing audio")
    }
}
