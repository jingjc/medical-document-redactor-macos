import SwiftUI

struct ReviewEditPageView: View {
    @ObservedObject var viewModel: AppViewModel
    @FocusState private var isPreviewFocused: Bool
    @State private var canvasViewportSize: CGSize = .zero

    private let sidebarWidth: CGFloat = 240
    private let inspectorWidth: CGFloat = 360

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarWidth)
                .frame(maxHeight: .infinity, alignment: .top)

            Divider()

            canvas
                .frame(minWidth: 520, maxWidth: .infinity)
                .frame(maxHeight: .infinity, alignment: .top)

            Divider()

            inspector
                .frame(width: inspectorWidth)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .onMoveCommand { direction in
            switch direction {
            case .left:
                viewModel.goToPreviousPage()
            case .right:
                viewModel.goToNextPage()
            default:
                break
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PanelCard(
                    title: L10n.Review.filesTitle,
                    subtitle: L10n.Review.filesSubtitle
                ) {
                    if viewModel.files.isEmpty {
                        Text(L10n.Review.noImportedFiles)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(viewModel.files) { file in
                                Button {
                                    viewModel.selectFile(file.id)
                                } label: {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(file.displayName)
                                                .font(.headline)
                                                .multilineTextAlignment(.leading)
                                            Text(viewModel.fileSummary(for: file))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            if file.id == viewModel.selectedFileID,
                                               let metadata = viewModel.selectedSinglePageSidebarMetadata {
                                                Text(metadata)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }

                                        Spacer()
                                        StatusBadge(text: file.status.displayTitle)
                                    }
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(file.id == viewModel.selectedFileID ? Color.accentColor.opacity(0.10) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if viewModel.shouldShowPagesCard {
                    PanelCard(
                        title: L10n.Review.pagesTitle,
                        subtitle: L10n.Review.pagesSubtitle
                    ) {
                        if let pages = viewModel.selectedFile?.pages, !pages.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(pages) { page in
                                    Button {
                                        viewModel.selectPage(page.id)
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(page.title)
                                                    .font(.headline)
                                                Text(viewModel.pageSummary(for: page))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }

                                            Spacer()
                                            StatusBadge(text: page.status.displayTitle)
                                        }
                                        .padding(12)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(page.id == viewModel.selectedPageID ? Color.accentColor.opacity(0.10) : Color.clear)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } else {
                            Text(L10n.Review.noPagesAvailable)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var canvas: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.Navigation.title(for: .reviewEdit))
                        .font(.title2.weight(.semibold))

                    Text(L10n.Review.reviewReminder)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                PanelCard(
                    title: viewModel.canvasTitle,
                    subtitle: L10n.Review.canvasSubtitle
                ) {
                    let previewContent = viewModel.previewContent
                    let previewCanvasSize = rasterCanvasSize(for: previewContent)

                    VStack(spacing: 18) {
                        VStack(spacing: 10) {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(L10n.Review.documentContextTitle)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)

                                    Text(viewModel.selectedFileDisplayLabel)
                                        .font(.headline)
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    Text(viewModel.selectedPageDisplayLabel)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Picker(L10n.Review.previewMode, selection: $viewModel.previewDisplayMode) {
                                    ForEach(ReviewPreviewMode.allCases) { mode in
                                        Text(previewModeTitle(for: mode)).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 220)
                                .disabled(!viewModel.hasImportedFiles)
                            }

                            HStack(spacing: 12) {
                                zoomControls(contentSize: previewCanvasSize)
                                Spacer()

                                Button(L10n.Review.undo) {
                                    viewModel.undoCurrentPageEdit()
                                }
                                .disabled(!viewModel.isEditingEnabled || !viewModel.canUndoCurrentPageEdit)

                                Button(L10n.Review.redo) {
                                    viewModel.redoCurrentPageEdit()
                                }
                                .disabled(!viewModel.isEditingEnabled || !viewModel.canRedoCurrentPageEdit)

                                Button(L10n.Export.exportButton) {
                                    viewModel.beginExportFlow()
                                }
                                .disabled(!viewModel.canBeginExportFlow)
                            }
                        }

                        DocumentPreviewView(
                            content: previewContent,
                            regions: viewModel.displayedPreviewRegions,
                            candidateHighlights: candidateHighlights,
                            selectedRegionID: viewModel.selectedRegionID,
                            focusedCandidateID: viewModel.selectedOCRCandidateID,
                            focusedCandidateBounds: focusedCandidateBounds,
                            isEditingEnabled: viewModel.isEditingEnabled,
                            zoomScale: viewModel.resolvedCanvasZoomScale(
                                contentSize: previewCanvasSize,
                                viewportSize: canvasViewportSize
                            ),
                            scrollOffset: Binding(
                                get: { viewModel.selectedCanvasScrollOffset },
                                set: { viewModel.updateSelectedCanvasScrollOffset($0) }
                            ),
                            onViewportSizeChanged: { canvasViewportSize = $0 },
                            onSelectRegion: selectPreviewRegion,
                            onCreateRegion: createPreviewRegion,
                            onUpdateRegion: updatePreviewRegion,
                            onEditTransactionBegan: viewModel.beginPageEditTransaction,
                            onEditTransactionEnded: viewModel.endPageEditTransaction
                        )
                        .focusable()
                        .focusEffectDisabled()
                        .focused($isPreviewFocused)
                        .onDeleteCommand {
                            viewModel.deleteSelectedRegion()
                        }

                        HStack {
                            HStack(spacing: 8) {
                                Button(L10n.Review.previousPage) {
                                    viewModel.goToPreviousPage()
                                }
                                .disabled(!viewModel.canGoToPreviousPage)

                                Button(L10n.Review.nextPage) {
                                    viewModel.goToNextPage()
                                }
                                .disabled(!viewModel.canGoToNextPage)
                            }
                        }
                        .foregroundStyle(.secondary)

                        HStack {
                            if let selectedPreviewMetadataSummary = viewModel.selectedPreviewMetadataSummary,
                               let selectedPageStatusSummary = viewModel.selectedPageStatusSummary {
                                Text(selectedPreviewMetadataSummary)
                                Spacer()
                                Text(selectedPageStatusSummary)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        HStack {
                            Text(viewModel.isEditingEnabled ? L10n.Review.manualEditHint : L10n.Review.maskedPreviewHint)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button(role: .destructive) {
                                viewModel.deleteSelectedRegion()
                            } label: {
                                Label(L10n.Review.deleteRegion, systemImage: "trash")
                            }
                            .disabled(!viewModel.canDeleteSelectedRegion)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func zoomControls(contentSize: CGSize?) -> some View {
        HStack(spacing: 8) {
            Button(L10n.Review.zoomOut) {
                viewModel.zoomCanvasOut(
                    contentSize: contentSize,
                    viewportSize: canvasViewportSize
                )
            }
            .disabled(contentSize == nil)

            Text(viewModel.canvasZoomPercentageText(
                contentSize: contentSize,
                viewportSize: canvasViewportSize
            ))
            .font(.caption.monospacedDigit())
            .frame(width: 52)

            Button(L10n.Review.zoomIn) {
                viewModel.zoomCanvasIn(
                    contentSize: contentSize,
                    viewportSize: canvasViewportSize
                )
            }
            .disabled(contentSize == nil)

            Divider()
                .frame(height: 18)

            Button(L10n.Review.fitToWidthLabel) {
                viewModel.fitCanvasToWidth()
            }
            .disabled(contentSize == nil)

            Button(L10n.Review.fitToWindowLabel) {
                viewModel.fitCanvasToWindow()
            }
            .disabled(contentSize == nil)
        }
        .controlSize(.small)
    }

    private func rasterCanvasSize(for content: DocumentPreviewContent) -> CGSize? {
        guard case let .raster(rasterContent) = content else {
            return nil
        }

        return rasterContent.canvasSize
    }

    private func previewModeTitle(for mode: ReviewPreviewMode) -> String {
        switch mode {
        case .original:
            L10n.Review.originalPreviewLabel
        case .maskedPreview:
            L10n.Review.maskedPreviewLabel
        }
    }

    private var candidateHighlights: [DocumentPreviewCandidateHighlight] {
        guard viewModel.isEditingEnabled else {
            return []
        }

        return viewModel.visibleSelectedPageOCRCandidates.compactMap { candidate in
            guard candidate.boundingBox.width > 0,
                  candidate.boundingBox.height > 0 else {
                return nil
            }

            let isSelected = viewModel.selectedOCRCandidateID == candidate.id

            if candidate.status == .masked && !isSelected {
                return nil
            }

            return DocumentPreviewCandidateHighlight(
                id: candidate.id,
                bounds: candidate.boundingBox,
                status: DocumentPreviewCandidateHighlight.Status(candidate.status),
                isSelected: isSelected
            )
        }
    }

    private var focusedCandidateBounds: NormalizedRect? {
        guard let selectedOCRCandidateID = viewModel.selectedOCRCandidateID else {
            return nil
        }

        return viewModel.visibleSelectedPageOCRCandidates
            .first { $0.id == selectedOCRCandidateID }?
            .boundingBox
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PanelCard(
                    title: L10n.Review.inspectorTitle,
                    subtitle: L10n.Review.inspectorSubtitle
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(L10n.Review.maskPreset)
                            .font(.headline)

                        Picker(L10n.Review.maskPreset, selection: $viewModel.selectedPreset) {
                            ForEach(MaskPreset.allCases) { preset in
                                Text(preset.title).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text(viewModel.selectedPreset.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if viewModel.selectedPreset == .custom {
                            customPresetChecklist
                        }

                        Divider()

                        Label(viewModel.selectedFileRegionsSummary, systemImage: "square.dashed")
                        Label(viewModel.preparedRegionsSummary, systemImage: "square.stack.3d.down.right")
                        Label(viewModel.maskPreviewSummary, systemImage: "rectangle.and.pencil.and.ellipsis")
                    }
                }

                PanelCard(
                    title: L10n.Review.detectionTitle,
                    subtitle: L10n.Review.detectionSubtitle
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            viewModel.detectCurrentPageOCR()
                        } label: {
                            Label(L10n.Review.detectCurrentPage, systemImage: "text.viewfinder")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!viewModel.canDetectCurrentPageOCR)

                        HStack(spacing: 8) {
                            if viewModel.currentPageOCRState.isRunning {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            Text(viewModel.currentPageOCRStateSummary)
                        }
                        .font(.subheadline)

                        Text(L10n.Review.ocrSuggestionHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Divider()

                        Label(viewModel.ocrSummary, systemImage: "text.viewfinder")
                            .foregroundStyle(.secondary)
                        Label(viewModel.barcodeSummary, systemImage: "barcode.viewfinder")
                            .foregroundStyle(.secondary)

                        Divider()

                        VStack(alignment: .leading, spacing: 10) {
                            let visibleCandidates = viewModel.visibleSelectedPageOCRCandidates

                            Text(L10n.Review.ocrDetectedItemsTitle)
                                .font(.headline)

                            if !visibleCandidates.isEmpty {
                                ForEach(visibleCandidates) { candidate in
                                    OCRCandidateRow(
                                        candidate: candidate,
                                        isSelected: viewModel.selectedOCRCandidateID == candidate.id,
                                        onMask: {
                                            viewModel.maskOCRCandidate(candidate.id)
                                            isPreviewFocused = true
                                        },
                                        onIgnore: {
                                            viewModel.ignoreOCRCandidate(candidate.id)
                                        },
                                        onUndo: {
                                            viewModel.undoOCRCandidate(candidate.id)
                                        },
                                        onLocate: {
                                            viewModel.selectOCRCandidate(candidate.id)
                                            isPreviewFocused = true
                                        }
                                    )
                                }
                            } else {
                                Text(L10n.Review.noVisibleCandidates)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var customPresetChecklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Review.customPresetFieldsTitle)
                .font(.subheadline.weight(.semibold))

            ForEach(MaskCustomField.allCases) { field in
                Toggle(
                    field.title,
                    isOn: Binding(
                        get: { viewModel.isCustomFieldEnabled(field) },
                        set: { viewModel.setCustomField(field, isEnabled: $0) }
                    )
                )
            }
        }
        .toggleStyle(.checkbox)
    }

    private func selectPreviewRegion(_ regionID: SensitiveRegion.ID?) {
        viewModel.selectRegion(regionID)
        isPreviewFocused = true
    }

    private func createPreviewRegion(with bounds: NormalizedRect) {
        viewModel.createRegion(with: bounds)
        isPreviewFocused = true
    }

    private func updatePreviewRegion(_ regionID: SensitiveRegion.ID, _ bounds: NormalizedRect) {
        viewModel.updateRegion(regionID, bounds: bounds)
        isPreviewFocused = true
    }
}

private struct OCRCandidateRow: View {
    let candidate: OCRSensitiveCandidate
    let isSelected: Bool
    let onMask: () -> Void
    let onIgnore: () -> Void
    let onUndo: () -> Void
    let onLocate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(candidate.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                Text(stateBadgeText)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(stateBadgeForeground)
                    .background(
                        Capsule(style: .continuous)
                            .fill(stateBadgeBackground)
                    )
            }

            Text(candidate.displayValueText)
                .font(.subheadline)
                .foregroundStyle(valueForeground)
                .lineLimit(3)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(L10n.Review.maskOCRCandidate) {
                    onMask()
                }
                .disabled(!canMask)

                Button(L10n.Review.ignoreOCRCandidate) {
                    onIgnore()
                }
                .disabled(!canIgnore)

                Button(L10n.Review.undoOCRCandidate) {
                    onUndo()
                }
                .disabled(!canUndo)

                Button(L10n.Review.locateOCRCandidate) {
                    onLocate()
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(candidate.status == .ignored ? 0.58 : 1)
        .background(rowBackgroundColor)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(rowBorderColor, lineWidth: isSelected ? 2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var canMask: Bool {
        candidate.status == .pending
    }

    private var canIgnore: Bool {
        candidate.status == .pending
    }

    private var canUndo: Bool {
        candidate.status == .masked || candidate.status == .ignored
    }

    private var rowBackgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.10)
        }

        switch candidate.status {
        case .pending:
            switch candidate.valueState {
            case .valueUncertain, .unreadableContent:
                return Color.orange.opacity(0.10)
            case .emptyField:
                return Color(nsColor: .controlBackgroundColor)
            case .valueRecognized:
                return Color(nsColor: .controlBackgroundColor)
            }
        case .masked:
            return Color.green.opacity(0.10)
        case .ignored:
            return Color(nsColor: .controlBackgroundColor).opacity(0.55)
        }
    }

    private var rowBorderColor: Color {
        if isSelected {
            return Color.accentColor
        }

        switch candidate.status {
        case .pending:
            switch candidate.valueState {
            case .valueUncertain, .unreadableContent:
                return Color.orange.opacity(0.45)
            case .emptyField:
                return Color.secondary.opacity(0.18)
            case .valueRecognized:
                return Color.red.opacity(0.28)
            }
        case .masked:
            return Color.green.opacity(0.42)
        case .ignored:
            return Color.secondary.opacity(0.22)
        }
    }

    private var valueForeground: Color {
        switch candidate.status {
        case .ignored:
            return Color.secondary
        case .masked:
            return Color.primary
        case .pending:
            switch candidate.valueState {
            case .valueUncertain, .unreadableContent:
                return Color.orange
            case .emptyField:
                return Color.secondary
            case .valueRecognized:
                return Color.primary
            }
        }
    }

    private var stateBadgeText: String {
        switch candidate.status {
        case .masked:
            return L10n.Review.candidateMasked
        case .ignored:
            return L10n.Review.candidateIgnored
        case .pending:
            switch candidate.valueState {
            case .valueRecognized:
                return L10n.Review.candidateReliable
            case .valueUncertain:
                return L10n.Review.candidateUncertain
            case .unreadableContent:
                return L10n.Review.candidateUnreadable
            case .emptyField:
                return L10n.Review.candidateEmpty
            }
        }
    }

    private var stateBadgeForeground: Color {
        switch candidate.status {
        case .masked:
            return Color.green
        case .ignored:
            return Color.secondary
        case .pending:
            switch candidate.valueState {
            case .valueUncertain, .unreadableContent:
                return Color.orange
            case .emptyField:
                return Color.secondary
            case .valueRecognized:
                return Color.red
            }
        }
    }

    private var stateBadgeBackground: Color {
        stateBadgeForeground.opacity(0.14)
    }
}
