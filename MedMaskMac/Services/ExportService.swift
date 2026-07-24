import AppKit
import Foundation
import PDFKit

@MainActor
protocol ExportService {
    func preparedSummary(for files: [FileItem], preset: MaskPreset) -> String
    func chooseDestination() -> URL?
    func exportSession(
        files: [FileItem],
        preset: MaskPreset,
        destinationURL: URL
    ) -> ExportResult
    func openFolder(at url: URL)
}

enum ExportError: LocalizedError {
    case sourceUnavailable
    case imageUnavailable
    case imageEncodingUnavailable
    case pdfUnavailable
    case pdfPageUnavailable(Int)
    case writeFailed(underlyingDescription: String?)

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            L10n.Export.failureSourceUnavailable
        case .imageUnavailable:
            L10n.Export.failureImageUnavailable
        case .imageEncodingUnavailable:
            L10n.Export.failureImageEncodingUnavailable
        case .pdfUnavailable:
            L10n.Export.failurePDFUnavailable
        case let .pdfPageUnavailable(pageNumber):
            L10n.Export.failurePDFPageUnavailable(pageNumber)
        case let .writeFailed(underlyingDescription):
            if let underlyingDescription, !underlyingDescription.isEmpty {
                "\(L10n.Export.failureWriteFailed) \(underlyingDescription)"
            } else {
                L10n.Export.failureWriteFailed
            }
        }
    }
}

@MainActor
struct DefaultExportService: ExportService {
    private let maskComposeService: any MaskComposeService

    init(maskComposeService: any MaskComposeService) {
        self.maskComposeService = maskComposeService
    }

    func preparedSummary(for files: [FileItem], preset: MaskPreset) -> String {
        L10n.Services.exportSummary(fileCount: files.count, presetTitle: preset.title)
    }

    func chooseDestination() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = true
        panel.title = L10n.Export.destinationPanelTitle
        panel.message = L10n.Export.destinationPanelMessage
        panel.prompt = L10n.Export.destinationPanelPrompt

        guard panel.runModal() == .OK else {
            return nil
        }

        return panel.urls.first
    }

    func exportSession(
        files: [FileItem],
        preset: MaskPreset,
        destinationURL: URL
    ) -> ExportResult {
        let accessedDestination = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if accessedDestination {
                destinationURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try validateDestinationDirectory(destinationURL)
        } catch {
            return ExportResult(
                destinationURL: destinationURL,
                successCount: 0,
                failures: files.map { file in
                    ExportFailure(
                        fileName: file.displayName,
                        reason: error.localizedDescription
                    )
                }
            )
        }

        var successCount = 0
        var failures: [ExportFailure] = []

        for file in files {
            do {
                try exportFile(file, preset: preset, destinationURL: destinationURL)
                successCount += 1
            } catch {
                failures.append(
                    ExportFailure(
                        fileName: file.displayName,
                        reason: error.localizedDescription
                    )
                )
            }
        }

        return ExportResult(
            destinationURL: destinationURL,
            successCount: successCount,
            failures: failures
        )
    }

    func openFolder(at url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func exportFile(
        _ file: FileItem,
        preset: MaskPreset,
        destinationURL: URL
    ) throws {
        guard let sourceURL = file.sourceURL else {
            throw ExportError.sourceUnavailable
        }

        switch file.kind {
        case .image:
            try exportImageFile(
                file,
                preset: preset,
                sourceURL: sourceURL,
                destinationURL: destinationURL
            )
        case .pdf:
            try exportPDFFile(
                file,
                preset: preset,
                sourceURL: sourceURL,
                destinationURL: destinationURL
            )
        }
    }

    private func exportImageFile(
        _ file: FileItem,
        preset: MaskPreset,
        sourceURL: URL,
        destinationURL: URL
    ) throws {
        try withSecurityScopedAccess(to: sourceURL) {
            guard let image = NSImage(contentsOf: sourceURL),
                  let sourceImage = image.cgImageValue else {
                throw ExportError.imageUnavailable
            }

            let page = file.pages.first ?? PageItem(pageNumber: 1, sourcePageIndex: 0, status: .readyForReview)
            guard let maskedImage = maskComposeService.maskedCGImage(
                from: sourceImage,
                regions: page.sensitiveRegions,
                preset: preset
            ) else {
                throw ExportError.imageUnavailable
            }

            let outputFormat = resolvedImageFormat(for: sourceURL)
            let bitmapRep = NSBitmapImageRep(cgImage: maskedImage)
            let properties = outputFormat.properties

            guard let data = bitmapRep.representation(using: outputFormat.fileType, properties: properties) else {
                throw ExportError.imageEncodingUnavailable
            }

            let outputURL = uniqueOutputURL(
                for: sourceURL.deletingPathExtension().lastPathComponent,
                fileExtension: outputFormat.fileExtension,
                in: destinationURL
            )

            do {
                try data.write(to: outputURL, options: .atomic)
            } catch {
                throw ExportError.writeFailed(underlyingDescription: error.localizedDescription)
            }
        }
    }

    private func exportPDFFile(
        _ file: FileItem,
        preset: MaskPreset,
        sourceURL: URL,
        destinationURL: URL
    ) throws {
        try withSecurityScopedAccess(to: sourceURL) {
            guard let document = PDFDocument(url: sourceURL) else {
                throw ExportError.pdfUnavailable
            }

            let exportedDocument = PDFDocument()

            for (pageOffset, pageItem) in file.pages.enumerated() {
                let sourcePageIndex = pageItem.sourcePageIndex ?? pageOffset
                guard let sourcePage = document.page(at: sourcePageIndex) else {
                    throw ExportError.pdfPageUnavailable(pageItem.pageNumber)
                }

                let pageBounds = sourcePage.bounds(for: .mediaBox).standardized
                let rasterSize = rasterSize(for: pageBounds.size)
                let thumbnail = sourcePage.thumbnail(of: rasterSize, for: .mediaBox)

                guard let thumbnailImage = thumbnail.cgImageValue,
                      let maskedImage = maskComposeService.maskedCGImage(
                          from: thumbnailImage,
                          regions: pageItem.sensitiveRegions,
                          preset: preset
                      ) else {
                    throw ExportError.pdfPageUnavailable(pageItem.pageNumber)
                }

                let pageImage = NSImage(cgImage: maskedImage, size: pageBounds.size)
                guard let exportedPage = PDFPage(image: pageImage) else {
                    throw ExportError.pdfPageUnavailable(pageItem.pageNumber)
                }

                exportedDocument.insert(exportedPage, at: exportedDocument.pageCount)
            }

            let outputURL = uniqueOutputURL(
                for: sourceURL.deletingPathExtension().lastPathComponent,
                fileExtension: "pdf",
                in: destinationURL
            )

            guard exportedDocument.write(to: outputURL) else {
                throw ExportError.writeFailed(underlyingDescription: nil)
            }
        }
    }

    private func resolvedImageFormat(for sourceURL: URL) -> ExportImageFormat {
        switch sourceURL.pathExtension.lowercased() {
        case "jpg", "jpeg":
            ExportImageFormat(
                fileType: .jpeg,
                fileExtension: "jpg",
                properties: [.compressionFactor: 1.0]
            )
        case "tif", "tiff":
            ExportImageFormat(fileType: .tiff, fileExtension: "tiff")
        case "gif":
            ExportImageFormat(fileType: .gif, fileExtension: "gif")
        case "bmp":
            ExportImageFormat(fileType: .bmp, fileExtension: "bmp")
        default:
            ExportImageFormat(fileType: .png, fileExtension: "png")
        }
    }

    private func uniqueOutputURL(
        for baseName: String,
        fileExtension: String,
        in destinationURL: URL
    ) -> URL {
        let sanitizedBaseName = safeFileBaseName(from: baseName)
        let redactedBaseName = sanitizedBaseName + "_redacted"
        var candidateURL = destinationURL
            .appendingPathComponent(redactedBaseName, isDirectory: false)
            .appendingPathExtension(fileExtension)
        var collisionIndex = 2

        while (try? candidateURL.checkResourceIsReachable()) == true {
            candidateURL = destinationURL
                .appendingPathComponent("\(redactedBaseName)_\(collisionIndex)", isDirectory: false)
                .appendingPathExtension(fileExtension)
            collisionIndex += 1
        }

        return candidateURL
    }

    private func validateDestinationDirectory(_ destinationURL: URL) throws {
        do {
            let resourceValues = try destinationURL.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues.isDirectory == true else {
                throw ExportError.writeFailed(underlyingDescription: L10n.Export.failureDestinationNotDirectory)
            }
        } catch let exportError as ExportError {
            throw exportError
        } catch {
            throw ExportError.writeFailed(underlyingDescription: error.localizedDescription)
        }
    }

    private func safeFileBaseName(from baseName: String) -> String {
        let invalidScalars = CharacterSet(charactersIn: "/:\\")
            .union(.controlCharacters)
        let cleanedScalars = baseName.unicodeScalars.map { scalar in
            invalidScalars.contains(scalar) ? "_" : String(scalar)
        }
        let cleanedName = cleanedScalars
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        return cleanedName.isEmpty ? "export" : cleanedName
    }

    private func rasterSize(for pageSize: CGSize) -> CGSize {
        let scale = 200.0 / 72.0

        return CGSize(
            width: max(pageSize.width * scale, 1),
            height: max(pageSize.height * scale, 1)
        )
    }

    private func withSecurityScopedAccess<T>(
        to url: URL,
        operation: () throws -> T
    ) throws -> T {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return try operation()
    }
}

private struct ExportImageFormat {
    let fileType: NSBitmapImageRep.FileType
    let fileExtension: String
    let properties: [NSBitmapImageRep.PropertyKey: Any]

    init(
        fileType: NSBitmapImageRep.FileType,
        fileExtension: String,
        properties: [NSBitmapImageRep.PropertyKey: Any] = [:]
    ) {
        self.fileType = fileType
        self.fileExtension = fileExtension
        self.properties = properties
    }
}
