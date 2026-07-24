import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

@MainActor
protocol FileImportService {
    func supportedFileTypes() -> [String]
    func importGuidanceMessage() -> String
    func importFiles() throws -> [FileItem]
}

enum FileImportError: LocalizedError {
    case unreadableFile(String)
    case emptyPDF(String)

    var errorDescription: String? {
        switch self {
        case let .unreadableFile(fileName):
            L10n.Import.importErrorUnreadableFile(fileName)
        case let .emptyPDF(fileName):
            L10n.Import.importErrorEmptyPDF(fileName)
        }
    }
}

struct DefaultFileImportService: FileImportService {
    private let allowedContentTypes: [UTType] = [.pdf, .image]

    func supportedFileTypes() -> [String] {
        ["PDF", "PNG", "JPEG", "TIFF", "HEIC", "GIF", "BMP"]
    }

    func importGuidanceMessage() -> String {
        L10n.Services.fileImportGuidance
    }

    func importFiles() throws -> [FileItem] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = allowedContentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.resolvesAliases = true
        panel.title = L10n.Import.panelTitle
        panel.message = L10n.Import.panelMessage
        panel.prompt = L10n.Import.chooseFiles

        guard panel.runModal() == .OK else {
            return []
        }

        return try panel.urls.map(makeFileItem(from:))
    }

    private func makeFileItem(from url: URL) throws -> FileItem {
        try withSecurityScopedAccess(to: url) {
            let contentType = resolvedContentType(for: url)

            if contentType.conforms(to: .pdf) {
                return try makePDFItem(from: url)
            }

            if contentType.conforms(to: .image) {
                return makeImageItem(from: url)
            }

            throw FileImportError.unreadableFile(url.lastPathComponent)
        }
    }

    private func makeImageItem(from url: URL) -> FileItem {
        FileItem(
            displayName: url.lastPathComponent,
            sourceURL: url,
            kind: .image,
            status: .readyForReview,
            pages: [
                PageItem(
                    pageNumber: 1,
                    sourcePageIndex: 0,
                    status: .readyForReview
                )
            ]
        )
    }

    private func makePDFItem(from url: URL) throws -> FileItem {
        guard let document = PDFDocument(url: url) else {
            throw FileImportError.unreadableFile(url.lastPathComponent)
        }

        guard document.pageCount > 0 else {
            throw FileImportError.emptyPDF(url.lastPathComponent)
        }

        let pages = (0 ..< document.pageCount).map { index in
            PageItem(
                pageNumber: index + 1,
                sourcePageIndex: index,
                status: .readyForReview
            )
        }

        return FileItem(
            displayName: url.lastPathComponent,
            sourceURL: url,
            kind: .pdf,
            status: .readyForReview,
            pages: pages
        )
    }

    private func resolvedContentType(for url: URL) -> UTType {
        if let resourceType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return resourceType
        }

        if let typeFromExtension = UTType(filenameExtension: url.pathExtension) {
            return typeFromExtension
        }

        return .data
    }

    private func withSecurityScopedAccess<T>(to url: URL, operation: () throws -> T) rethrows -> T {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return try operation()
    }
}
