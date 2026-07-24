import Foundation

enum ReviewPreviewMode: String, CaseIterable, Identifiable {
    case original
    case maskedPreview

    var id: Self { self }

    var title: String {
        switch self {
        case .original:
            L10n.Review.originalPreview
        case .maskedPreview:
            L10n.Review.maskedPreview
        }
    }

    var toggleMenuTitle: String {
        switch self {
        case .original:
            L10n.Review.showMaskedPreview
        case .maskedPreview:
            L10n.Review.showOriginalPreview
        }
    }

    func toggled() -> ReviewPreviewMode {
        switch self {
        case .original:
            .maskedPreview
        case .maskedPreview:
            .original
        }
    }
}
