import SwiftUI

struct ImportPageView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.Import.v0Title)
                        .font(.title2.weight(.semibold))

                    Text(L10n.Import.v0Description)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 16) {
                        importArea
                        importedFilesList
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    sessionPanel
                        .frame(width: 320)
                }
            }
            .padding(24)
        }
    }

    private var importArea: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .center, spacing: 12) {
                Image(systemName: "plus.rectangle.on.folder")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.tint)

                VStack(spacing: 6) {
                    Text(L10n.Import.dropAreaTitle)
                        .font(.headline)

                    Text(L10n.Import.dropAreaSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button(L10n.Import.chooseFiles) {
                        viewModel.importFiles()
                    }
                    .buttonStyle(.borderedProminent)

                    Button(L10n.Import.goToReview) {
                        viewModel.goToReview()
                    }
                    .disabled(!viewModel.canGoToReview)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        Color.accentColor.opacity(0.45),
                        style: StrokeStyle(lineWidth: 1.5, dash: [8, 5])
                    )
            )

            HStack(alignment: .top, spacing: 14) {
                Label(L10n.Common.supportedFormats(viewModel.supportedImportTypes), systemImage: "doc.badge.plus")
                Label(L10n.Import.privacyLocalOnly, systemImage: "desktopcomputer")
                Label(L10n.Import.privacyNoUpload, systemImage: "icloud.slash")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if let importErrorMessage = viewModel.importErrorMessage {
                Text(importErrorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
    }

    private var importedFilesList: some View {
        PanelCard(
            title: L10n.Import.importedListTitle,
            subtitle: viewModel.importedFilesCardSubtitle
        ) {
            if viewModel.files.isEmpty {
                Text(L10n.Import.emptyImportedFiles)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(viewModel.files) { file in
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: file.kind == .pdf ? "doc.richtext" : "photo")
                                .foregroundStyle(.secondary)
                                .frame(width: 22)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(file.displayName)
                                    .font(.headline)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Text(viewModel.fileSummary(for: file))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                            StatusBadge(text: file.status.displayTitle)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private var sessionPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            PanelCard(title: L10n.Import.currentSessionTitle) {
                HStack(spacing: 14) {
                    sessionMetric(value: "\(viewModel.files.count)", label: "文件")
                    sessionMetric(value: "\(viewModel.totalPageCount)", label: "页")
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.Import.privacyTitle)
                        .font(.subheadline.weight(.semibold))
                    Label(L10n.Import.privacyLocalOnly, systemImage: "checkmark.shield")
                    Label(L10n.Import.privacyNoUpload, systemImage: "network.slash")
                    Label(L10n.Import.privacySessionOnly, systemImage: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            PanelCard(title: L10n.Import.modeTitle) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker(L10n.Review.maskPreset, selection: $viewModel.selectedPreset) {
                        ForEach(MaskPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(L10n.Import.modeDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func sessionMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title.weight(.semibold))
                .monospacedDigit()

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
