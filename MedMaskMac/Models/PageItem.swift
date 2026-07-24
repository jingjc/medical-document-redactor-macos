import Foundation

enum PageProcessingStatus: String, CaseIterable, Hashable {
    case pendingDetection = "Pending Detection"
    case readyForReview = "Ready For Review"
    case maskedPreview = "Preview"

    var displayTitle: String {
        switch self {
        case .pendingDetection:
            L10n.PageStatus.pendingDetection
        case .readyForReview:
            L10n.PageStatus.readyForReview
        case .maskedPreview:
            L10n.PageStatus.maskedPreview
        }
    }
}

struct PageItem: Identifiable, Hashable {
    let id: UUID
    var pageNumber: Int
    var sourcePageIndex: Int?
    var status: PageProcessingStatus
    var sensitiveRegions: [SensitiveRegion]

    init(
        id: UUID = UUID(),
        pageNumber: Int,
        sourcePageIndex: Int? = nil,
        status: PageProcessingStatus,
        sensitiveRegions: [SensitiveRegion] = []
    ) {
        self.id = id
        self.pageNumber = pageNumber
        self.sourcePageIndex = sourcePageIndex
        self.status = status
        self.sensitiveRegions = sensitiveRegions
    }

    var title: String {
        L10n.Common.pageTitle(pageNumber)
    }
}
