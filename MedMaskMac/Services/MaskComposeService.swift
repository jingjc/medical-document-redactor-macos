import AppKit
import CoreGraphics
import Foundation

nonisolated protocol MaskComposeService {
    func previewSummary(for preset: MaskPreset, regionCount: Int) -> String
    func maskedPreview(
        from rasterContent: DocumentPreviewRasterContent,
        regions: [SensitiveRegion],
        preset: MaskPreset
    ) -> DocumentPreviewRasterContent
    func maskedCGImage(
        from sourceImage: CGImage,
        regions: [SensitiveRegion],
        preset: MaskPreset
    ) -> CGImage?
    func exportRegions(from page: PageItem, preset: MaskPreset) -> [SensitiveRegion]
}

nonisolated struct DefaultMaskComposeService: MaskComposeService {
    func previewSummary(for preset: MaskPreset, regionCount: Int) -> String {
        L10n.Services.maskPreviewSummary(presetTitle: preset.title, regionCount: regionCount)
    }

    func maskedPreview(
        from rasterContent: DocumentPreviewRasterContent,
        regions: [SensitiveRegion],
        preset: MaskPreset
    ) -> DocumentPreviewRasterContent {
        guard let sourceImage = rasterContent.image.cgImageValue,
              let maskedImage = maskedCGImage(
                  from: sourceImage,
                  regions: regions,
                  preset: preset
              ) else {
            return rasterContent
        }

        return DocumentPreviewRasterContent(
            image: NSImage(cgImage: maskedImage, size: rasterContent.image.size),
            canvasSize: rasterContent.canvasSize
        )
    }

    func maskedCGImage(
        from sourceImage: CGImage,
        regions: [SensitiveRegion],
        preset: MaskPreset
    ) -> CGImage? {
        let includedRegions = exportRegions(from: regions, preset: preset)
        guard !includedRegions.isEmpty else {
            return sourceImage
        }

        let canvasSize = CGSize(width: sourceImage.width, height: sourceImage.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        let imageRect = CGRect(origin: .zero, size: canvasSize)
        context.draw(sourceImage, in: imageRect)
        context.setFillColor(NSColor.black.cgColor)

        for region in includedRegions {
            context.fill(region.bounds.rectInCoreGraphicsSpace(in: canvasSize))
        }

        return context.makeImage()
    }

    func exportRegions(from page: PageItem, preset: MaskPreset) -> [SensitiveRegion] {
        exportRegions(from: page.sensitiveRegions, preset: preset)
    }

    private func exportRegions(from regions: [SensitiveRegion], preset: MaskPreset) -> [SensitiveRegion] {
        regions.filter(\.isMasked)
    }
}

extension NSImage {
    var cgImageValue: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
