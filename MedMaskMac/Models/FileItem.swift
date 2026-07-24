import Foundation

enum FileKind: String, CaseIterable, Hashable {
    case pdf = "PDF"
    case image = "Image"

    var displayTitle: String {
        switch self {
        case .pdf:
            L10n.FileKind.pdf
        case .image:
            L10n.FileKind.image
        }
    }
}

enum FileProcessingStatus: String, CaseIterable, Hashable {
    case imported = "Imported"
    case readyForReview = "Ready For Review"
    case needsAttention = "Needs Attention"

    var displayTitle: String {
        switch self {
        case .imported:
            L10n.FileStatus.imported
        case .readyForReview:
            L10n.FileStatus.readyForReview
        case .needsAttention:
            L10n.FileStatus.needsAttention
        }
    }
}

struct FileItem: Identifiable, Hashable {
    let id: UUID
    var displayName: String
    var sourceURL: URL?
    var kind: FileKind
    var status: FileProcessingStatus
    var pages: [PageItem]

    init(
        id: UUID = UUID(),
        displayName: String,
        sourceURL: URL? = nil,
        kind: FileKind,
        status: FileProcessingStatus,
        pages: [PageItem] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.sourceURL = sourceURL
        self.kind = kind
        self.status = status
        self.pages = pages
    }

    var pageCount: Int {
        pages.count
    }
}
