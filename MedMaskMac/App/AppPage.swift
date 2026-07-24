import Foundation

enum AppPage: String, CaseIterable, Identifiable {
    case `import`
    case reviewEdit
    case exportSummary

    var id: Self { self }

    var title: String {
        L10n.Navigation.title(for: self)
    }

    var subtitle: String {
        L10n.Navigation.subtitle(for: self)
    }
}
