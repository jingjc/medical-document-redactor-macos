import SwiftUI

struct ExportSummaryPageView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(L10n.Export.title)
                    .font(.title2.weight(.semibold))

                Text(L10n.Export.description)
                    .foregroundStyle(.secondary)

                summaryMetrics

                Text(L10n.Export.currentRecognizedRegions)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 20) {
                    successListCard
                    failureListCard
                }

                actionBar
            }
            .padding(24)
        }
    }

    private var summaryMetrics: some View {
        HStack(spacing: 16) {
            ExportMetricCard(
                title: L10n.Export.successFilesTitle,
                value: "\(viewModel.lastExportResult?.successCount ?? 0)",
                systemImage: "checkmark.circle",
                color: .green
            )

            ExportMetricCard(
                title: L10n.Export.failedFilesTitle,
                value: "\(viewModel.lastExportResult?.failureCount ?? 0)",
                systemImage: "exclamationmark.triangle",
                color: .orange
            )

            ExportMetricCard(
                title: L10n.Export.processedFilesTitle,
                value: viewModel.processedExportFilesSummary,
                systemImage: "doc.on.doc",
                color: .accentColor
            )

            ExportMetricCard(
                title: L10n.Review.maskPreset,
                value: viewModel.selectedPreset.title,
                systemImage: "line.3.horizontal.decrease.circle",
                color: .secondary
            )
        }
    }

    private var successListCard: some View {
        PanelCard(
            title: L10n.Export.successFilesTitle,
            subtitle: L10n.Export.originalUnchanged
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if viewModel.successfulExportFileNames.isEmpty {
                    Text(L10n.Export.noSuccessfulFiles)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.successfulExportFileNames, id: \.self) { fileName in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(fileName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            StatusBadge(text: L10n.Export.exportedStatus)
                        }
                    }
                }
            }
        }
    }

    private var failureListCard: some View {
        PanelCard(
            title: L10n.Export.failedFilesTitle,
            subtitle: L10n.Export.failuresSubtitle
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if let failures = viewModel.lastExportResult?.failures,
                   !failures.isEmpty {
                    ForEach(failures) { failure in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(failure.fileName)
                                    .font(.headline)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Text(failure.reason)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(L10n.Export.noFailedFiles)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button(L10n.Export.exportButton) {
                viewModel.beginExportFlow()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canBeginExportFlow)

            Button(L10n.Export.openFolderButton) {
                viewModel.openExportDestination()
            }
            .disabled(!viewModel.canOpenExportDestination)

            Button(L10n.Export.continueNextBatch) {
                viewModel.continueNextBatch()
            }
            .disabled(!viewModel.hasImportedFiles && viewModel.lastExportResult == nil)

            Spacer()

            if let destinationPath = viewModel.lastExportDestinationPath {
                Label(L10n.Export.destinationPath(destinationPath), systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct ExportMetricCard: View {
    let title: String
    let value: String
    let systemImage: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}
