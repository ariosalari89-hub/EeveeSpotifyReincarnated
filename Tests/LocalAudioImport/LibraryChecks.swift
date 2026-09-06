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
        // macOS exposes the same temporary file through /var and /private/var.
        // Compare file locations, not those equivalent URL spellings.
        try expect(files.count == 1 && files[0].fileURL.resolvingSymlinksInPath() == copied.resolvingSymlinksInPath(),
                   "the imported-files library must list the existing native Documents copy; actual=\(files), expected=\(copied)")
        let reopened = try LocalAudioLibrary(directory: output).files()
        try expect(files == reopened && files[0].name == "Imported song.wav" && files[0].size > 0,
                   "reopening the library must retain the file's identity, name and size")
        let originalBytes = try Data(contentsOf: original)
        let copyBytes = try Data(contentsOf: files[0].fileURL)
        try expect(originalBytes == copyBytes && tryAudioFrames(files[0].fileURL) == 4_410,
                   "listing imports must preserve the original and its playable copy")
        print("PASS: imported-file inventory survives re-entry without changing audio")
    }
    try withDirectories { input, output in
        let original = input.appendingPathComponent("Before.wav")
        try makeAudio(at: original)
        let before = try Data(contentsOf: original)
        _ = LocalAudioImporter(directory: output).importFiles([original])
        let library = LocalAudioLibrary(directory: output)
        let selected = try library.files()[0]
        let renamed = try library.rename(selected, toStem: "音楽 — After")
        let reopened = try LocalAudioLibrary(directory: output).files()
        let renamedBytes = try Data(contentsOf: renamed.fileURL)
        let originalBytes = try Data(contentsOf: original)
        try expect(reopened.count == 1 && reopened[0] == renamed && renamed.id == selected.id &&
                   renamed.name == "音楽 — After.wav" && renamedBytes == before && originalBytes == before &&
                   tryAudioFrames(renamed.fileURL) == 4_410,
                   "renaming an imported filename must preserve its identity, extension, audio and external original after re-entry")
        print("PASS: imported filename rename survives re-entry without changing audio or external original")
    }
}
