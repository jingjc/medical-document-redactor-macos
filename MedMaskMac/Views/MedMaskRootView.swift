import SwiftUI

struct MedMaskRootView: View {
    @ObservedObject var viewModel: AppViewModel
    private let sidebarWidth: CGFloat = 180

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarWidth)
                .frame(maxHeight: .infinity, alignment: .top)

            Divider()

            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.App.title)
                    .font(.headline.weight(.semibold))

                Text(L10n.App.sidebarSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(AppPage.allCases) { page in
                    Button {
                        viewModel.selectedPage = page
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: iconName(for: page))
                                .frame(width: 18)

                            Text(navigationTitle(for: page))
                                .font(.subheadline.weight(viewModel.selectedPage == page ? .semibold : .regular))
                                .lineLimit(1)

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .foregroundStyle(viewModel.selectedPage == page ? Color.primary : Color.secondary)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(viewModel.selectedPage == page ? Color.accentColor.opacity(0.14) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 22)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.58))
    }

    @ViewBuilder
    private var pageContent: some View {
        switch viewModel.selectedPage {
        case .import:
            ImportPageView(viewModel: viewModel)
        case .reviewEdit:
            ReviewEditPageView(viewModel: viewModel)
        case .exportSummary:
            ExportSummaryPageView(viewModel: viewModel)
        }
    }

    private func navigationTitle(for page: AppPage) -> String {
        switch page {
        case .import:
            return L10n.Import.v0Title
        case .reviewEdit:
            return L10n.Navigation.title(for: .reviewEdit)
        case .exportSummary:
            return L10n.Navigation.title(for: .exportSummary)
        }
    }

    private func iconName(for page: AppPage) -> String {
        switch page {
        case .import:
            return "tray.and.arrow.down"
        case .reviewEdit:
            return "rectangle.and.pencil.and.ellipsis"
        case .exportSummary:
            return "checklist"
        }
    }
}
