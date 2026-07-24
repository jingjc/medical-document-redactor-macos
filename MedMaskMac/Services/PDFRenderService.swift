import AppKit
import Foundation
import PDFKit

nonisolated struct DocumentPreviewRasterContent {
    let image: NSImage
    let canvasSize: CGSize
}

nonisolated enum DocumentPreviewContent {
    case empty
    case raster(DocumentPreviewRasterContent)
    case failure(message: String)
}

nonisolated protocol PDFRenderService {
    func canvasTitle(for page: PageItem?) -> String
    func previewContent(for file: FileItem?, page: PageItem?) -> DocumentPreviewContent
}

nonisolated final class DefaultPDFRenderService: PDFRenderService {
    private var imageCache: [URL: NSImage] = [:]
    private var pdfCache: [URL: PDFDocument] = [:]
    private var pdfPageCache: [PDFPageCacheKey: DocumentPreviewRasterContent] = [:]

    func canvasTitle(for page: PageItem?) -> String {
        if let page {
            return L10n.Services.canvasTitle(for: page.title)
        }

        return L10n.Services.emptyCanvasTitle
    }

    func previewContent(for file: FileItem?, page: PageItem?) -> DocumentPreviewContent {
        guard let file else {
            return .empty
        }

        guard let sourceURL = file.sourceURL else {
            return .failure(message: L10n.Review.previewUnavailable)
        }

        switch file.kind {
        case .image:
            return loadImagePreview(fileName: file.displayName, sourceURL: sourceURL)
        case .pdf:
            return loadPDFPreview(
                fileName: file.displayName,
                sourceURL: sourceURL,
                preferredPageIndex: page?.sourcePageIndex ?? 0
            )
        }
    }

    private func loadImagePreview(fileName: String, sourceURL: URL) -> DocumentPreviewContent {
        if let cachedImage = imageCache[sourceURL] {
            return .raster(
                DocumentPreviewRasterContent(
                    image: cachedImage,
                    canvasSize: resolvedCanvasSize(for: cachedImage.size)
                )
            )
        }

        return withSecurityScopedAccess(to: sourceURL) {
            guard let image = NSImage(contentsOf: sourceURL) else {
                return .failure(message: L10n.Review.previewLoadFailed(fileName))
            }

            imageCache[sourceURL] = image
            return .raster(
                DocumentPreviewRasterContent(
                    image: image,
                    canvasSize: resolvedCanvasSize(for: image.size)
                )
            )
        }
    }

    private func loadPDFPreview(
        fileName: String,
        sourceURL: URL,
        preferredPageIndex: Int
    ) -> DocumentPreviewContent {
        let document: PDFDocument?

        if let cachedDocument = pdfCache[sourceURL] {
            document = cachedDocument
        } else {
            document = withSecurityScopedAccess(to: sourceURL) {
                PDFDocument(url: sourceURL)
            }

            if let document {
                pdfCache[sourceURL] = document
            }
        }

        guard let document else {
            return .failure(message: L10n.Review.previewLoadFailed(fileName))
        }

        guard document.pageCount > 0 else {
            return .failure(message: L10n.Review.previewUnavailable)
        }

        let resolvedPageIndex = max(0, min(preferredPageIndex, document.pageCount - 1))
        let cacheKey = PDFPageCacheKey(sourceURL: sourceURL, pageIndex: resolvedPageIndex)
        if let cachedPagePreview = pdfPageCache[cacheKey] {
            return .raster(cachedPagePreview)
        }

        guard let page = document.page(at: resolvedPageIndex) else {
            return .failure(message: L10n.Review.previewUnavailable)
        }

        let pageBounds = page.bounds(for: .mediaBox).standardized
        let canvasSize = resolvedCanvasSize(for: pageBounds.size)
        let thumbnailSize = resolvedThumbnailSize(for: canvasSize)
        let image = page.thumbnail(of: thumbnailSize, for: .mediaBox)
        let rasterContent = DocumentPreviewRasterContent(image: image, canvasSize: canvasSize)
        pdfPageCache[cacheKey] = rasterContent
        return .raster(rasterContent)
    }

    private func withSecurityScopedAccess<T>(to url: URL, operation: () -> T) -> T {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return operation()
    }

    private func resolvedCanvasSize(for size: CGSize) -> CGSize {
        CGSize(width: max(size.width, 1), height: max(size.height, 1))
    }

    private func resolvedThumbnailSize(for canvasSize: CGSize) -> CGSize {
        let maxDimension: CGFloat = 1800
        let baseScale: CGFloat = 2.0
        let currentMaxDimension = max(canvasSize.width, canvasSize.height)
        let cappedScale = min(baseScale, maxDimension / max(currentMaxDimension, 1))
        let resolvedScale = max(cappedScale, 1.0)

        return CGSize(
            width: max(canvasSize.width * resolvedScale, 1),
            height: max(canvasSize.height * resolvedScale, 1)
        )
    }
}

nonisolated private struct PDFPageCacheKey: Hashable {
    let sourceURL: URL
    let pageIndex: Int
}
