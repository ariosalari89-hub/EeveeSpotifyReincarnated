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
    try withDirectories { input, output in
        let original = input.appendingPathComponent("Remove this copy.wav")
        let other = input.appendingPathComponent("Keep this copy.wav")
        try makeAudio(at: original)
        try makeAudio(at: other, value: 0.5)
        let originalBytes = try Data(contentsOf: original)
        _ = LocalAudioImporter(directory: output).importFiles([original, other])
        let library = LocalAudioLibrary(directory: output)
        let selected = try library.files().first { $0.name == "Remove this copy.wav" }!
        try library.remove(selected)
        let reopened = try LocalAudioLibrary(directory: output).files()
        let preservedOriginal = try Data(contentsOf: original)
        try expect(reopened.count == 1 && reopened[0].name == "Keep this copy.wav" &&
                   tryAudioFrames(reopened[0].fileURL) == 4_410 && originalBytes == preservedOriginal,
                   "confirmed removal must remove only the selected imported copy while preserving the other song and external original")
        print("PASS: removing an imported copy preserves the external original and every other song")
    }
    try withDirectories { input, output in
        let original = input.appendingPathComponent("Selected.wav")
        try makeAudio(at: original)
        _ = LocalAudioImporter(directory: output).importFiles([original])
        let library = LocalAudioLibrary(directory: output)
        let selected = try library.files()[0]
        let before = try Data(contentsOf: selected.fileURL)
        let occupied = output.appendingPathComponent("Occupied.wav")
        try makeAudio(at: occupied, value: 0.75)
        let occupiedBytes = try Data(contentsOf: occupied)
        let hidden = output.appendingPathComponent(".Hidden.wav")
        try makeAudio(at: hidden)
        try Data("not audio".utf8).write(to: output.appendingPathComponent("Notes.wav"))
        let nested = output.appendingPathComponent("Subfolder")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try makeAudio(at: nested.appendingPathComponent("Nested.wav"))
        try FileManager.default.createSymbolicLink(at: output.appendingPathComponent("Link.wav"), withDestinationURL: original)
        try FileManager.default.createSymbolicLink(at: output.appendingPathComponent("Dangling.wav"),
                                                   withDestinationURL: input.appendingPathComponent("Absent.wav"))
        let visible = try library.files()
        try expect(visible.map(\.name) == ["Occupied.wav", "Selected.wav"],
                   "the library must expose only direct, nonhidden, regular playable copies")
        for stem in ["", "   ", ".hidden", "../Outside", "..\\Outside", "bad:name", "bad\nname", String(repeating: "音", count: 90), "Occupied", "Link", "Dangling"] {
            var rejected = false
            do { _ = try library.rename(selected, toStem: stem) } catch { rejected = true }
            let after = try Data(contentsOf: selected.fileURL)
            let otherAfter = try Data(contentsOf: occupied)
            let originalAfter = try Data(contentsOf: original)
            try expect(rejected && after == before && otherAfter == occupiedBytes && originalAfter == before,
                       "invalid or occupied rename must fail without changing any existing file: \(stem.debugDescription)")
        }
        print("PASS: invalid names, collisions, symlinks and out-of-scope files cannot alter any song")
    }
    for change in ["replace", "disappear", "symlink", "external"] {
        try withDirectories { input, output in
            let original = input.appendingPathComponent("Selected.wav")
            try makeAudio(at: original)
            _ = LocalAudioImporter(directory: output).importFiles([original])
            let library = LocalAudioLibrary(directory: output)
            var selected = try library.files()[0]
            if change == "external" {
                selected = LocalAudioFile(id: selected.id, fileURL: original, size: selected.size,
                                          modified: selected.modified, created: selected.created)
            } else {
                try FileManager.default.removeItem(at: selected.fileURL)
                if change == "replace" { try makeAudio(at: selected.fileURL, value: 0.875, frames: 8_820) }
                if change == "symlink" {
                    try FileManager.default.createSymbolicLink(at: selected.fileURL, withDestinationURL: original)
                }
            }
            let externalBefore = try Data(contentsOf: original)
            let replacementBefore = try? Data(contentsOf: selected.fileURL)
            var renameRejected = false, removeRejected = false
            do { _ = try library.rename(selected, toStem: "Wrong file") } catch { renameRejected = true }
            do { try library.remove(selected) } catch { removeRejected = true }
            let externalAfter = try Data(contentsOf: original)
            let replacementAfter = try? Data(contentsOf: selected.fileURL)
            try expect(renameRejected && removeRejected && externalBefore == externalAfter &&
                       replacementBefore == replacementAfter,
                       "a \(change) target must never substitute for the originally selected imported copy")
            print("PASS: \(change) after selection rejects rename/remove and preserves the remaining files")
        }
    }
    try withDirectories { input, output in
        let original = input.appendingPathComponent("Read only.wav")
        try makeAudio(at: original)
        _ = LocalAudioImporter(directory: output).importFiles([original])
        let library = LocalAudioLibrary(directory: output)
        let selected = try library.files()[0]
        let before = try Data(contentsOf: selected.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: output.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: output.path) }
        var renameRejected = false, removeRejected = false
        do { _ = try library.rename(selected, toStem: "Cannot write") } catch { renameRejected = true }
        do { try library.remove(selected) } catch { removeRejected = true }
        let after = try Data(contentsOf: selected.fileURL)
        try expect(renameRejected && removeRejected && before == after,
                   "a filesystem write failure must report failure while preserving the selected imported copy")
        print("PASS: real permission failure leaves the imported copy untouched")
    }
}
