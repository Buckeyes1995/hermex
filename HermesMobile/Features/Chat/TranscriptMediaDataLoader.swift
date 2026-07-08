import Foundation

extension APIClient {
    func transcriptMediaData(for reference: TranscriptMediaReference, sessionID: String? = nil) async throws -> Data {
        switch reference.source {
        case let .localPath(path):
            return try await mediaData(path: path, sessionID: sessionID)
        case let .remoteURL(url):
            return try await remoteTranscriptMediaData(from: url)
        }
    }
}
