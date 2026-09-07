import Foundation

func runArtworkDiagnosticExportChecks() throws {
    try withDirectories { input, _ in
        let activeURL = input.appendingPathComponent("artwork-active.log")
        let diagnostics = LocalAudioArtworkDiagnostics(fileURL: activeURL)
        diagnostics.record("reader request=track")
        diagnostics.record("reader result=no-match")
        diagnostics.record("reader URL=https://example.invalid/PrivateCanary")
        diagnostics.record("reader path=/private/PrivateCanary")
        diagnostics.record("reader result=PrivateCanary\nnative install=1")
        diagnostics.record("PrivateCanary")
        guard let snapshot = diagnostics.exportSnapshot() else {
            throw TestFailure(description: "artwork diagnostics must export an independent readable snapshot")
        }
        let initial = try Data(contentsOf: snapshot)
        let text = String(decoding: initial, as: UTF8.self)
        try expect(snapshot != activeURL && text.contains("build=v5.20-diagnostic") &&
                   text.contains("reader request=track") && text.contains("reader result=no-match") &&
                   !text.contains("PrivateCanary") && !text.contains(input.path),
                   "the artwork export must contain its build and observed stages, excluding malformed or raw-data records")
        DispatchQueue.concurrentPerform(iterations: 2_000) { index in
            diagnostics.record("native remote result=sample count=\(index)")
            diagnostics.record("reader request=track")
        }
        guard let bounded = diagnostics.exportSnapshot() else { throw TestFailure(description: "the bounded diagnostic snapshot is unavailable") }
        let boundedText = try String(contentsOf: bounded, encoding: .utf8)
        let lines = boundedText.split(separator: "\n")
        try expect(boundedText.utf8.count <= 192 * 1_024 && lines.count <= 258 &&
                   lines.allSatisfy { $0.hasPrefix("[LocalArtwork]") } &&
                   lines.filter { $0.contains("reader request=track") }.count <= 3 &&
                   boundedText.contains("trace limit=reached"),
                   "concurrent diagnostic traffic must stay bounded, suppress repeated records and report its recording limit")
        let retained = try Data(contentsOf: snapshot)
        try expect(retained == initial, "continued recording must not mutate a diagnostic snapshot already prepared for sharing")
        let restarted = LocalAudioArtworkDiagnostics(fileURL: activeURL)
        guard let fresh = restarted.exportSnapshot() else { throw TestFailure(description: "the new session needs its own diagnostic snapshot") }
        let freshText = try String(contentsOf: fresh, encoding: .utf8)
        let stillRetained = try Data(contentsOf: snapshot)
        try expect(!freshText.contains("reader result=no-match") && stillRetained == initial,
                   "a new app session must reset only its active diagnostic log, retaining already exported snapshots")
        print("PASS: artwork diagnostic export is a bounded, immutable, session-scoped snapshot without raw-data records")
    }
}
