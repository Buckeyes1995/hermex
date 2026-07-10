import XCTest

final class ChatTranscriptLazyRowRealizationTests: XCTestCase {
    // Source-level regression guard for issue #32.
    // Ensures the transcript scroll content uses LazyVStack so rows are
    // realized on demand rather than all at once on load.
    func testTranscriptScrollContentUsesLazyVStack() throws {
        let sourceURL = try XCTUnwrap(
            Bundle(for: type(of: self))
                .url(forResource: "ChatTranscriptView", withExtension: "swift")
                ?? sourceFileURL(),
            "Could not locate ChatTranscriptView.swift"
        )

        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(matches(#"(?m)^\s*LazyVStack\(spacing: transcriptMessageSpacing\)"#, in: source))
        XCTAssertFalse(matches(#"(?m)^\s*VStack\(spacing: transcriptMessageSpacing\)"#, in: source))
    }

    private func matches(_ pattern: String, in source: String) -> Bool {
        source.range(of: pattern, options: .regularExpression) != nil
    }

    private func sourceFileURL() -> URL? {
        // Walk up from the test bundle to find the source tree.
        var url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // HermesMobileTests/
            .deletingLastPathComponent()  // project root
        url.appendPathComponent("HermesMobile/Features/Chat/ChatTranscriptView.swift")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
