import Combine
import CoreGraphics
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published var selectedPage: AppPage = .import
    @Published var selectedPreset: MaskPreset = .standard {
        didSet {
            guard oldValue != selectedPreset else {
                return
            }

            lastExportResult = nil
            handleOCRDisplayOptionsChanged()
            schedulePreviewRefresh()
        }
    }
    @Published var selectedCustomFields: Set<MaskCustomField> = MaskCustomField.defaultEnabledFields {
        didSet {
            guard oldValue != selectedCustomFields else {
                return
            }

            lastExportResult = nil
            if selectedPreset == .custom {
                handleOCRDisplayOptionsChanged()
            }
            schedulePreviewRefresh()
        }
    }
    @Published var previewDisplayMode: ReviewPreviewMode = .original {
        didSet {
            if previewDisplayMode == .maskedPreview {
                selectedRegionID = nil
            }
            schedulePreviewRefresh()
        }
    }
    @Published var files: [FileItem] {
        didSet {
            guard oldValue != files else {
                return
            }

            lastExportResult = nil
            schedulePreviewRefresh()
        }
    }
    @Published var selectedFileID: FileItem.ID?
    @Published var selectedPageID: PageItem.ID?
    @Published var selectedRegionID: SensitiveRegion.ID?
    @Published var importErrorMessage: String?
    @Published var lastExportResult: ExportResult?
    @Published var currentPageOCRState: CurrentPageOCRState = .idle
    @Published private(set) var previewContent: DocumentPreviewContent = .empty
    @Published var ocrCandidates: [OCRSensitiveCandidate] = [] {
        didSet {
            ocrCandidatesRevision += 1
        }
    }
    @Published var selectedOCRCandidateID: OCRSensitiveCandidate.ID?
    @Published private var recognizingPageIDs: Set<PageItem.ID> = []

    private let fileImportService: any FileImportService
    private let pdfRenderService: any PDFRenderService
    private let ocrService: any OCRService
    private let barcodeService: any BarcodeService
    private let maskComposeService: any MaskComposeService
    private let exportService: any ExportService
    private let previewRenderer = PreviewRenderer()
    private var lastSelectedPageByFileID: [FileItem.ID: PageItem.ID] = [:]
    private var undoStack: [PageEditSnapshot] = []
    private var redoStack: [PageEditSnapshot] = []
    private var historyPageID: PageItem.ID?
    private var isPageEditTransactionOpen = false
    private let minimumCanvasZoomScale: CGFloat = 0.25
    private let maximumCanvasZoomScale: CGFloat = 8.0
    private let canvasZoomStep: CGFloat = 1.25
    @Published private var canvasZoomStates: [PageItem.ID: CanvasZoomState] = [:]
    private var canvasScrollOffsets: [PageItem.ID: CGPoint] = [:]
    private var previewRenderTask: Task<Void, Never>?
    private var pendingPreviewKey: PreviewContentCacheKey?
    private var renderedPreviewKey: PreviewContentCacheKey?
    private var previewContentCache: [PreviewContentCacheKey: DocumentPreviewContent] = [:]
    private var pageOCRStates: [PageItem.ID: CurrentPageOCRState] = [:]
    private var ocrCandidatesRevision = 0
    private var visibleCandidatesCacheKey: VisibleCandidateCacheKey?
    private var visibleCandidatesCache: [OCRSensitiveCandidate] = []

    init() {
        self.files = []
        self.fileImportService = DefaultFileImportService()
        self.pdfRenderService = DefaultPDFRenderService()
        self.ocrService = DefaultOCRService()
        self.barcodeService = PlaceholderBarcodeService()
        self.maskComposeService = DefaultMaskComposeService()
        self.exportService = DefaultExportService(maskComposeService: maskComposeService)
        self.selectedFileID = nil
        self.selectedPageID = nil
        self.selectedRegionID = nil
        self.lastExportResult = nil
    }

    var selectedFile: FileItem? {
        files.first { $0.id == selectedFileID }
    }

    var selectedDocumentPage: PageItem? {
        selectedFile?.pages.first { $0.id == selectedPageID }
    }

    var supportedImportTypes: String {
        L10n.Common.supportedV0ImportTypes
    }

    var importGuidanceMessage: String {
        fileImportService.importGuidanceMessage()
    }

    var canvasTitle: String {
        pdfRenderService.canvasTitle(for: selectedDocumentPage)
    }

    var ocrSummary: String {
        ocrService.availabilitySummary
    }

    var barcodeSummary: String {
        barcodeService.statusSummary
    }

    var totalPageCount: Int {
        files.reduce(0) { $0 + $1.pageCount }
    }

    var totalRegionCount: Int {
        files
            .flatMap(\.pages)
            .reduce(0) { $0 + $1.sensitiveRegions.count }
    }

    var selectedFileRegionCount: Int {
        selectedFile?.pages.reduce(0) { $0 + $1.sensitiveRegions.count } ?? 0
    }

    var selectedPageRegions: [SensitiveRegion] {
        selectedDocumentPage?.sensitiveRegions ?? []
    }

    var selectedRegion: SensitiveRegion? {
        selectedPageRegions.first { $0.id == selectedRegionID }
    }

    var hasSelectedRegion: Bool {
        selectedRegion != nil
    }

    var canDeleteSelectedRegion: Bool {
        isEditingEnabled && selectedRegion != nil
    }

    var maskPreviewSummary: String {
        maskComposeService.previewSummary(for: selectedPreset, regionCount: totalRegionCount)
    }

    var exportPreparedSummary: String {
        exportService.preparedSummary(for: files, preset: selectedPreset)
    }

    var hasImportedFiles: Bool {
        !files.isEmpty
    }

    var isReviewPageActive: Bool {
        selectedPage == .reviewEdit
    }

    var isEditingEnabled: Bool {
        previewDisplayMode == .original
    }

    var displayedPreviewRegions: [SensitiveRegion] {
        isEditingEnabled ? selectedPageRegions : []
    }

    var canUndoCurrentPageEdit: Bool {
        !undoStack.isEmpty
    }

    var canRedoCurrentPageEdit: Bool {
        !redoStack.isEmpty
    }

    var canDetectCurrentPageOCR: Bool {
        guard hasImportedFiles,
              selectedFile != nil,
              selectedDocumentPage != nil,
              let selectedPageID else {
            return false
        }

        return !recognizingPageIDs.contains(selectedPageID)
    }

    var currentPageOCRStateSummary: String {
        switch currentPageOCRState {
        case .idle:
            L10n.Review.ocrStateIdle
        case .running:
            L10n.Review.ocrStateRunning
        case .needsRerun:
            L10n.Review.ocrStateNeedsRerun
        case let .succeeded(candidateCount):
            L10n.Review.ocrStateSucceeded(candidateCount)
        case let .failed(reason):
            L10n.Review.ocrStateFailed(reason)
        }
    }

    var selectedPageOCRCandidates: [OCRSensitiveCandidate] {
        guard let selectedPageID else {
            return []
        }

        return ocrCandidates.filter { $0.pageID == selectedPageID }
    }

    var visibleSelectedPageOCRCandidates: [OCRSensitiveCandidate] {
        let cacheKey = VisibleCandidateCacheKey(
            pageID: selectedPageID,
            includedCategories: ocrDetectionOptions.includedCategories,
            revision: ocrCandidatesRevision
        )

        if cacheKey == visibleCandidatesCacheKey {
            return visibleCandidatesCache
        }

        let includedCategories = ocrDetectionOptions.includedCategories

        let candidates = selectedPageOCRCandidates
            .filter { includedCategories.contains($0.category) }
            .sorted { left, right in
                if left.orderIndex != right.orderIndex {
                    return left.orderIndex < right.orderIndex
                }

                return candidatePositionPrecedes(left, right)
            }

        visibleCandidatesCacheKey = cacheKey
        visibleCandidatesCache = candidates
        return candidates
    }

    var hasVisibleSelectedPageOCRCandidates: Bool {
        !visibleSelectedPageOCRCandidates.isEmpty
    }

    var selectedCanvasScrollOffset: CGPoint {
        guard let selectedPageID else {
            return .zero
        }

        return canvasScrollOffsets[selectedPageID] ?? .zero
    }

    func canvasZoomPercentageText(
        contentSize: CGSize?,
        viewportSize: CGSize
    ) -> String {
        let percent = Int((resolvedCanvasZoomScale(
            contentSize: contentSize,
            viewportSize: viewportSize
        ) * 100).rounded())

        return "\(percent)%"
    }

    func resolvedCanvasZoomScale(
        contentSize: CGSize?,
        viewportSize: CGSize
    ) -> CGFloat {
        guard let contentSize,
              contentSize.width > 0,
              contentSize.height > 0,
              viewportSize.width > 0,
              viewportSize.height > 0,
              let selectedPageID else {
            return 1
        }

        let zoomState = canvasZoomStates[selectedPageID] ?? CanvasZoomState()

        switch zoomState.mode {
        case .fitWindow:
            let widthScale = viewportSize.width / contentSize.width
            let heightScale = viewportSize.height / contentSize.height
            return max(min(widthScale, heightScale), 0.01)
        case .fitWidth:
            return max(viewportSize.width / contentSize.width, 0.01)
        case .custom:
            return clampedCanvasZoomScale(zoomState.customScale)
        }
    }

    func zoomCanvasIn(
        contentSize: CGSize?,
        viewportSize: CGSize
    ) {
        let currentScale = resolvedCanvasZoomScale(contentSize: contentSize, viewportSize: viewportSize)
        setSelectedCanvasCustomZoom(max(currentScale, minimumCanvasZoomScale) * canvasZoomStep)
    }

    func zoomCanvasOut(
        contentSize: CGSize?,
        viewportSize: CGSize
    ) {
        let currentScale = resolvedCanvasZoomScale(contentSize: contentSize, viewportSize: viewportSize)
        setSelectedCanvasCustomZoom(max(currentScale, minimumCanvasZoomScale) / canvasZoomStep)
    }

    func fitCanvasToWindow() {
        setSelectedCanvasZoomMode(.fitWindow, resetScroll: true)
    }

    func fitCanvasToWidth() {
        setSelectedCanvasZoomMode(.fitWidth, resetScroll: true)
    }

    func resetCanvasZoomToActualSize() {
        setSelectedCanvasCustomZoom(1, resetScroll: true)
    }

    func isCustomFieldEnabled(_ field: MaskCustomField) -> Bool {
        selectedCustomFields.contains(field)
    }

    func setCustomField(_ field: MaskCustomField, isEnabled: Bool) {
        if isEnabled {
            selectedCustomFields.insert(field)
        } else {
            selectedCustomFields.remove(field)
        }
    }

    func updateSelectedCanvasScrollOffset(_ offset: CGPoint) {
        guard let selectedPageID else {
            return
        }

        canvasScrollOffsets[selectedPageID] = offset
    }

    var canGoToPreviousPage: Bool {
        guard let pages = selectedFile?.pages,
              let selectedPageID,
              let pageIndex = pages.firstIndex(where: { $0.id == selectedPageID }) else {
            return false
        }

        return pageIndex > 0
    }

    var canGoToNextPage: Bool {
        guard let pages = selectedFile?.pages,
              let selectedPageID,
              let pageIndex = pages.firstIndex(where: { $0.id == selectedPageID }) else {
            return false
        }

        return pageIndex < pages.index(before: pages.endIndex)
    }

    var shouldShowPagesCard: Bool {
        guard let selectedFile else {
            return false
        }

        return selectedFile.pageCount > 1
    }

    var canBeginExportFlow: Bool {
        hasImportedFiles
    }

    var canOpenExportDestination: Bool {
        lastExportResult != nil
    }

    var selectedFileDisplayLabel: String {
        selectedFile?.displayName ?? L10n.Review.noFileSelected
    }

    var selectedPageDisplayLabel: String {
        selectedDocumentPage?.title ?? L10n.Review.noPageSelected
    }

    var selectedSinglePageSidebarMetadata: String? {
        guard let selectedFile,
              selectedFile.pageCount == 1,
              let page = selectedFile.pages.first else {
            return nil
        }

        return L10n.Review.singlePageMetadata(
            pageSummary: pageSummary(for: page),
            status: page.status.displayTitle
        )
    }

    var selectedFileRegionsSummary: String {
        L10n.Common.selectedFileRegions(selectedFileRegionCount)
    }

    var totalSessionRegionsSummary: String {
        L10n.Common.totalSessionRegions(totalRegionCount)
    }

    var importedFilesCardSubtitle: String {
        if hasImportedFiles {
            return L10n.Import.importedFilesSummary(fileCount: files.count, pageCount: totalPageCount)
        }

        return L10n.Import.importedFilesSessionSummary
    }

    var canGoToReview: Bool {
        hasImportedFiles
    }

    var preparedFilesSummary: String {
        L10n.Common.fileCount(files.count)
    }

    var preparedPagesSummary: String {
        L10n.Common.totalPageCount(totalPageCount)
    }

    var preparedRegionsSummary: String {
        L10n.Common.currentProcessedRegions(totalRegionCount)
    }

    var lastExportDestinationPath: String? {
        lastExportResult?.destinationURL.path
    }

    var exportSuccessSummary: String? {
        guard let lastExportResult else {
            return nil
        }

        return L10n.Export.successCount(lastExportResult.successCount)
    }

    var exportFailureSummary: String? {
        guard let lastExportResult else {
            return nil
        }

        return L10n.Export.failureCount(lastExportResult.failureCount)
    }

    var processedExportFilesSummary: String {
        guard let lastExportResult else {
            return L10n.Common.fileCount(files.count)
        }

        return L10n.Common.fileCount(lastExportResult.successCount + lastExportResult.failureCount)
    }

    var successfulExportFileNames: [String] {
        guard let lastExportResult else {
            return []
        }

        let failedFileNames = Set(lastExportResult.failures.map(\.fileName))

        return files
            .filter { !failedFileNames.contains($0.displayName) }
            .prefix(lastExportResult.successCount)
            .map(exportedDisplayName(for:))
    }

    var hasExportFailures: Bool {
        guard let lastExportResult else {
            return false
        }

        return !lastExportResult.failures.isEmpty
    }

    var selectedFileMetadataSummary: String? {
        guard let selectedFile else {
            return nil
        }

        return fileSummary(for: selectedFile)
    }

    var selectedPreviewMetadataSummary: String? {
        guard let selectedFile, let selectedDocumentPage else {
            return nil
        }

        return L10n.Review.previewMetadata(
            kind: selectedFile.kind.displayTitle,
            pageNumber: selectedDocumentPage.pageNumber,
            pageCount: selectedFile.pageCount
        )
    }

    var selectedPageStatusSummary: String? {
        if previewDisplayMode == .maskedPreview {
            return L10n.PageStatus.maskedPreview
        }

        return selectedDocumentPage?.status.displayTitle
    }

    func fileSummary(for file: FileItem) -> String {
        L10n.Common.filePageSummary(kind: file.kind.displayTitle, pageCount: file.pageCount)
    }

    func pageSummary(for page: PageItem) -> String {
        L10n.Common.regionCount(page.sensitiveRegions.count)
    }

    func importFiles() {
        importErrorMessage = nil

        do {
            let importedFiles = try fileImportService.importFiles()

            guard !importedFiles.isEmpty else {
                return
            }

            let shouldSelectImportedContent = selectedFile == nil
            files.append(contentsOf: importedFiles)

            if shouldSelectImportedContent, let firstImportedFile = importedFiles.first {
                applySelection(for: firstImportedFile, preferredPageID: firstImportedFile.pages.first?.id)
            } else if selectedPageID == nil {
                if let selectedFile {
                    applySelection(for: selectedFile, preferredPageID: selectedFile.pages.first?.id)
                }
            }
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    func goToReview() {
        guard canGoToReview else {
            return
        }

        if selectedFile == nil, let firstFile = files.first {
            applySelection(for: firstFile, preferredPageID: firstFile.pages.first?.id)
        }

        selectedPage = .reviewEdit
    }

    func selectFile(_ fileID: FileItem.ID) {
        guard let file = files.first(where: { $0.id == fileID }) else {
            return
        }

        let preferredPageID = lastSelectedPageByFileID[fileID] ?? file.pages.first?.id
        applySelection(for: file, preferredPageID: preferredPageID)
    }

    func selectPage(_ pageID: PageItem.ID) {
        guard let selectedFile, selectedFile.pages.contains(where: { $0.id == pageID }) else {
            return
        }

        selectedPageID = pageID
        selectedRegionID = nil
        selectedOCRCandidateID = nil
        clearPageHistory()
        syncCurrentOCRStateForSelection()

        if let selectedFileID {
            lastSelectedPageByFileID[selectedFileID] = pageID
        }

        schedulePreviewRefresh()
    }

    func selectRegion(_ regionID: SensitiveRegion.ID?) {
        selectedOCRCandidateID = nil

        guard let regionID else {
            selectedRegionID = nil
            return
        }

        guard selectedPageRegions.contains(where: { $0.id == regionID }) else {
            selectedRegionID = nil
            return
        }

        guard regionID != selectedRegionID else {
            return
        }

        selectedRegionID = regionID
    }

    func clearSelectedRegionSelection() {
        selectedRegionID = nil
        selectedOCRCandidateID = nil
    }

    func createRegion(with bounds: NormalizedRect) {
        let clampedBounds = bounds.clamped()
        guard clampedBounds.width > 0, clampedBounds.height > 0 else {
            return
        }

        let startedImplicitTransaction = beginImplicitPageEditTransactionIfNeeded()
        var createdRegionID: SensitiveRegion.ID?
        mutateSelectedPage { page in
            let region = SensitiveRegion(
                kind: .custom,
                bounds: clampedBounds,
                isMasked: true
            )
            page.sensitiveRegions.append(region)
            createdRegionID = region.id
        }

        selectedRegionID = createdRegionID
        selectedOCRCandidateID = nil

        if startedImplicitTransaction {
            endPageEditTransaction()
        }
    }

    func updateRegion(_ regionID: SensitiveRegion.ID, bounds: NormalizedRect) {
        let startedImplicitTransaction = beginImplicitPageEditTransactionIfNeeded()
        mutateSelectedPage { page in
            guard let regionIndex = page.sensitiveRegions.firstIndex(where: { $0.id == regionID }) else {
                return
            }

            page.sensitiveRegions[regionIndex].bounds = bounds.clamped()
        }

        if startedImplicitTransaction {
            endPageEditTransaction()
        }
    }

    func deleteSelectedRegion() {
        guard canDeleteSelectedRegion, let selectedRegionID else {
            return
        }

        let startedImplicitTransaction = beginImplicitPageEditTransactionIfNeeded()
        mutateSelectedPage { page in
            page.sensitiveRegions.removeAll { $0.id == selectedRegionID }
        }

        markOCRCandidatesPending(linkedTo: selectedRegionID)
        self.selectedRegionID = nil

        if startedImplicitTransaction {
            endPageEditTransaction()
        }
    }

    func beginPageEditTransaction() {
        guard let selectedPageID else {
            return
        }

        if historyPageID != selectedPageID {
            clearPageHistory()
            historyPageID = selectedPageID
        }

        guard !isPageEditTransactionOpen, let snapshot = currentPageEditSnapshot else {
            return
        }

        undoStack.append(snapshot)
        if undoStack.count > 20 {
            undoStack.removeFirst(undoStack.count - 20)
        }
        redoStack.removeAll()
        isPageEditTransactionOpen = true
    }

    func endPageEditTransaction() {
        isPageEditTransactionOpen = false
    }

    func undoCurrentPageEdit() {
        guard let snapshot = undoStack.popLast(),
              let currentSnapshot = currentPageEditSnapshot else {
            return
        }

        redoStack.append(currentSnapshot)
        applyPageEditSnapshot(snapshot)
        reconcileOCRCandidatesWithSelectedPage()
        isPageEditTransactionOpen = false
    }

    func redoCurrentPageEdit() {
        guard let snapshot = redoStack.popLast(),
              let currentSnapshot = currentPageEditSnapshot else {
            return
        }

        undoStack.append(currentSnapshot)
        applyPageEditSnapshot(snapshot)
        reconcileOCRCandidatesWithSelectedPage()
        isPageEditTransactionOpen = false
    }

    func goToPreviousPage() {
        guard let pages = selectedFile?.pages,
              let selectedPageID,
              let currentIndex = pages.firstIndex(where: { $0.id == selectedPageID }),
              currentIndex > 0 else {
            return
        }

        selectPage(pages[currentIndex - 1].id)
    }

    func goToNextPage() {
        guard let pages = selectedFile?.pages,
              let selectedPageID,
              let currentIndex = pages.firstIndex(where: { $0.id == selectedPageID }),
              currentIndex < pages.index(before: pages.endIndex) else {
            return
        }

        selectPage(pages[currentIndex + 1].id)
    }

    func togglePreviewDisplayMode() {
        previewDisplayMode = previewDisplayMode.toggled()
    }

    func detectCurrentPageOCR() {
        guard let selectedFile,
              let selectedDocumentPage,
              let selectedFileID,
              let selectedPageID else {
            currentPageOCRState = .failed(L10n.Review.ocrStateNoPage)
            return
        }

        guard !recognizingPageIDs.contains(selectedPageID) else {
            pageOCRStates[selectedPageID] = .running
            currentPageOCRState = .running
            return
        }

        previewDisplayMode = .original
        let detectionOptions = ocrDetectionOptions
        recognizingPageIDs.insert(selectedPageID)
        pageOCRStates[selectedPageID] = .running
        currentPageOCRState = .running

        Task.detached(priority: .userInitiated) {
            let result: Result<[OCRSensitiveCandidate], Error>

            do {
                let candidates = try await DefaultOCRService().candidates(
                    for: selectedFile,
                    page: selectedDocumentPage,
                    options: detectionOptions
                )
                result = .success(candidates)
            } catch {
                result = .failure(error)
            }

            await MainActor.run {
                self.finishCurrentPageOCR(
                    result,
                    fileID: selectedFileID,
                    pageID: selectedPageID,
                    detectionOptions: detectionOptions
                )
            }
        }
    }

    func selectOCRCandidate(_ candidateID: OCRSensitiveCandidate.ID) {
        guard let candidate = ocrCandidates.first(where: { $0.id == candidateID }) else {
            return
        }

        selectedOCRCandidateID = candidateID

        if let linkedRegionID = candidate.linkedRegionID,
           selectedPageRegions.contains(where: { $0.id == linkedRegionID }) {
            selectRegion(linkedRegionID)
            selectedOCRCandidateID = candidateID
        } else {
            selectedRegionID = nil
        }
    }

    func maskOCRCandidate(_ candidateID: OCRSensitiveCandidate.ID) {
        guard let candidateIndex = ocrCandidates.firstIndex(where: { $0.id == candidateID }) else {
            return
        }

        let candidate = ocrCandidates[candidateIndex]
        guard candidate.status == .pending,
              candidate.pageID == selectedPageID,
              candidate.boundingBox.width > 0,
              candidate.boundingBox.height > 0 else {
            return
        }

        let startedImplicitTransaction = beginImplicitPageEditTransactionIfNeeded(for: candidate.pageID)
        var createdRegionID: SensitiveRegion.ID?

        mutateSelectedPage { page in
            let region = SensitiveRegion(
                kind: candidate.category.regionKind,
                source: .ocr,
                bounds: candidate.boundingBox,
                confidence: candidate.confidence,
                isMasked: true
            )
            page.sensitiveRegions.append(region)
            createdRegionID = region.id
        }

        if let createdRegionID {
            ocrCandidates[candidateIndex].status = .masked
            ocrCandidates[candidateIndex].linkedRegionID = createdRegionID
            selectedRegionID = createdRegionID
            selectedOCRCandidateID = candidateID
        }

        if startedImplicitTransaction {
            endPageEditTransaction()
        }
    }

    func ignoreOCRCandidate(_ candidateID: OCRSensitiveCandidate.ID) {
        guard let candidateIndex = ocrCandidates.firstIndex(where: { $0.id == candidateID }) else {
            return
        }

        guard ocrCandidates[candidateIndex].status == .pending else {
            return
        }

        ocrCandidates[candidateIndex].status = .ignored
    }

    func undoOCRCandidate(_ candidateID: OCRSensitiveCandidate.ID) {
        guard let candidateIndex = ocrCandidates.firstIndex(where: { $0.id == candidateID }) else {
            return
        }

        let candidate = ocrCandidates[candidateIndex]
        guard candidate.pageID == selectedPageID,
              candidate.status == .masked || candidate.status == .ignored else {
            return
        }

        if candidate.status == .masked,
           let linkedRegionID = candidate.linkedRegionID {
            let startedImplicitTransaction = beginImplicitPageEditTransactionIfNeeded(for: candidate.pageID)
            mutateSelectedPage { page in
                guard let regionIndex = page.sensitiveRegions.firstIndex(where: { $0.id == linkedRegionID }),
                      page.sensitiveRegions[regionIndex].source == .ocr else {
                    return
                }

                page.sensitiveRegions.remove(at: regionIndex)
            }

            if selectedRegionID == linkedRegionID {
                selectedRegionID = nil
            }

            if startedImplicitTransaction {
                endPageEditTransaction()
            }
        }

        ocrCandidates[candidateIndex].status = .pending
        ocrCandidates[candidateIndex].linkedRegionID = nil

        if selectedOCRCandidateID == candidateID {
            selectedRegionID = nil
        }
    }

    func beginExportFlow() {
        guard canBeginExportFlow else {
            return
        }

        guard let destinationURL = exportService.chooseDestination() else {
            return
        }

        lastExportResult = exportService.exportSession(
            files: files,
            preset: selectedPreset,
            destinationURL: destinationURL
        )
        selectedPage = .exportSummary
    }

    func openExportDestination() {
        guard let destinationURL = lastExportResult?.destinationURL else {
            return
        }

        exportService.openFolder(at: destinationURL)
    }

    func continueNextBatch() {
        files.removeAll()
        selectedFileID = nil
        selectedPageID = nil
        selectedRegionID = nil
        selectedOCRCandidateID = nil
        importErrorMessage = nil
        lastExportResult = nil
        currentPageOCRState = .idle
        ocrCandidates.removeAll()
        recognizingPageIDs.removeAll()
        pageOCRStates.removeAll()
        lastSelectedPageByFileID.removeAll()
        canvasZoomStates.removeAll()
        canvasScrollOffsets.removeAll()
        clearPageHistory()
        previewDisplayMode = .original
        resetPreviewRendering()
        selectedPage = .import
    }

    private func schedulePreviewRefresh() {
        guard let request = makePreviewRenderRequest() else {
            resetPreviewRendering()
            return
        }

        if renderedPreviewKey == request.contentKey {
            return
        }

        if pendingPreviewKey == request.contentKey {
            return
        }

        if let cachedContent = previewContentCache[request.contentKey] {
            previewRenderTask?.cancel()
            pendingPreviewKey = nil
            previewContent = cachedContent
            renderedPreviewKey = request.contentKey
            return
        }

        previewRenderTask?.cancel()
        pendingPreviewKey = request.contentKey
        previewContent = .empty

        let renderer = previewRenderer
        previewRenderTask = Task(priority: .userInitiated) { [renderer, request] in
            let renderedContent = await renderer.render(request)

            await MainActor.run {
                guard self.pendingPreviewKey == request.contentKey else {
                    return
                }

                self.previewContentCache[request.contentKey] = renderedContent
                self.previewContent = renderedContent
                self.renderedPreviewKey = request.contentKey
                self.pendingPreviewKey = nil
                self.previewRenderTask = nil
            }
        }
    }

    private func resetPreviewRendering() {
        previewRenderTask?.cancel()
        previewRenderTask = nil
        pendingPreviewKey = nil
        renderedPreviewKey = nil
        previewContent = .empty
        previewContentCache.removeAll()
        Task {
            await previewRenderer.removeAllCachedContent()
        }
    }

    private func makePreviewRenderRequest() -> PreviewRenderRequest? {
        guard let selectedFile,
              let selectedDocumentPage else {
            return nil
        }

        let baseKey = PreviewBaseCacheKey(
            fileID: selectedFile.id,
            pageID: selectedDocumentPage.id,
            sourceURL: selectedFile.sourceURL,
            fileKind: selectedFile.kind,
            sourcePageIndex: selectedDocumentPage.sourcePageIndex,
            pageNumber: selectedDocumentPage.pageNumber
        )
        let contentKey = PreviewContentCacheKey(
            baseKey: baseKey,
            displayMode: previewDisplayMode.rawValue,
            preset: previewDisplayMode == .maskedPreview ? selectedPreset : nil,
            regions: previewDisplayMode == .maskedPreview ? selectedDocumentPage.sensitiveRegions : []
        )

        return PreviewRenderRequest(
            file: selectedFile,
            page: selectedDocumentPage,
            displayMode: previewDisplayMode,
            preset: selectedPreset,
            baseKey: baseKey,
            contentKey: contentKey
        )
    }

    private func finishCurrentPageOCR(
        _ result: Result<[OCRSensitiveCandidate], Error>,
        fileID: FileItem.ID,
        pageID: PageItem.ID,
        detectionOptions: OCRDetectionOptions
    ) {
        recognizingPageIDs.remove(pageID)

        guard pageLocation(fileID: fileID, pageID: pageID) != nil else {
            pageOCRStates[pageID] = nil
            syncCurrentOCRStateForSelection()
            return
        }

        switch result {
        case let .success(candidates):
            guard ocrDetectionOptions == detectionOptions else {
                pageOCRStates[pageID] = .needsRerun
                syncCurrentOCRStateForSelection()
                return
            }

            let candidateCount = replaceOCRCandidates(
                candidates,
                fileID: fileID,
                pageID: pageID
            )
            pageOCRStates[pageID] = .succeeded(candidateCount: candidateCount)
        case let .failure(error):
            pageOCRStates[pageID] = .failed(error.localizedDescription)
        }

        syncCurrentOCRStateForSelection()
    }

    private func syncCurrentOCRStateForSelection() {
        guard let selectedPageID else {
            currentPageOCRState = .idle
            return
        }

        if recognizingPageIDs.contains(selectedPageID) {
            currentPageOCRState = .running
        } else {
            currentPageOCRState = pageOCRStates[selectedPageID] ?? .idle
        }
    }

    private func applySelection(for file: FileItem, preferredPageID: PageItem.ID?) {
        selectedFileID = file.id
        selectedPageID = resolvedPageID(in: file, preferredPageID: preferredPageID)
        selectedRegionID = nil
        selectedOCRCandidateID = nil
        clearPageHistory()
        syncCurrentOCRStateForSelection()

        if let selectedPageID {
            lastSelectedPageByFileID[file.id] = selectedPageID
        }

        schedulePreviewRefresh()
    }

    private func resolvedPageID(in file: FileItem, preferredPageID: PageItem.ID?) -> PageItem.ID? {
        if let preferredPageID, file.pages.contains(where: { $0.id == preferredPageID }) {
            return preferredPageID
        }

        return file.pages.first?.id
    }

    private func mutateSelectedPage(_ mutation: (inout PageItem) -> Void) {
        guard let selection = selectedPageLocation else {
            return
        }

        var updatedFiles = files
        mutation(&updatedFiles[selection.fileIndex].pages[selection.pageIndex])
        files = updatedFiles
    }

    private func mutatePage(
        fileID: FileItem.ID,
        pageID: PageItem.ID,
        _ mutation: (inout PageItem) -> Void
    ) {
        guard let fileIndex = files.firstIndex(where: { $0.id == fileID }),
              let pageIndex = files[fileIndex].pages.firstIndex(where: { $0.id == pageID }) else {
            return
        }

        var updatedFiles = files
        mutation(&updatedFiles[fileIndex].pages[pageIndex])
        files = updatedFiles
    }

    private func replaceOCRCandidates(
        _ candidates: [OCRSensitiveCandidate],
        fileID: FileItem.ID,
        pageID: PageItem.ID
    ) -> Int {
        guard pageLocation(fileID: fileID, pageID: pageID) != nil else {
            return 0
        }

        let existingPageCandidates = ocrCandidates
            .filter { $0.pageID == pageID }
            .sorted(by: candidateOrderPrecedes)
        let incomingPageCandidates = candidates
            .filter { $0.pageID == pageID }
            .sorted(by: candidatePositionPrecedes)
        let pageCandidates = deduplicatedOCRCandidates(
            existing: existingPageCandidates,
            incoming: incomingPageCandidates
        )

        var updatedCandidates = ocrCandidates.filter { $0.pageID != pageID }
        var replacedCount = 0

        for candidate in pageCandidates {
            guard candidate.boundingBox.width > 0, candidate.boundingBox.height > 0 else {
                continue
            }

            var newCandidate = candidate
            newCandidate.orderIndex = replacedCount
            updatedCandidates.append(newCandidate)
            replacedCount += 1
        }

        ocrCandidates = updatedCandidates

        if let selectedOCRCandidateID,
           !ocrCandidates.contains(where: { $0.id == selectedOCRCandidateID }) {
            self.selectedOCRCandidateID = nil
            selectedRegionID = nil
        }

        return replacedCount
    }

    private func deduplicatedOCRCandidates(
        existing: [OCRSensitiveCandidate],
        incoming: [OCRSensitiveCandidate]
    ) -> [OCRSensitiveCandidate] {
        var mergedCandidates: [OCRSensitiveCandidate] = []

        for candidate in existing + incoming {
            guard candidate.boundingBox.width > 0, candidate.boundingBox.height > 0 else {
                continue
            }

            if let duplicateIndex = mergedCandidates.firstIndex(where: { areDuplicateOCRCandidates($0, candidate) }) {
                mergedCandidates[duplicateIndex] = preferredOCRCandidate(
                    existing: mergedCandidates[duplicateIndex],
                    incoming: candidate
                )
            } else {
                mergedCandidates.append(candidate)
            }
        }

        return mergedCandidates
    }

    private func areDuplicateOCRCandidates(
        _ left: OCRSensitiveCandidate,
        _ right: OCRSensitiveCandidate
    ) -> Bool {
        guard left.pageID == right.pageID,
              candidateCategoriesOverlap(left.category, right.category),
              canMergeLinkedOCRCandidates(left, right),
              sameOCRCandidateLocation(left, right) else {
            return false
        }

        let leftValue = normalizedCandidateText(left.text)
        let rightValue = normalizedCandidateText(right.text)

        if left.detectionKind == .labelFallback || right.detectionKind == .labelFallback {
            return true
        }

        return !leftValue.isEmpty && leftValue == rightValue
    }

    private func canMergeLinkedOCRCandidates(
        _ left: OCRSensitiveCandidate,
        _ right: OCRSensitiveCandidate
    ) -> Bool {
        guard let leftRegionID = left.linkedRegionID,
              let rightRegionID = right.linkedRegionID else {
            return true
        }

        return leftRegionID == rightRegionID
    }

    private func sameOCRCandidateLocation(
        _ left: OCRSensitiveCandidate,
        _ right: OCRSensitiveCandidate
    ) -> Bool {
        if ocrBoxesReferToSameLocation(left.boundingBox, right.boundingBox) {
            return true
        }

        if let leftLabel = left.labelBoundingBox,
           let rightLabel = right.labelBoundingBox,
           ocrBoxesReferToSameLocation(leftLabel, rightLabel) {
            return true
        }

        if let leftLabel = left.labelBoundingBox,
           ocrBoxesReferToSameLocation(leftLabel, right.boundingBox) {
            return true
        }

        if let rightLabel = right.labelBoundingBox,
           ocrBoxesReferToSameLocation(left.boundingBox, rightLabel) {
            return true
        }

        return false
    }

    private func ocrBoxesReferToSameLocation(
        _ left: NormalizedRect,
        _ right: NormalizedRect
    ) -> Bool {
        normalizedRectIoU(left, right) >= 0.18
            || left.substantiallyOverlaps(right, threshold: 0.30)
            || ocrBoxesAreVeryClose(left, right)
    }

    private func ocrBoxesAreVeryClose(
        _ left: NormalizedRect,
        _ right: NormalizedRect
    ) -> Bool {
        let centerDeltaX = abs(centerX(of: left) - centerX(of: right))
        let centerDeltaY = abs(centerY(of: left) - centerY(of: right))
        let xAllowance = max(left.width, right.width) * 0.85 + 0.08
        let yAllowance = max(left.height, right.height) * 1.25 + 0.045

        return centerDeltaX <= xAllowance && centerDeltaY <= yAllowance
    }

    private func normalizedRectIoU(
        _ left: NormalizedRect,
        _ right: NormalizedRect
    ) -> Double {
        let intersection = normalizedRectIntersectionArea(left, right)
        let union = left.width * left.height + right.width * right.height - intersection

        guard union > 0 else {
            return 0
        }

        return intersection / union
    }

    private func normalizedRectIntersectionArea(
        _ left: NormalizedRect,
        _ right: NormalizedRect
    ) -> Double {
        let width = max(0, min(maxX(of: left), maxX(of: right)) - max(left.x, right.x))
        let height = max(0, min(maxY(of: left), maxY(of: right)) - max(left.y, right.y))

        return width * height
    }

    private func preferredOCRCandidate(
        existing: OCRSensitiveCandidate,
        incoming: OCRSensitiveCandidate
    ) -> OCRSensitiveCandidate {
        if statusPriority(existing.status) != statusPriority(incoming.status) {
            return statusPriority(existing.status) > statusPriority(incoming.status) ? existing : incoming
        }

        if existing.linkedRegionID != nil, incoming.linkedRegionID == nil {
            return existing
        }

        if incoming.linkedRegionID != nil, existing.linkedRegionID == nil {
            return incoming
        }

        if (existing.sourceLabelText?.isEmpty == false) != (incoming.sourceLabelText?.isEmpty == false) {
            return incoming.sourceLabelText?.isEmpty == false ? incoming : existing
        }

        let existingHasExplicitValue = existing.detectionKind != .labelFallback
        let incomingHasExplicitValue = incoming.detectionKind != .labelFallback

        if existingHasExplicitValue != incomingHasExplicitValue {
            return incomingHasExplicitValue ? incoming : existing
        }

        let existingConfidence = existing.confidence ?? 0
        let incomingConfidence = incoming.confidence ?? 0
        if existingConfidence != incomingConfidence {
            return incomingConfidence > existingConfidence ? incoming : existing
        }

        return existing
    }

    private func statusPriority(_ status: OCRCandidateStatus) -> Int {
        switch status {
        case .masked:
            3
        case .ignored:
            2
        case .pending:
            1
        }
    }

    private func candidateOrderPrecedes(
        _ left: OCRSensitiveCandidate,
        _ right: OCRSensitiveCandidate
    ) -> Bool {
        if left.orderIndex != right.orderIndex {
            return left.orderIndex < right.orderIndex
        }

        return candidatePositionPrecedes(left, right)
    }

    private func maxX(of rect: NormalizedRect) -> Double {
        rect.x + rect.width
    }

    private func maxY(of rect: NormalizedRect) -> Double {
        rect.y + rect.height
    }

    private func centerX(of rect: NormalizedRect) -> Double {
        rect.x + rect.width / 2
    }

    private func centerY(of rect: NormalizedRect) -> Double {
        rect.y + rect.height / 2
    }

    private var ocrDetectionOptions: OCRDetectionOptions {
        OCRDetectionOptions(
            preset: selectedPreset,
            customFields: selectedCustomFields
        )
    }

    private var selectedPageLocation: (fileIndex: Int, pageIndex: Int)? {
        guard let selectedFileID,
              let selectedPageID else {
            return nil
        }

        return pageLocation(fileID: selectedFileID, pageID: selectedPageID)
    }

    private func pageLocation(
        fileID: FileItem.ID,
        pageID: PageItem.ID
    ) -> (fileIndex: Int, pageIndex: Int)? {
        guard let fileIndex = files.firstIndex(where: { $0.id == fileID }),
              let pageIndex = files[fileIndex].pages.firstIndex(where: { $0.id == pageID }) else {
            return nil
        }

        return (fileIndex, pageIndex)
    }

    private func beginImplicitPageEditTransactionIfNeeded() -> Bool {
        guard !isPageEditTransactionOpen else {
            return false
        }

        beginPageEditTransaction()
        return true
    }

    private func beginImplicitPageEditTransactionIfNeeded(for pageID: PageItem.ID) -> Bool {
        guard selectedPageID == pageID else {
            return false
        }

        return beginImplicitPageEditTransactionIfNeeded()
    }

    private func matchingCandidateIndex(for candidate: OCRSensitiveCandidate) -> Int? {
        ocrCandidates.firstIndex { existingCandidate in
            existingCandidate.pageID == candidate.pageID
                && candidateCategoriesOverlap(existingCandidate.category, candidate.category)
                && normalizedCandidateText(existingCandidate.text) == normalizedCandidateText(candidate.text)
                && existingCandidate.boundingBox.substantiallyOverlaps(candidate.boundingBox)
        }
    }

    private func candidateCategoriesOverlap(
        _ left: OCRCandidateCategory,
        _ right: OCRCandidateCategory
    ) -> Bool {
        if left == right {
            return true
        }

        let relatedPairs: [[OCRCandidateCategory]] = [
            [.chineseID, .documentNumber],
            [.phone, .fax],
            [.date, .birthday, .examDate]
        ]

        return relatedPairs.contains { Set($0).isSuperset(of: Set([left, right])) }
    }

    private func markOCRCandidatesPending(linkedTo regionID: SensitiveRegion.ID) {
        for index in ocrCandidates.indices where ocrCandidates[index].linkedRegionID == regionID {
            ocrCandidates[index].status = .pending
            ocrCandidates[index].linkedRegionID = nil
        }
    }

    private func clearHiddenOCRCandidateSelection() {
        guard let selectedOCRCandidateID,
              let candidate = ocrCandidates.first(where: { $0.id == selectedOCRCandidateID }),
              !ocrDetectionOptions.includedCategories.contains(candidate.category) else {
            return
        }

        self.selectedOCRCandidateID = nil
    }

    private func handleOCRDisplayOptionsChanged() {
        clearHiddenOCRCandidateSelection()

        if let selectedPageID,
           selectedDocumentPage != nil,
           !recognizingPageIDs.contains(selectedPageID) {
            pageOCRStates[selectedPageID] = .needsRerun
            currentPageOCRState = .needsRerun
        }
    }

    private func reconcileOCRCandidatesWithSelectedPage() {
        let selectedRegionIDs = Set(selectedPageRegions.map(\.id))

        for index in ocrCandidates.indices where ocrCandidates[index].pageID == selectedPageID {
            guard let linkedRegionID = ocrCandidates[index].linkedRegionID,
                  !selectedRegionIDs.contains(linkedRegionID) else {
                continue
            }

            ocrCandidates[index].status = .pending
            ocrCandidates[index].linkedRegionID = nil
        }
    }

    private func normalizedCandidateText(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func nextOCRCandidateOrderIndex(on pageID: PageItem.ID) -> Int {
        let existingOrderIndexes = ocrCandidates
            .filter { $0.pageID == pageID && $0.orderIndex != .max }
            .map(\.orderIndex)

        return (existingOrderIndexes.max() ?? -1) + 1
    }

    private func setSelectedCanvasCustomZoom(
        _ scale: CGFloat,
        resetScroll: Bool = false
    ) {
        guard let selectedPageID else {
            return
        }

        canvasZoomStates[selectedPageID] = CanvasZoomState(
            mode: .custom,
            customScale: clampedCanvasZoomScale(scale)
        )

        if resetScroll {
            canvasScrollOffsets[selectedPageID] = .zero
        }
    }

    private func setSelectedCanvasZoomMode(
        _ mode: CanvasZoomMode,
        resetScroll: Bool
    ) {
        guard let selectedPageID else {
            return
        }

        let existingScale = canvasZoomStates[selectedPageID]?.customScale ?? 1
        canvasZoomStates[selectedPageID] = CanvasZoomState(
            mode: mode,
            customScale: existingScale
        )

        if resetScroll {
            canvasScrollOffsets[selectedPageID] = .zero
        }
    }

    private func clampedCanvasZoomScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minimumCanvasZoomScale), maximumCanvasZoomScale)
    }

    private func candidatePositionPrecedes(
        _ left: OCRSensitiveCandidate,
        _ right: OCRSensitiveCandidate
    ) -> Bool {
        let leftCenterY = left.boundingBox.y + left.boundingBox.height / 2
        let rightCenterY = right.boundingBox.y + right.boundingBox.height / 2
        let sameRowThreshold = max(left.boundingBox.height, right.boundingBox.height) * 0.75
        let isSameRow = abs(leftCenterY - rightCenterY) <= max(sameRowThreshold, 0.015)

        if isSameRow, left.boundingBox.x != right.boundingBox.x {
            return left.boundingBox.x < right.boundingBox.x
        }

        if left.boundingBox.y != right.boundingBox.y {
            return left.boundingBox.y < right.boundingBox.y
        }

        return left.boundingBox.x < right.boundingBox.x
    }

    private func clearPageHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        historyPageID = selectedPageID
        isPageEditTransactionOpen = false
    }

    private func applyPageEditSnapshot(_ snapshot: PageEditSnapshot) {
        mutateSelectedPage { page in
            page.sensitiveRegions = snapshot.regions
        }

        if let selectedRegionID = snapshot.selectedRegionID,
           selectedPageRegions.contains(where: { $0.id == selectedRegionID }) {
            self.selectedRegionID = selectedRegionID
        } else {
            self.selectedRegionID = nil
        }
    }

    private var currentPageEditSnapshot: PageEditSnapshot? {
        guard let selectedDocumentPage else {
            return nil
        }

        return PageEditSnapshot(
            regions: selectedDocumentPage.sensitiveRegions,
            selectedRegionID: selectedRegionID
        )
    }

    private func exportedDisplayName(for file: FileItem) -> String {
        let sourceURL = URL(fileURLWithPath: file.displayName)
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let fileExtension: String

        switch file.kind {
        case .pdf:
            fileExtension = "pdf"
        case .image:
            switch file.sourceURL?.pathExtension.lowercased() {
            case "jpg", "jpeg":
                fileExtension = "jpg"
            default:
                fileExtension = "png"
            }
        }

        return "\(baseName)_redacted.\(fileExtension)"
    }
}

private struct PageEditSnapshot {
    let regions: [SensitiveRegion]
    let selectedRegionID: SensitiveRegion.ID?
}

private actor PreviewRenderer {
    private let pdfRenderService = DefaultPDFRenderService()
    private let maskComposeService = DefaultMaskComposeService()
    private var contentCache: [PreviewContentCacheKey: DocumentPreviewContent] = [:]

    func render(_ request: PreviewRenderRequest) -> DocumentPreviewContent {
        if let cachedContent = contentCache[request.contentKey] {
            return cachedContent
        }

        let baseContent = pdfRenderService.previewContent(for: request.file, page: request.page)
        let resolvedContent: DocumentPreviewContent

        if request.displayMode == .maskedPreview,
           case let .raster(rasterContent) = baseContent {
            resolvedContent = .raster(
                maskComposeService.maskedPreview(
                    from: rasterContent,
                    regions: request.page.sensitiveRegions,
                    preset: request.preset
                )
            )
        } else {
            resolvedContent = baseContent
        }

        contentCache[request.contentKey] = resolvedContent
        return resolvedContent
    }

    func removeAllCachedContent() {
        contentCache.removeAll()
    }
}

nonisolated private struct PreviewRenderRequest {
    let file: FileItem
    let page: PageItem
    let displayMode: ReviewPreviewMode
    let preset: MaskPreset
    let baseKey: PreviewBaseCacheKey
    let contentKey: PreviewContentCacheKey
}

nonisolated private struct PreviewBaseCacheKey: Hashable {
    let fileID: FileItem.ID
    let pageID: PageItem.ID
    let sourceURL: URL?
    let fileKind: FileKind
    let sourcePageIndex: Int?
    let pageNumber: Int
}

nonisolated private struct PreviewContentCacheKey: Hashable {
    let baseKey: PreviewBaseCacheKey
    let displayMode: String
    let preset: MaskPreset?
    let regions: [SensitiveRegion]
}

nonisolated private struct VisibleCandidateCacheKey: Hashable {
    let pageID: PageItem.ID?
    let includedCategories: Set<OCRCandidateCategory>
    let revision: Int
}

enum CurrentPageOCRState: Equatable {
    case idle
    case running
    case needsRerun
    case succeeded(candidateCount: Int)
    case failed(String)

    var isRunning: Bool {
        if case .running = self {
            return true
        }

        return false
    }
}

private enum CanvasZoomMode: Equatable {
    case fitWindow
    case fitWidth
    case custom
}

private struct CanvasZoomState: Equatable {
    var mode: CanvasZoomMode = .fitWindow
    var customScale: CGFloat = 1
}
