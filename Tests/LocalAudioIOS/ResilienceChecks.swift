import UIKit
import AVFoundation

@MainActor
extension QAAppDelegate {
    func openPicker(on navigation: UINavigationController) async throws -> UIDocumentPickerViewController {
        guard let host = navigation.topViewController, let list = table(in: host.view), list.window != nil else {
            throw Failure(description: "the active settings page is not on screen")
        }
        try tap("local_files_import", in: list)
        try await waitUntil("the system picker did not finish presenting") {
            guard let current = picker(in: navigation) else { return false }
            return current.viewIfLoaded?.window != nil && !current.isBeingPresented
        }
        return picker(in: navigation)!
    }

    func cancelAndRetry(navigation: UINavigationController) async throws {
        mark("Cancelling the picker before retrying a mixed selection")
        let list = table(in: navigation.topViewController!.view)!
        let retained = documents.appendingPathComponent("Completed before stop.wav")
        let retainedBytes = try Data(contentsOf: retained)
        let cancelledPicker = try await openPicker(on: navigation)
        cancelledPicker.delegate?.documentPickerWasCancelled?(cancelledPicker)
        try await waitUntil("cancelling the picker must dismiss without replacing the previous receipts") {
            picker(in: navigation) == nil &&
                cell("local_files_summary", in: list)?.accessibilityValue == "Copied: 1 · Already present: 0 · Not copied: 1"
        }
        let retainedAfter = try Data(contentsOf: retained)
        try expect(retainedAfter == retainedBytes, "picker cancellation must leave a completed song unchanged")

        let temporary = FileManager.default.temporaryDirectory
        let retry = temporary.appendingPathComponent("Waiting to copy.wav")
        let mp3 = temporary.appendingPathComponent("Evening tone.mp3")
        try FileManager.default.copyItem(at: Bundle.main.url(forResource: "synthetic-tone", withExtension: "mp3")!, to: mp3)
        let aac = temporary.appendingPathComponent("Summer recording.m4a")
        try makeAAC(at: aac)
        let longName = temporary.appendingPathComponent("أغنية مسائية — Evening walk by the river and the old harbour, recorded on a quiet summer night.wav")
        try makeAudio(at: longName)
        let invalid = temporary.appendingPathComponent("Unreadable recording.wav")
        try Data("This selected file contains text, not audio.".utf8).write(to: invalid)
        let duplicate = temporary.appendingPathComponent("Picked song.wav")
        let valid = [retry, mp3, aac, longName]
        let selections = valid + [invalid, duplicate]
        let originals = try selections.map { try Data(contentsOf: $0) }
        let selectionPicker = try await openPicker(on: navigation)
        selectionPicker.delegate?.documentPicker?(selectionPicker, didPickDocumentsAt: selections)
        try await waitUntil("the mixed retry must report four copies, one existing file and one failure") {
            picker(in: navigation) == nil &&
                cell("local_files_summary", in: list)?.accessibilityValue == "Copied: 4 · Already present: 1 · Not copied: 1"
        }
        for (index, source) in selections.enumerated() {
            let sourceAfter = try Data(contentsOf: source)
            try expect(sourceAfter == originals[index], "native selection must preserve every original")
        }
        for source in valid {
            try await waitUntil("a successful native result must identify its copied file") {
                cell("local_files_result", label: source.lastPathComponent, in: list)?.accessibilityValue == "Copied"
            }
            let output = documents.appendingPathComponent(source.lastPathComponent)
            let outputBytes = try Data(contentsOf: output)
            let inputBytes = try Data(contentsOf: source)
            let reader = try AVAudioFile(forReading: output)
            let decoded = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 1_024)!
            try reader.read(into: decoded)
            try expect(outputBytes == inputBytes && decoded.frameLength > 0,
                       "WAV, MP3 and AAC native receipts must correspond to unchanged, readable audio")
        }
        try await waitUntil("duplicate and unreadable items need distinct visible results") {
            cell("local_files_result", label: duplicate.lastPathComponent, in: list)?.accessibilityValue == "Already present" &&
                cell("local_files_result", label: invalid.lastPathComponent, in: list)?.accessibilityValue == "This file isn’t readable audio or is protected."
        }
        try expect(!FileManager.default.fileExists(atPath: documents.appendingPathComponent(invalid.lastPathComponent).path),
                   "failed audio must not enter the song source")
        list.setContentOffset(CGPoint(x: 0, y: -list.adjustedContentInset.top), animated: false)
        try await capture("mixed")
    }
}

private func makeAAC(at url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 11_025)!
    buffer.frameLength = 11_025
    for index in 0..<11_025 { buffer.floatChannelData![0][index] = 0.125 }
    let encoder = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000
    ], commonFormat: .pcmFormatFloat32, interleaved: false)
    try encoder.write(from: buffer)
}
