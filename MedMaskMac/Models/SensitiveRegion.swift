import CoreGraphics
import Foundation

struct NormalizedRect: Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let zero = NormalizedRect(x: 0, y: 0, width: 0, height: 0)

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(rect: CGRect, in size: CGSize) {
        guard size.width > 0, size.height > 0 else {
            self = .zero
            return
        }

        let bounds = CGRect(origin: .zero, size: size)
        let clampedRect = rect.standardized.intersection(bounds)

        self.init(
            x: Double(clampedRect.minX / size.width),
            y: Double(clampedRect.minY / size.height),
            width: Double(clampedRect.width / size.width),
            height: Double(clampedRect.height / size.height)
        )

        self = self.clamped()
    }

    func rect(in size: CGSize) -> CGRect {
        CGRect(
            x: x * size.width,
            y: y * size.height,
            width: width * size.width,
            height: height * size.height
        )
    }

    func rectInCoreGraphicsSpace(in size: CGSize) -> CGRect {
        let topLeftRect = rect(in: size)

        return CGRect(
            x: topLeftRect.minX,
            y: size.height - topLeftRect.maxY,
            width: topLeftRect.width,
            height: topLeftRect.height
        )
    }

    func clamped() -> NormalizedRect {
        let clampedX = x.clamped(to: 0...1)
        let clampedY = y.clamped(to: 0...1)
        let clampedWidth = width.clamped(to: 0...(1 - clampedX))
        let clampedHeight = height.clamped(to: 0...(1 - clampedY))

        return NormalizedRect(
            x: clampedX,
            y: clampedY,
            width: clampedWidth,
            height: clampedHeight
        )
    }

    func padded(horizontal: Double, vertical: Double) -> NormalizedRect {
        NormalizedRect(
            x: x - horizontal,
            y: y - vertical,
            width: width + horizontal * 2,
            height: height + vertical * 2
        )
        .clamped()
    }

    func substantiallyOverlaps(_ other: NormalizedRect, threshold: Double = 0.55) -> Bool {
        let intersectionWidth = max(0, min(x + width, other.x + other.width) - max(x, other.x))
        let intersectionHeight = max(0, min(y + height, other.y + other.height) - max(y, other.y))
        let intersectionArea = intersectionWidth * intersectionHeight
        let smallerArea = min(width * height, other.width * other.height)

        guard smallerArea > 0 else {
            return false
        }

        return intersectionArea / smallerArea >= threshold
    }
}

enum SensitiveRegionKind: String, CaseIterable, Hashable {
    case name = "Name"
    case phoneNumber = "Phone Number"
    case chineseIDNumber = "Chinese ID Number"
    case medicalNumber = "Medical Number"
    case barcode = "Barcode / QR"
    case custom = "Custom"
}

enum SensitiveRegionSource: String, CaseIterable, Hashable {
    case manual = "Manual"
    case ocr = "OCR"
}

struct SensitiveRegion: Identifiable, Hashable {
    let id: UUID
    var kind: SensitiveRegionKind
    var source: SensitiveRegionSource
    var bounds: NormalizedRect
    var confidence: Double?
    var isMasked: Bool

    init(
        id: UUID = UUID(),
        kind: SensitiveRegionKind,
        source: SensitiveRegionSource = .manual,
        bounds: NormalizedRect,
        confidence: Double? = nil,
        isMasked: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.bounds = bounds
        self.confidence = confidence
        self.isMasked = isMasked
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
