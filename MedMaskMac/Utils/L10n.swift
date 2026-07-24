import Foundation

enum L10n {
    private static let table = "Localizable"

    private static func string(_ key: String, default defaultValue: String) -> String {
        Bundle.main.localizedString(forKey: key, value: defaultValue, table: table)
    }

    private static func formatted(
        _ key: String,
        default defaultValue: String,
        _ arguments: CVarArg...
    ) -> String {
        String(format: string(key, default: defaultValue), locale: Locale.current, arguments: arguments)
    }

    private static func countText(_ count: Int) -> String {
        count.formatted()
    }

    enum App {
        static let title = L10n.string("app.title", default: "MedMask Mac")
        static let sidebarSubtitle = L10n.string("app.sidebar_subtitle", default: "本地脱敏流程准备 PDF 或图像")
        static let pagePickerLabel = L10n.string("app.page_picker_label", default: "Page")
    }

    enum Navigation {
        static func title(for page: AppPage) -> String {
            switch page {
            case .import:
                L10n.string("nav.import.title", default: "Import")
            case .reviewEdit:
                L10n.string("nav.review.title", default: "Review / Edit")
            case .exportSummary:
                L10n.string("nav.export.title", default: "Export Summary")
            }
        }

        static func subtitle(for page: AppPage) -> String {
            switch page {
            case .import:
                L10n.string("nav.import.subtitle", default: "Prepare PDFs or images for a local redaction pass.")
            case .reviewEdit:
                L10n.string("nav.review.subtitle", default: "Review pages, place manual masks, and prepare the current session for export.")
            case .exportSummary:
                L10n.string("nav.export.subtitle", default: "Review export results for the current session and open the output folder.")
            }
        }
    }

    enum FileKind {
        static let pdf = L10n.string("file_kind.pdf", default: "PDF")
        static let image = L10n.string("file_kind.image", default: "Image")
    }

    enum FileStatus {
        static let imported = L10n.string("file_status.imported", default: "Imported")
        static let readyForReview = L10n.string("file_status.ready_for_review", default: "Ready For Review")
        static let needsAttention = L10n.string("file_status.needs_attention", default: "Needs Attention")
    }

    enum PageStatus {
        static let pendingDetection = L10n.string("page_status.pending_detection", default: "Pending Detection")
        static let readyForReview = L10n.string("page_status.ready_for_review", default: "Ready For Review")
        static let maskedPreview = L10n.string("page_status.masked_preview", default: "Preview")
    }

    enum Preset {
        static let standardTitle = L10n.string("preset.standard.title", default: "Standard Redaction")
        static let standardSummary = L10n.string("preset.standard.summary", default: "Detect name, phone number, ID number, outpatient number, inpatient number, medical record number, and other core identity fields.")
        static let strictTitle = L10n.string("preset.strict.title", default: "Strict Redaction")
        static let strictSummary = L10n.string("preset.strict.summary", default: "Adds demographics, dates, contact, facility, doctor, and bed information.")
        static let customTitle = L10n.string("preset.custom.title", default: "Custom Redaction")
        static let customSummary = L10n.string("preset.custom.summary", default: "Uses the enabled checklist fields for OCR suggestions.")
    }

    enum CustomField {
        static let name = L10n.string("preset.custom.field.name", default: "Name")
        static let phone = L10n.string("preset.custom.field.phone", default: "Phone")
        static let idNumber = L10n.string("preset.custom.field.id_number", default: "ID Number")
        static let medicalNumbers = L10n.string("preset.custom.field.medical_numbers", default: "Medical Numbers")
        static let sex = L10n.string("preset.custom.field.sex", default: "Gender")
        static let age = L10n.string("preset.custom.field.age", default: "Age")
        static let dates = L10n.string("preset.custom.field.dates", default: "Dates")
        static let address = L10n.string("preset.custom.field.address", default: "Address")
        static let email = L10n.string("preset.custom.field.email", default: "Email")
        static let hospitalDepartment = L10n.string("preset.custom.field.hospital_department", default: "Hospital/Department")
        static let doctor = L10n.string("preset.custom.field.doctor", default: "Doctor")
        static let staffSignature = L10n.string("preset.custom.field.staff_signature", default: "Staff / Signature")
    }

    enum Common {
        static let supportedV0ImportTypes = L10n.string("common.supported_v0_import_types", default: "PDF / PNG / JPG / JPEG")

        static func supportedFormats(_ types: String) -> String {
            L10n.formatted("common.supported_formats", default: "Supported: %@", types)
        }

        static func pageTitle(_ pageNumber: Int) -> String {
            L10n.formatted("common.page_title", default: "Page %@", countText(pageNumber))
        }

        static func pageCount(_ count: Int) -> String {
            L10n.formatted("common.page_count", default: "%@ page(s)", countText(count))
        }

        static func regionCount(_ count: Int) -> String {
            L10n.formatted("common.region_count", default: "%@ region(s)", countText(count))
        }

        static func fileCount(_ count: Int) -> String {
            L10n.formatted("common.file_count", default: "%@ file(s)", countText(count))
        }

        static func totalPageCount(_ count: Int) -> String {
            L10n.formatted("common.total_page_count", default: "%@ total page(s)", countText(count))
        }

        static func filePageSummary(kind: String, pageCount: Int) -> String {
            L10n.formatted("common.file_page_summary", default: "%@ • %@", kind, self.pageCount(pageCount))
        }

        static func selectedFileRegions(_ count: Int) -> String {
            L10n.formatted("common.selected_file_regions", default: "Selected file regions: %@", countText(count))
        }

        static func totalSessionRegions(_ count: Int) -> String {
            L10n.formatted("common.total_session_regions", default: "Total session regions: %@", countText(count))
        }

        static func currentProcessedRegions(_ count: Int) -> String {
            L10n.formatted("common.current_processed_regions", default: "当前已识别/已处理区域：%@", countText(count))
        }
    }

    enum Import {
        static let v0Title = L10n.string("import.v0.title", default: "导入批次")
        static let v0Description = L10n.string("import.v0.description", default: "选择本地 PDF 或图片文件，文件仅保留在当前会话内，不上传、不保存历史。")
        static let dropAreaTitle = L10n.string("import.v0.drop_area_title", default: "拖入检查单 PDF 或图片")
        static let dropAreaSubtitle = L10n.string("import.v0.drop_area_subtitle", default: "支持 PDF / PNG / JPG / JPEG，可批量导入")
        static let privacyTitle = L10n.string("import.v0.privacy_title", default: "隐私提示")
        static let privacyLocalOnly = L10n.string("import.v0.privacy_local_only", default: "仅本机处理")
        static let privacyNoUpload = L10n.string("import.v0.privacy_no_upload", default: "不登录、不上传、不云 OCR")
        static let privacySessionOnly = L10n.string("import.v0.privacy_session_only", default: "当前会话内保留，关闭后不保证恢复")
        static let currentSessionTitle = L10n.string("import.v0.current_session", default: "当前会话")
        static let importedListTitle = L10n.string("import.v0.imported_list_title", default: "待处理文件")
        static let modeTitle = L10n.string("import.v0.mode_title", default: "模式说明")
        static let modeDescription = L10n.string("import.v0.mode_description", default: "标准：核心身份信息优先。严格：额外显示更多可能身份线索。自定义：用户自行控制字段开关。")
        static let continueAdding = L10n.string("import.v0.continue_adding", default: "继续添加")
        static let title = L10n.string("import.title", default: "Import Page")
        static let description = L10n.string("import.description", default: "Choose local PDF or image files to load them into the current session.")
        static let actionTitle = L10n.string("import.card.title", default: "Import Files")
        static let localFirst = L10n.string("import.local_first", default: "Local-only session")
        static let noBackground = L10n.string("import.no_background", default: "Current-page OCR runs only when requested")
        static let chooseFiles = L10n.string("import.choose_files", default: "Choose Files")
        static let goToReview = L10n.string("import.go_to_review", default: "Go to Review / Edit")
        static let importedFilesTitle = L10n.string("import.card.session_seed_title", default: "Imported Files")
        static let importedFilesSessionSummary = L10n.string("import.summary.session_only", default: "Imported files remain in memory for the current session only.")
        static let emptyImportedFiles = L10n.string("import.summary.empty", default: "No files imported yet.")
        static let panelTitle = L10n.string("import.panel.title", default: "Import Files")
        static let panelMessage = L10n.string("import.panel.message", default: "Choose one or more PDF or image files to load into this session.")

        static func importedFilesSummary(fileCount: Int, pageCount: Int) -> String {
            L10n.formatted(
                "import.summary.counts",
                default: "%1$@ file(s) • %2$@ total page(s)",
                L10n.countText(fileCount),
                L10n.countText(pageCount)
            )
        }

        static func importErrorUnreadableFile(_ fileName: String) -> String {
            L10n.formatted("import.error.unreadable_file", default: "Could not import \"%@\".", fileName)
        }

        static func importErrorEmptyPDF(_ fileName: String) -> String {
            L10n.formatted("import.error.empty_pdf", default: "\"%@\" has no readable pages.", fileName)
        }
    }

    enum Review {
        static let documentContextTitle = L10n.string("review.v0.document_context", default: "文档 / 页面")
        static let originalPreviewLabel = L10n.string("review.v0.original_preview", default: "原件")
        static let maskedPreviewLabel = L10n.string("review.v0.masked_preview", default: "脱敏预览")
        static let zoomOut = L10n.string("review.v0.zoom_out", default: "缩小")
        static let zoomIn = L10n.string("review.v0.zoom_in", default: "放大")
        static let fitToWidthLabel = L10n.string("review.v0.fit_to_width", default: "适应宽度")
        static let fitToWindowLabel = L10n.string("review.v0.fit_to_window", default: "适应窗口")
        static let candidateReliable = L10n.string("review.v0.candidate_reliable", default: "可靠")
        static let candidateUncertain = L10n.string("review.v0.candidate_uncertain", default: "可能")
        static let candidateUnreadable = L10n.string("review.v0.candidate_unreadable", default: "读不出")
        static let candidateEmpty = L10n.string("review.v0.candidate_empty", default: "空字段")
        static let candidateMasked = L10n.string("review.v0.candidate_masked", default: "已脱敏")
        static let candidateIgnored = L10n.string("review.v0.candidate_ignored", default: "已忽略")
        static let candidatePending = L10n.string("review.v0.candidate_pending", default: "待处理")
        static let noVisibleCandidates = L10n.string("review.v0.no_visible_candidates", default: "本页未识别到敏感候选")
        static let reviewReminder = L10n.string("review.v0.review_reminder", default: "OCR 建议仅作参考，导出前必须人工复核。")
        static let filesTitle = L10n.string("review.sidebar.files_title", default: "Files")
        static let filesSubtitle = L10n.string("review.sidebar.files_subtitle", default: "Imported documents in the current session.")
        static let noImportedFiles = L10n.string("review.sidebar.no_files", default: "No files imported yet.")
        static let pagesTitle = L10n.string("review.sidebar.pages_title", default: "Pages")
        static let pagesSubtitle = L10n.string("review.sidebar.pages_subtitle", default: "Pages discovered from the selected file.")
        static let noPagesAvailable = L10n.string("review.sidebar.no_pages", default: "Select a file to view its pages.")
        static let canvasSectionTitle = L10n.string("review.canvas.title", default: "Canvas")
        static let canvasSubtitle = L10n.string("review.canvas.subtitle", default: "Actual preview is shown here. Drag to create, move, resize, and delete manual regions on the selected page.")
        static let canvasPreviewPlaceholder = L10n.string("review.canvas.preview_placeholder", default: "Select a file and page to preview.")
        static let noFileSelected = L10n.string("review.canvas.no_file", default: "No file selected")
        static let noPageSelected = L10n.string("review.canvas.no_page", default: "No page selected")
        static let inspectorTitle = L10n.string("review.inspector.title", default: "Inspector")
        static let inspectorSubtitle = L10n.string("review.inspector.subtitle", default: "Mask settings and current-session region counts for the selected file.")
        static let maskPreset = L10n.string("review.inspector.mask_preset", default: "Mask Preset")
        static let detectionTitle = L10n.string("review.inspector.detection_title", default: "Detection Status")
        static let detectionSubtitle = L10n.string("review.inspector.detection_subtitle", default: "Run local OCR suggestions for the selected page only.")
        static let detectCurrentPage = L10n.string("review.ocr.detect_current_page", default: "Detect Current Page")
        static let ocrDetectedItemsTitle = L10n.string("review.ocr.detected_items_title", default: "Detected Items")
        static let maskOCRCandidate = L10n.string("review.ocr.action.mask", default: "Mask")
        static let ignoreOCRCandidate = L10n.string("review.ocr.action.ignore", default: "Ignore")
        static let locateOCRCandidate = L10n.string("review.ocr.action.locate", default: "Locate")
        static let undoOCRCandidate = L10n.string("review.ocr.action.undo", default: "Undo")
        static let unmaskOCRCandidate = L10n.string("review.ocr.action.unmask", default: "Unmask")
        static let ocrCandidateStatusPending = L10n.string("review.ocr.status.pending", default: "Pending")
        static let ocrCandidateStatusMasked = L10n.string("review.ocr.status.masked", default: "Masked")
        static let ocrCandidateStatusIgnored = L10n.string("review.ocr.status.ignored", default: "Ignored")
        static let ocrNoCandidates = L10n.string("review.ocr.no_candidates", default: "No sensitive items detected")
        static let ocrNoExplicitValue = L10n.string("review.ocr.no_explicit_value", default: "No specific content recognized. Please check this fill-in area.")
        static let ocrStateIdle = L10n.string("review.ocr.state.idle", default: "Idle")
        static let ocrStateRunning = L10n.string("review.ocr.state.running", default: "Detecting current page...")
        static let ocrStateNeedsRerun = L10n.string("review.ocr.state.needs_rerun", default: "Detection settings changed. Rerun OCR for the current page.")
        static let ocrStateNoPage = L10n.string("review.ocr.state.no_page", default: "Select a file and page first.")
        static let ocrSuggestionHint = L10n.string("review.ocr.suggestion_hint", default: "OCR suggestions are normal editable boxes on the selected page.")
        static let manualEditHint = L10n.string("review.canvas.manual_edit_hint", default: "Drag on empty preview space to create a region. Delete removes the selected box.")
        static let maskedPreviewHint = L10n.string("review.canvas.masked_preview_hint", default: "Preview is view-only. Switch back to Edit to edit boxes.")
        static let deleteRegion = L10n.string("review.canvas.delete_region", default: "Delete Selected Box")
        static let previewMode = L10n.string("review.canvas.preview_mode", default: "Preview Mode")
        static let originalPreview = L10n.string("review.canvas.original_preview", default: "Edit")
        static let maskedPreview = L10n.string("review.canvas.masked_preview", default: "Preview")
        static let fitToWindow = L10n.string("review.canvas.zoom.fit_to_window", default: "Fit to Window")
        static let fitToWidth = L10n.string("review.canvas.zoom.fit_to_width", default: "Fit to Width")
        static let actualSize = L10n.string("review.canvas.zoom.actual_size", default: "Actual Size")
        static let customPresetFieldsTitle = L10n.string("review.inspector.custom_preset_fields", default: "Custom Fields")
        static let showOriginalPreview = L10n.string("review.command.show_original", default: "Show Edit")
        static let showMaskedPreview = L10n.string("review.command.show_masked", default: "Show Preview")
        static let undo = L10n.string("review.command.undo", default: "Undo")
        static let redo = L10n.string("review.command.redo", default: "Redo")
        static let previousPage = L10n.string("review.command.previous_page", default: "Previous Page")
        static let nextPage = L10n.string("review.command.next_page", default: "Next Page")
        static let commandMenuTitle = L10n.string("review.command.menu_title", default: "Review")

        static var previewUnavailable: String {
            L10n.string("review.canvas.preview_unavailable", default: "Preview unavailable for the selected content.")
        }

        static func previewLoadFailed(_ fileName: String) -> String {
            L10n.formatted("review.canvas.preview_load_failed", default: "Could not load a preview for \"%@\".", fileName)
        }

        static func previewMetadata(kind: String, pageNumber: Int, pageCount: Int) -> String {
            L10n.formatted(
                "review.canvas.preview_metadata",
                default: "%1$@ • Page %2$@ of %3$@",
                kind,
                L10n.countText(pageNumber),
                L10n.countText(pageCount)
            )
        }

        static func singlePageMetadata(pageSummary: String, status: String) -> String {
            L10n.formatted(
                "review.sidebar.single_page_metadata",
                default: "Single page • %1$@ • %2$@",
                pageSummary,
                status
            )
        }

        static func ocrStateSucceeded(_ count: Int) -> String {
            L10n.formatted("review.ocr.state.succeeded", default: "Detected %d candidate item(s) on this page.", count)
        }

        static func ocrStateFailed(_ reason: String) -> String {
            L10n.formatted("review.ocr.state.failed", default: "OCR failed: %@", reason)
        }

        static let ocrUnreadableContentValue = L10n.string("review.ocr.value.unreadable_content", default: "Text was not recognized reliably. Please review the masking area.")
        static let ocrEmptyFieldValue = L10n.string("review.ocr.value.empty_field", default: "No filled content detected.")

        static func ocrUncertainValue(_ value: String) -> String {
            L10n.formatted("review.ocr.value.uncertain", default: "Possible: %@. Please review.", value)
        }
    }

    enum OCRCategory {
        static let name = L10n.string("ocr.category.name", default: "Name")
        static let sex = L10n.string("ocr.category.sex", default: "Sex")
        static let age = L10n.string("ocr.category.age", default: "Age")
        static let address = L10n.string("ocr.category.address", default: "Address")
        static let phone = L10n.string("ocr.category.phone", default: "Phone")
        static let email = L10n.string("ocr.category.email", default: "Email")
        static let fax = L10n.string("ocr.category.fax", default: "Fax")
        static let chineseID = L10n.string("ocr.category.chinese_id", default: "Chinese ID")
        static let documentNumber = L10n.string("ocr.category.document_number", default: "Document Number")
        static let medicalNumber = L10n.string("ocr.category.medical_number", default: "Medical Number")
        static let hospital = L10n.string("ocr.category.hospital", default: "Hospital")
        static let department = L10n.string("ocr.category.department", default: "Department")
        static let doctor = L10n.string("ocr.category.doctor", default: "Doctor")
        static let staffSignature = L10n.string("ocr.category.staff_signature", default: "Staff / Signature")
        static let bedNumber = L10n.string("ocr.category.bed_number", default: "Bed Number")
        static let date = L10n.string("ocr.category.date", default: "Date")
        static let birthday = L10n.string("ocr.category.birthday", default: "Birthday")
        static let examDate = L10n.string("ocr.category.exam_date", default: "Exam Date")
        static let custom = L10n.string("ocr.category.custom", default: "Custom")
        static let unknown = L10n.string("ocr.category.unknown", default: "Unknown")
    }

    enum Export {
        static let successFilesTitle = L10n.string("export.v0.success_files_title", default: "成功文件")
        static let failedFilesTitle = L10n.string("export.v0.failed_files_title", default: "失败文件")
        static let exportedStatus = L10n.string("export.v0.exported_status", default: "已导出")
        static let noSuccessfulFiles = L10n.string("export.v0.no_success_files", default: "当前还没有成功导出的文件。")
        static let noFailedFiles = L10n.string("export.v0.no_failed_files", default: "当前没有失败文件。")
        static let processedFilesTitle = L10n.string("export.v0.processed_files_title", default: "已处理文件")
        static let continueNextBatch = L10n.string("export.v0.continue_next_batch", default: "继续处理下一批")
        static let currentRecognizedRegions = L10n.string("export.v0.current_recognized_regions", default: "区域数按当前已识别/已处理结果统计；若后台识别仍在运行，不代表全部页面最终总数。")
        static let title = L10n.string("export.title", default: "Export Summary")
        static let description = L10n.string("export.description", default: "Review the current session, export redacted copies to a local folder, and inspect any per-file failures.")
        static let preparedTitle = L10n.string("export.prepared_title", default: "Prepared Session")
        static let readyTitle = L10n.string("export.ready_title", default: "Ready To Export")
        static let readySubtitle = L10n.string("export.ready_subtitle", default: "Choose a destination folder to export redacted copies for the current session.")
        static let resultsTitle = L10n.string("export.results_title", default: "Last Export Result")
        static let resultsSubtitle = L10n.string("export.results_subtitle", default: "Latest export result for the current in-memory session.")
        static let failuresTitle = L10n.string("export.failures_title", default: "Failed Files")
        static let failuresSubtitle = L10n.string("export.failures_subtitle", default: "These files did not export successfully.")
        static let noResultsYet = L10n.string("export.no_results_yet", default: "No export has run in this session yet.")
        static let fixedPDFResolution = L10n.string("export.fixed_pdf_resolution", default: "PDF pages export as rasterized 200 DPI pages")
        static let localDestinationOnly = L10n.string("export.local_destination_only", default: "Choose a local folder destination with no persistence")
        static let originalUnchanged = L10n.string("export.original_unchanged", default: "Original files remain unchanged")
        static let exportButton = L10n.string("export.export_button", default: "Export Redacted Copy")
        static let openFolderButton = L10n.string("export.open_folder", default: "Open Output Folder")
        static let destinationPanelTitle = L10n.string("export.destination_panel.title", default: "Choose Export Folder")
        static let destinationPanelMessage = L10n.string("export.destination_panel.message", default: "Choose a folder for the current session's redacted copies.")
        static let destinationPanelPrompt = L10n.string("export.destination_panel.prompt", default: "Choose Folder")
        static let failureSourceUnavailable = L10n.string("export.failure.source_unavailable", default: "The source file is no longer available.")
        static let failureImageUnavailable = L10n.string("export.failure.image_unavailable", default: "The image source could not be loaded.")
        static let failureImageEncodingUnavailable = L10n.string("export.failure.image_encoding_unavailable", default: "The redacted image could not be encoded for export.")
        static let failurePDFUnavailable = L10n.string("export.failure.pdf_unavailable", default: "The PDF source could not be loaded.")
        static let failureWriteFailed = L10n.string("export.failure.write_failed", default: "The exported file could not be written to the destination folder.")
        static let failureDestinationNotDirectory = L10n.string("export.failure.destination_not_directory", default: "The selected destination is not a folder.")

        static func failurePDFPageUnavailable(_ pageNumber: Int) -> String {
            L10n.formatted(
                "export.failure.pdf_page_unavailable",
                default: "PDF page %@ could not be rasterized.",
                L10n.countText(pageNumber)
            )
        }

        static func destinationPath(_ path: String) -> String {
            L10n.formatted("export.destination_path", default: "Destination: %@", path)
        }

        static func successCount(_ count: Int) -> String {
            L10n.formatted("export.success_count", default: "Successful exports: %@", L10n.countText(count))
        }

        static func failureCount(_ count: Int) -> String {
            L10n.formatted("export.failure_count", default: "Failed exports: %@", L10n.countText(count))
        }
    }

    enum Services {
        static let fileImportGuidance = L10n.string("service.file_import.guidance", default: "Choose local PDF or image files. They remain in memory for this session only.")
        static let emptyCanvasTitle = L10n.string("service.pdf.canvas_title_empty", default: "Canvas")
        static let ocrSummary = L10n.string("service.ocr.summary", default: "Local Vision OCR is available for current-page suggestions.")
        static let barcodeSummary = L10n.string("service.barcode.summary", default: "Barcode and QR detection are not implemented in this V0.")
        static let ocrFailureSourceUnavailable = L10n.string("service.ocr.failure.source_unavailable", default: "The source file is no longer available.")

        static func canvasTitle(for pageTitle: String) -> String {
            L10n.formatted("service.pdf.canvas_title", default: "%@ Canvas", pageTitle)
        }

        static func maskPreviewSummary(presetTitle: String, regionCount: Int) -> String {
            L10n.formatted(
                "service.mask.preview_summary",
                default: "%1$@ will burn %2$@ into preview and exported copies.",
                presetTitle,
                L10n.Common.regionCount(regionCount)
            )
        }

        static func exportSummary(fileCount: Int, presetTitle: String) -> String {
            L10n.formatted(
                "service.export.summary",
                default: "Ready to export %1$@ with the %2$@ preset.",
                countText(fileCount),
                presetTitle
            )
        }

        static func ocrFailureImageUnavailable(_ fileName: String) -> String {
            L10n.formatted("service.ocr.failure.image_unavailable", default: "The image \"%@\" could not be prepared for OCR.", fileName)
        }

        static func ocrFailurePDFUnavailable(_ fileName: String) -> String {
            L10n.formatted("service.ocr.failure.pdf_unavailable", default: "The PDF \"%@\" could not be prepared for OCR.", fileName)
        }

        static func ocrFailurePDFPageUnavailable(_ pageNumber: Int) -> String {
            L10n.formatted("service.ocr.failure.pdf_page_unavailable", default: "PDF page %@ could not be prepared for OCR.", countText(pageNumber))
        }

        static func ocrFailureRecognitionFailed(_ reason: String) -> String {
            L10n.formatted("service.ocr.failure.recognition_failed", default: "Vision text recognition failed. %@", reason)
        }
    }
}
