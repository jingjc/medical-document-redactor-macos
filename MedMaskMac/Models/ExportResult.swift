import Foundation

struct ExportFailure: Identifiable, Hashable {
    let id: UUID
    let fileName: String
    let reason: String

    init(
        id: UUID = UUID(),
        fileName: String,
        reason: String
    ) {
        self.id = id
        self.fileName = fileName
        self.reason = reason
    }
}

struct ExportResult: Hashable {
    let destinationURL: URL
    let successCount: Int
    let failures: [ExportFailure]

    var failureCount: Int {
        failures.count
    }
}
