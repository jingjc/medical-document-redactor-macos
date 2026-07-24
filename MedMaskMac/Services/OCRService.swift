import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

nonisolated protocol OCRService {
    var availabilitySummary: String { get }

    func candidates(
        for file: FileItem,
        page: PageItem,
        options: OCRDetectionOptions
    ) async throws -> [OCRSensitiveCandidate]
}

enum OCRServiceError: LocalizedError {
    case sourceUnavailable
    case imageUnavailable(String)
    case pdfUnavailable(String)
    case pdfPageUnavailable(Int)
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            L10n.Services.ocrFailureSourceUnavailable
        case let .imageUnavailable(fileName):
            L10n.Services.ocrFailureImageUnavailable(fileName)
        case let .pdfUnavailable(fileName):
            L10n.Services.ocrFailurePDFUnavailable(fileName)
        case let .pdfPageUnavailable(pageNumber):
            L10n.Services.ocrFailurePDFPageUnavailable(pageNumber)
        case let .recognitionFailed(reason):
            L10n.Services.ocrFailureRecognitionFailed(reason)
        }
    }
}


nonisolated struct DefaultOCRService: OCRService {
    let availabilitySummary = L10n.Services.ocrSummary

    func candidates(
        for file: FileItem,
        page: PageItem,
        options: OCRDetectionOptions
    ) async throws -> [OCRSensitiveCandidate] {
        let input = try makeRecognitionInput(for: file, page: page)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[OCRSensitiveCandidate], Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try Self.recognizeSensitiveText(
                        in: input.cgImage,
                        pageID: page.id,
                        options: options
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func makeRecognitionInput(
        for file: FileItem,
        page: PageItem
    ) throws -> OCRRecognitionInput {
        guard let sourceURL = file.sourceURL else {
            throw OCRServiceError.sourceUnavailable
        }

        switch file.kind {
        case .image:
            return try makeImageRecognitionInput(fileName: file.displayName, sourceURL: sourceURL)
        case .pdf:
            return try makePDFRecognitionInput(
                fileName: file.displayName,
                sourceURL: sourceURL,
                page: page
            )
        }
    }

    private func makeImageRecognitionInput(
        fileName: String,
        sourceURL: URL
    ) throws -> OCRRecognitionInput {
        try withSecurityScopedAccess(to: sourceURL) {
            guard let cgImage = Self.makeOCRImageCGImage(from: sourceURL)
                ?? NSImage(contentsOf: sourceURL)?.cgImageValue else {
                throw OCRServiceError.imageUnavailable(fileName)
            }

            return OCRRecognitionInput(cgImage: cgImage)
        }
    }

    private func makePDFRecognitionInput(
        fileName: String,
        sourceURL: URL,
        page: PageItem
    ) throws -> OCRRecognitionInput {
        try withSecurityScopedAccess(to: sourceURL) {
            guard let document = PDFDocument(url: sourceURL) else {
                throw OCRServiceError.pdfUnavailable(fileName)
            }

            let pageIndex = page.sourcePageIndex ?? max(0, page.pageNumber - 1)
            guard let pdfPage = document.page(at: pageIndex) else {
                throw OCRServiceError.pdfPageUnavailable(page.pageNumber)
            }

            let pageBounds = pdfPage.bounds(for: .mediaBox).standardized
            let image = pdfPage.thumbnail(of: rasterSize(for: pageBounds.size), for: .mediaBox)

            guard let cgImage = image.cgImageValue else {
                throw OCRServiceError.pdfPageUnavailable(page.pageNumber)
            }

            return OCRRecognitionInput(cgImage: cgImage)
        }
    }

    private static func recognizeSensitiveText(
        in cgImage: CGImage,
        pageID: PageItem.ID,
        options: OCRDetectionOptions
    ) throws -> [OCRSensitiveCandidate] {
        let observations: [VNRecognizedTextObservation]
        do {
            observations = try recognizedTextObservations(in: cgImage)
        } catch {
            throw OCRServiceError.recognitionFailed(error.localizedDescription)
        }

        return buildCandidates(
            from: observations,
            pageID: pageID,
            options: options,
            context: OCRProcessingContext(sourceImage: cgImage)
        )
    }

    private static func buildCandidates(
        from observations: [VNRecognizedTextObservation],
        pageID: PageItem.ID,
        options: OCRDetectionOptions,
        context: OCRProcessingContext = .empty
    ) -> [OCRSensitiveCandidate] {
        let textItems = recognizedTextItems(from: observations)

        return buildCandidates(from: textItems, pageID: pageID, options: options, context: context)
    }

    private static func buildCandidates(
        from textItems: [OCRTextItem],
        pageID: PageItem.ID,
        options: OCRDetectionOptions,
        context: OCRProcessingContext = .empty
    ) -> [OCRSensitiveCandidate] {
        let includedCategories = options.includedCategories
        var candidates: [OCRSensitiveCandidate] = []

        for item in textItems {
            for rule in targetRules where includedCategories.contains(rule.category) {
                for match in rule.matches(in: item.text) {
                    guard !isForbiddenPatientNameTargetMatch(
                        rule: rule,
                        match: match,
                        in: item.text,
                        options: options
                    ) else {
                        continue
                    }

                    let targetRange = match.targetRange
                    guard let bounds = appNormalizedRect(
                        for: targetRange,
                        in: item.recognizedText,
                        text: item.text,
                        fallbackBounds: item.boundingBox
                    ) else {
                        continue
                    }

                    let dateBinding = rule.category == .date
                        ? bindingForDateValue(
                            match: match,
                            valueBox: bounds,
                            valueItem: item,
                            textItems: textItems,
                            includedCategories: includedCategories
                        )
                        : nil
                    let category = dateBinding?.category ?? rule.category
                    guard includedCategories.contains(category) else {
                        continue
                    }
                    let sourceLabel = dateBinding == nil
                        ? sourceLabelObservation(
                            for: category,
                            in: item,
                            before: targetRange
                        )
                        : nil

                    appendCandidate(
                        OCRSensitiveCandidate(
                            pageID: pageID,
                            text: displayText(match.text, for: category),
                            category: category,
                            sourceLabelText: sourceLabel?.title,
                            confidence: item.confidence,
                            boundingBox: bounds.padded(horizontal: 0.003, vertical: 0.004),
                            labelBoundingBox: dateBinding?.labelBoundingBox ?? sourceLabel?.boundingBox,
                            detectionKind: dateBinding == nil ? .directValue : .labelValue
                        ),
                        to: &candidates
                    )
                }
            }
        }

        appendLabelBasedCandidates(
            from: textItems,
            pageID: pageID,
            options: options,
            context: context,
            to: &candidates
        )

        return finalizedCandidates(candidates, options: options)
    }

    private static func recognizedTextObservations(in cgImage: CGImage) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        return request.results ?? []
    }

    private static func makeOCRImageCGImage(from sourceURL: URL) -> CGImage? {
        guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            return nil
        }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 2400
        ] as CFDictionary

        let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options)
            ?? CGImageSourceCreateImageAtIndex(imageSource, 0, nil)

        guard let image else {
            return nil
        }

        return normalizedRGBImage(image)
    }

    private static func normalizedRGBImage(_ image: CGImage) -> CGImage? {
        guard image.width > 0, image.height > 0 else {
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    private static func recognizedTextItems(
        from observations: [VNRecognizedTextObservation],
        minimumConfidence: Float = 0.30
    ) -> [OCRTextItem] {
        observations.compactMap { observation in
            guard let recognizedText = observation.topCandidates(1).first,
                  recognizedText.confidence >= minimumConfidence else {
                return nil
            }

            let text = recognizedText.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return nil
            }

            return OCRTextItem(
                text: text,
                recognizedText: recognizedText,
                boundingBox: appNormalizedRect(fromVisionBounds: observation.boundingBox),
                confidence: Double(recognizedText.confidence)
            )
        }
    }

    private static func appendLabelBasedCandidates(
        from textItems: [OCRTextItem],
        pageID: PageItem.ID,
        options: OCRDetectionOptions,
        context: OCRProcessingContext,
        to candidates: inout [OCRSensitiveCandidate]
    ) {
        let includedCategories = options.includedCategories
        let consumedHeaderIndexes = appendStrictMedicalHeaderCandidates(
            from: textItems,
            pageID: pageID,
            options: options,
            context: context,
            to: &candidates
        )
        let consumedSplitNameLabelIndexes = appendPatientSplitNameLabelCandidates(
            from: textItems,
            pageID: pageID,
            options: options,
            context: context,
            to: &candidates
        )

        for (labelIndex, labelItem) in textItems.enumerated() {
            let wasConsumed = consumedHeaderIndexes.contains(labelIndex)
                || consumedSplitNameLabelIndexes.contains(labelIndex)

            guard !wasConsumed else {
                continue
            }

            for labelRule in labelRules where includedCategories.contains(labelRule.category) && labelRule.matches(labelItem.text) {
                guard !isForbiddenPatientNameLabelMatch(
                    labelRule: labelRule,
                    labelText: labelItem.text,
                    options: options
                ) else {
                    continue
                }

                guard !containsDirectValue(
                    for: labelRule.category,
                    in: labelItem.text,
                    includedCategories: includedCategories
                ) else {
                    continue
                }

                let candidate = candidateNearLabel(
                    labelRule: labelRule,
                    labelItem: labelItem,
                    labelIndex: labelIndex,
                    textItems: textItems,
                    pageID: pageID,
                    options: options,
                    context: context
                )
                guard let candidate else {
                    continue
                }

                appendCandidate(candidate, to: &candidates)
            }
        }
    }

    private static func appendStrictMedicalHeaderCandidates(
        from textItems: [OCRTextItem],
        pageID: PageItem.ID,
        options: OCRDetectionOptions,
        context: OCRProcessingContext,
        to candidates: inout [OCRSensitiveCandidate]
    ) -> Set<Int> {
        guard options.preset == .strict else {
            return []
        }

        let includedCategories = options.includedCategories
        var consumedIndexes = Set<Int>()
        let headerLines = reconstructedMedicalHeaderLines(from: textItems)
            + strictHeaderROILines(from: textItems, context: context)

        for line in headerLines {
            guard let fields = medicalReportHeaderFields(in: line.text) else {
                continue
            }

            var appendedField = false
            for field in fields where includedCategories.contains(field.category) {
                guard let bounds = headerFieldBoundingBox(for: field, in: line) else {
                    continue
                }

                appendCandidate(
                    OCRSensitiveCandidate(
                        pageID: pageID,
                        text: field.text,
                        category: field.category,
                        confidence: headerFieldConfidence(for: field, in: line),
                        boundingBox: bounds.padded(horizontal: 0.003, vertical: 0.004),
                        detectionKind: .directValue
                    ),
                    to: &candidates
                )
                appendedField = true
            }

            if appendedField {
                consumedIndexes.formUnion(line.segments.map(\.itemIndex).filter { $0 >= 0 })
            }
        }

        return consumedIndexes
    }

    private static func appendPatientSplitNameLabelCandidates(
        from textItems: [OCRTextItem],
        pageID: PageItem.ID,
        options: OCRDetectionOptions,
        context: OCRProcessingContext,
        to candidates: inout [OCRSensitiveCandidate]
    ) -> Set<Int> {
        guard options.preset == .standard || options.preset == .strict,
              options.includedCategories.contains(.name) else {
            return []
        }

        let groups = splitNameLabelGroups(in: textItems)
        var consumedIndexes = Set<Int>()

        for group in groups {
            if let candidate = candidateNearSplitNameLabel(
                group,
                textItems: textItems,
                pageID: pageID,
                options: options,
                context: context
            ) {
                appendCandidate(candidate, to: &candidates)
            }

            consumedIndexes.formUnion(group.itemIndexes)
        }

        return consumedIndexes
    }

    private static func splitNameLabelGroups(in textItems: [OCRTextItem]) -> [OCRSplitNameLabelGroup] {
        let splitItems = textItems.enumerated().compactMap { index, item -> OCRSplitNameLabelItem? in
            guard let match = splitNameLabelMatch(for: item) else {
                return nil
            }

            return OCRSplitNameLabelItem(
                index: index,
                part: match.part,
                boundingBox: item.boundingBox,
                confidence: item.confidence,
                inlineValue: match.inlineValue
            )
        }

        return splitNameLabelGroups(from: splitItems)
    }

    private static func reconstructedMedicalHeaderLines(
        from textItems: [OCRTextItem],
        itemIndexOffset: Int = 0
    ) -> [OCRHeaderLine] {
        let indexedItems = textItems
            .enumerated()
            .filter { !$0.element.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { left, right in
                if abs(left.element.boundingBox.centerY - right.element.boundingBox.centerY) > 0.006 {
                    return left.element.boundingBox.centerY < right.element.boundingBox.centerY
                }

                return left.element.boundingBox.x < right.element.boundingBox.x
            }

        var rows: [[(index: Int, item: OCRTextItem)]] = []
        for indexedItem in indexedItems {
            if let rowIndex = rows.firstIndex(where: { row in
                row.contains { headerTextItemsAreOnSameRow($0.item, indexedItem.element) }
            }) {
                rows[rowIndex].append((index: indexedItem.offset, item: indexedItem.element))
            } else {
                rows.append([(index: indexedItem.offset, item: indexedItem.element)])
            }
        }

        return rows.compactMap { row in
            let sortedRow = row.sorted {
                if abs($0.item.boundingBox.x - $1.item.boundingBox.x) > 0.004 {
                    return $0.item.boundingBox.x < $1.item.boundingBox.x
                }

                return $0.item.boundingBox.centerY < $1.item.boundingBox.centerY
            }

            var lineText = ""
            var segments: [OCRHeaderLineSegment] = []
            var previousItem: OCRTextItem?
            for rowItem in sortedRow {
                let itemText = rowItem.item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !itemText.isEmpty else {
                    continue
                }

                if let previousItem {
                    lineText += headerJoinSeparator(left: previousItem, right: rowItem.item)
                }

                let range = NSRange(
                    location: (lineText as NSString).length,
                    length: (itemText as NSString).length
                )
                lineText += itemText
                segments.append(
                    OCRHeaderLineSegment(
                        itemIndex: rowItem.index + itemIndexOffset,
                        item: rowItem.item,
                        textRange: range
                    )
                )
                previousItem = rowItem.item
            }

            guard !lineText.isEmpty, !segments.isEmpty else {
                return nil
            }

            return OCRHeaderLine(text: lineText, segments: segments)
        }
    }

    private static func strictHeaderROILines(
        from textItems: [OCRTextItem],
        context: OCRProcessingContext
    ) -> [OCRHeaderLine] {
        guard let sourceImage = context.sourceImage else {
            return []
        }

        let rowBoxes = strictHeaderROIRowBoxes(from: textItems)
        guard !rowBoxes.isEmpty else {
            return []
        }

        var lines: [OCRHeaderLine] = []
        for (rowIndex, rowBox) in rowBoxes.enumerated() {
            for scale in [1, 3, 5] {
                guard let croppedImage = croppedImage(sourceImage, to: rowBox),
                      let ocrImage = scaledImage(croppedImage, scale: scale),
                      let observations = try? recognizedTextObservations(in: ocrImage) else {
                    continue
                }

                let roiItems = recognizedTextItems(from: observations, minimumConfidence: 0.05)
                    .map { item in
                        OCRTextItem(
                            text: item.text,
                            recognizedText: nil,
                            boundingBox: pageRect(from: item.boundingBox, in: rowBox),
                            confidence: item.confidence
                        )
                    }

                lines.append(
                    contentsOf: reconstructedMedicalHeaderLines(
                        from: roiItems,
                        itemIndexOffset: -100_000 - rowIndex * 1_000
                    )
                )
            }
        }

        return lines
    }

    private static func strictHeaderROIRowBoxes(from textItems: [OCRTextItem]) -> [NormalizedRect] {
        let anchorItems = textItems
            .filter { item in
                item.boundingBox.y <= 0.20 && strictHeaderAnchorText(item.text)
            }
            .sorted { left, right in
                if abs(left.boundingBox.centerY - right.boundingBox.centerY) > 0.006 {
                    return left.boundingBox.centerY < right.boundingBox.centerY
                }

                return left.boundingBox.x < right.boundingBox.x
            }

        var rowBoxes: [NormalizedRect] = []
        for item in anchorItems {
            let rowHeight = min(max(item.boundingBox.height * 5.5, 0.075), 0.13)
            let y = max(item.boundingBox.centerY - rowHeight / 2, 0)
            let rowBox = NormalizedRect(
                x: 0.02,
                y: y,
                width: 0.96,
                height: min(rowHeight, 1 - y)
            )
            .clamped()

            guard !rowBoxes.contains(where: { candidateBoxCentersAreClose($0, rowBox) }) else {
                continue
            }

            rowBoxes.append(rowBox)
        }

        return rowBoxes
    }

    private static func strictHeaderAnchorText(_ text: String) -> Bool {
        let normalized = normalizedOCRLabelText(text)
        guard !normalized.isEmpty else {
            return false
        }

        return hospitalHeaderSuffixes.contains { normalized.contains(normalizedOCRLabelText($0)) }
            || reportTitlePatterns.contains { normalized.contains(normalizedOCRLabelText($0)) }
    }

    private static func headerTextItemsAreOnSameRow(
        _ left: OCRTextItem,
        _ right: OCRTextItem
    ) -> Bool {
        let verticalOverlap = min(left.boundingBox.maxY, right.boundingBox.maxY)
            - max(left.boundingBox.y, right.boundingBox.y)
        let centerDeltaY = abs(left.boundingBox.centerY - right.boundingBox.centerY)
        let rowHeight = max(left.boundingBox.height, right.boundingBox.height)

        return verticalOverlap >= min(left.boundingBox.height, right.boundingBox.height) * 0.20
            || centerDeltaY <= max(rowHeight * 1.60, 0.032)
    }

    private static func headerJoinSeparator(
        left: OCRTextItem,
        right: OCRTextItem
    ) -> String {
        let leftText = left.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let rightText = right.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if headerTextShouldJoinWithoutSeparator(leftText, rightText) {
            return ""
        }

        let gap = right.boundingBox.x - left.boundingBox.maxX
        let rowHeight = max(left.boundingBox.height, right.boundingBox.height)
        return gap <= max(rowHeight * 0.80, 0.018) ? "" : " "
    }

    private static func headerTextShouldJoinWithoutSeparator(
        _ left: String,
        _ right: String
    ) -> Bool {
        guard let leftScalar = left.unicodeScalars.last,
              let rightScalar = right.unicodeScalars.first else {
            return true
        }

        return isCJKScalar(leftScalar)
            || isCJKScalar(rightScalar)
            || leftScalar.properties.isIdeographic
            || rightScalar.properties.isIdeographic
    }

    private static func isCJKScalar(_ scalar: UnicodeScalar) -> Bool {
        (0x3400...0x9FFF).contains(Int(scalar.value))
    }

    private static func containsCJKText(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            isCJKScalar(scalar) || scalar.properties.isIdeographic
        }
    }

    private static func headerFieldBoundingBox(
        for field: OCRHeaderField,
        in line: OCRHeaderLine
    ) -> NormalizedRect? {
        let fieldUpperBound = rangeUpperBound(field.range)
        let segmentBoxes = line.segments.compactMap { segment -> NormalizedRect? in
            let segmentUpperBound = rangeUpperBound(segment.textRange)
            let overlapStart = max(field.range.location, segment.textRange.location)
            let overlapEnd = min(fieldUpperBound, segmentUpperBound)
            guard overlapEnd > overlapStart else {
                return nil
            }

            let localRange = NSRange(
                location: overlapStart - segment.textRange.location,
                length: overlapEnd - overlapStart
            )
            return appNormalizedRect(
                for: localRange,
                in: segment.item.recognizedText,
                text: segment.item.text,
                fallbackBounds: segment.item.boundingBox
            ) ?? segment.item.boundingBox
        }

        return segmentBoxes.reduce(nil) { partialResult, box in
            partialResult.map { unionRect($0, box) } ?? box
        }
    }

    private static func headerFieldConfidence(
        for field: OCRHeaderField,
        in line: OCRHeaderLine
    ) -> Double? {
        let fieldUpperBound = rangeUpperBound(field.range)
        let confidences = line.segments.compactMap { segment -> Double? in
            let segmentUpperBound = rangeUpperBound(segment.textRange)
            guard max(field.range.location, segment.textRange.location) < min(fieldUpperBound, segmentUpperBound) else {
                return nil
            }

            return segment.item.confidence
        }

        guard !confidences.isEmpty else {
            return nil
        }

        return confidences.reduce(0, +) / Double(confidences.count)
    }

    private static func medicalReportHeaderFields(in text: String) -> [OCRHeaderField]? {
        guard let hospitalRange = hospitalHeaderRange(in: text) else {
            return nil
        }

        let nsText = text as NSString
        let hospitalText = nsText.substring(with: hospitalRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isHospitalHeaderValue(hospitalText) else {
            return nil
        }

        var fields = [
            OCRHeaderField(
                category: .hospital,
                text: hospitalText,
                range: hospitalRange
            )
        ]

        let tailRange = NSRange(
            location: rangeUpperBound(hospitalRange),
            length: max(0, nsText.length - rangeUpperBound(hospitalRange))
        )
        if let departmentField = departmentHeaderField(in: text, tailRange: tailRange) {
            fields.append(departmentField)
        }

        return fields
    }

    private static func hospitalHeaderRange(in text: String) -> NSRange? {
        if let knownRange = knownHospitalHeaderRange(in: text) {
            return knownRange
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard nsText.length > 0 else {
            return nil
        }

        var ranges: [NSRange] = []
        for suffix in hospitalHeaderSuffixes {
            var searchRange = fullRange
            while searchRange.length > 0 {
                let match = nsText.range(of: suffix, options: [], range: searchRange)
                guard match.location != NSNotFound else {
                    break
                }

                let end = rangeUpperBound(match)
                if let start = hospitalHeaderStart(in: text, endingAt: end),
                   end > start,
                   let range = trimmedHeaderComponentRange(
                       in: text,
                       range: NSRange(location: start, length: end - start)
                   ) {
                    let value = nsText.substring(with: range)
                    if !value.contains(":"),
                       !value.contains("："),
                       isHospitalHeaderValue(value) {
                        ranges.append(range)
                    }
                }

                let nextLocation = match.location + 1
                searchRange = NSRange(
                    location: nextLocation,
                    length: max(0, nsText.length - nextLocation)
                )
            }
        }

        return ranges
            .sorted { left, right in
                if left.length != right.length {
                    return left.length > right.length
                }

                if left.location != right.location {
                    return left.location < right.location
                }

                return rangeUpperBound(left) > rangeUpperBound(right)
            }
            .first
    }

    private static func knownHospitalHeaderRange(in text: String) -> NSRange? {
        let nsText = text as NSString
        return knownHospitalHeaderNames
            .compactMap { name -> NSRange? in
                let range = nsText.range(of: name, options: [.caseInsensitive])
                return range.location == NSNotFound ? nil : range
            }
            .sorted { left, right in
                if left.length != right.length {
                    return left.length > right.length
                }

                return left.location < right.location
            }
            .first
    }

    private static func hospitalHeaderStart(in text: String, endingAt end: Int) -> Int? {
        let nsText = text as NSString
        guard let firstContent = firstNonWhitespaceLocation(in: text),
              firstContent < end else {
            return nil
        }

        var start = firstContent
        for index in firstContent..<end {
            let scalar = character(at: index, in: text)
            if isCJKScalar(scalar) || scalar.properties.isIdeographic {
                start = index
                break
            }
        }

        var lastSafeStart = start
        var index = start
        while index < end {
            let scalar = character(at: index, in: text)
            if headerTrimCharacters.contains(scalar) {
                let prefixRange = NSRange(location: start, length: max(0, index - start))
                let prefix = nsText.substring(with: prefixRange)
                if !containsCJKText(prefix) {
                    lastSafeStart = index + 1
                }
            }
            index += 1
        }

        return trimmedHeaderComponentRange(
            in: text,
            range: NSRange(location: lastSafeStart, length: end - lastSafeStart)
        )?.location
    }

    private static func departmentHeaderField(
        in text: String,
        tailRange: NSRange
    ) -> OCRHeaderField? {
        guard let contentRange = trimmedHeaderComponentRange(in: text, range: tailRange) else {
            return nil
        }

        let reportStart = reportTitleStart(in: text, range: contentRange)
        let departmentRange = NSRange(
            location: contentRange.location,
            length: max(0, (reportStart ?? rangeUpperBound(contentRange)) - contentRange.location)
        )
        guard let trimmedDepartmentRange = trimmedHeaderComponentRange(in: text, range: departmentRange) else {
            return nil
        }

        let departmentText = (text as NSString).substring(with: trimmedDepartmentRange)
        guard isDepartmentHeaderValue(departmentText) else {
            return nil
        }

        return OCRHeaderField(
            category: .department,
            text: departmentText,
            range: trimmedDepartmentRange
        )
    }

    private static func reportTitleStart(in text: String, range: NSRange) -> Int? {
        let nsText = text as NSString
        var bestStart: Int?

        for pattern in reportTitlePatterns {
            var searchRange = range
            while searchRange.length > 0 {
                let match = nsText.range(of: pattern, options: [.caseInsensitive], range: searchRange)
                guard match.location != NSNotFound else {
                    break
                }

                var start = match.location
                if pattern == "报告单" {
                    start = asciiTokenStart(before: start, in: text, lowerBound: range.location)
                }

                bestStart = min(bestStart ?? start, start)
                let nextLocation = match.location + 1
                searchRange = NSRange(
                    location: nextLocation,
                    length: max(0, rangeUpperBound(range) - nextLocation)
                )
            }
        }

        return bestStart
    }

    private static func asciiTokenStart(
        before location: Int,
        in text: String,
        lowerBound: Int
    ) -> Int {
        let nsText = text as NSString
        var current = location
        while current > lowerBound {
            let previousRange = NSRange(location: current - 1, length: 1)
            let previous = nsText.substring(with: previousRange)
            guard previous.range(of: #"^[A-Za-z0-9]$"#, options: .regularExpression) != nil else {
                break
            }

            current -= 1
        }

        return current
    }

    private static func trimmedHeaderComponentRange(
        in text: String,
        range: NSRange
    ) -> NSRange? {
        let nsText = text as NSString
        var location = max(0, range.location)
        var upperBound = min(nsText.length, rangeUpperBound(range))

        while location < upperBound,
              headerTrimCharacters.contains(character(at: location, in: text)) {
            location += 1
        }

        while upperBound > location,
              headerTrimCharacters.contains(character(at: upperBound - 1, in: text)) {
            upperBound -= 1
        }

        guard upperBound > location else {
            return nil
        }

        return NSRange(location: location, length: upperBound - location)
    }

    private static func firstNonWhitespaceLocation(in text: String) -> Int? {
        let nsText = text as NSString
        for index in 0..<nsText.length where !CharacterSet.whitespacesAndNewlines.contains(character(at: index, in: text)) {
            return index
        }

        return nil
    }

    private static func character(at location: Int, in text: String) -> UnicodeScalar {
        let nsText = text as NSString
        return nsText.substring(with: NSRange(location: location, length: 1)).unicodeScalars.first
            ?? UnicodeScalar(32)!
    }

    private static func isHospitalHeaderValue(_ text: String) -> Bool {
        isCleanHospitalCandidateValue(text)
    }

    private static func isCleanHospitalCandidateValue(_ text: String) -> Bool {
        let normalized = normalizedOCRValueText(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = normalizedOCRLabelText(normalized)
        guard compact.count >= 4,
              !isTruncatedHospitalHeaderValue(normalized),
              hospitalValueHasHospitalSuffix(compact),
              !hospitalValueContainsUnrelatedFieldLabel(compact),
              !hospitalValueContainsReportTitle(compact),
              !hospitalValueContainsDepartmentOnlyText(compact) else {
            return false
        }

        return true
    }

    private static func isTruncatedHospitalHeaderValue(_ text: String) -> Bool {
        let compact = normalizedOCRLabelText(text)
        return compact.hasPrefix("院附属")
    }

    private static func hospitalValueHasHospitalSuffix(_ compactText: String) -> Bool {
        hospitalHeaderSuffixes.contains { suffix in
            compactText.hasSuffix(normalizedOCRLabelText(suffix))
        }
    }

    private static func hospitalValueContainsUnrelatedFieldLabel(_ compactText: String) -> Bool {
        if hospitalPollutionPrefixPatterns.contains(where: { label in
            let normalizedLabel = normalizedOCRLabelText(label)
            return !normalizedLabel.isEmpty && compactText.hasPrefix(normalizedLabel)
        }) {
            return true
        }

        return hospitalPollutionLabelPatterns.contains { label in
            let normalizedLabel = normalizedOCRLabelText(label)
            return !normalizedLabel.isEmpty && compactText.contains(normalizedLabel)
        }
    }

    private static func hospitalValueContainsReportTitle(_ compactText: String) -> Bool {
        reportTitlePatterns.contains { pattern in
            let normalizedPattern = normalizedOCRLabelText(pattern)
            return !normalizedPattern.isEmpty && compactText.contains(normalizedPattern)
        }
    }

    private static func hospitalValueContainsDepartmentOnlyText(_ compactText: String) -> Bool {
        departmentHeaderSuffixes.contains { suffix in
            let normalizedSuffix = normalizedOCRLabelText(suffix)
            return normalizedSuffix.count > 1 && compactText.contains(normalizedSuffix)
        }
    }

    private static func isDepartmentHeaderValue(_ text: String) -> Bool {
        let normalized = normalizedOCRValueText(text)
        guard normalized.count >= 2,
              normalized.count <= 30,
              !reportTitlePatterns.contains(where: { normalized.localizedCaseInsensitiveContains($0) }) else {
            return false
        }

        return departmentHeaderSuffixes.contains { normalized.hasSuffix($0) }
    }

    private static func splitNameLabelGroups(from splitItems: [OCRSplitNameLabelItem]) -> [OCRSplitNameLabelGroup] {
        let surnames = splitItems
            .filter { $0.part == .surname }
            .sorted(by: splitNameLabelPrecedes)
        let givenNames = splitItems
            .filter { $0.part == .givenName }
            .sorted(by: splitNameLabelPrecedes)
        var consumedIndexes = Set<Int>()
        var groups: [OCRSplitNameLabelGroup] = []

        for surname in surnames {
            guard !consumedIndexes.contains(surname.index) else {
                continue
            }

            if let givenName = givenNames
                .filter({
                          !consumedIndexes.contains($0.index)
                              && splitNameLabelsBelongToSameField(surname.boundingBox, $0.boundingBox)
                      })
                .sorted(by: {
                          splitNameLabelGroupScore(surname.boundingBox, $0.boundingBox)
                              < splitNameLabelGroupScore(surname.boundingBox, $1.boundingBox)
                      })
                .first {
                let group = OCRSplitNameLabelGroup(
                    surnameIndex: surname.index,
                    givenNameIndex: givenName.index,
                    surnameBoundingBox: surname.boundingBox,
                    givenNameBoundingBox: givenName.boundingBox,
                    labelBoundingBox: unionRect(surname.boundingBox, givenName.boundingBox),
                    confidence: min(surname.confidence, givenName.confidence),
                    inlineValues: [surname.inlineValue, givenName.inlineValue].compactMap(\.self)
                )
                groups.append(group)
                consumedIndexes.insert(surname.index)
                consumedIndexes.insert(givenName.index)
            } else {
                let group = OCRSplitNameLabelGroup(
                    surnameIndex: surname.index,
                    givenNameIndex: nil,
                    surnameBoundingBox: surname.boundingBox,
                    givenNameBoundingBox: nil,
                    labelBoundingBox: surname.boundingBox,
                    confidence: surname.confidence,
                    inlineValues: [surname.inlineValue].compactMap(\.self)
                )
                groups.append(group)
                consumedIndexes.insert(surname.index)
            }
        }

        return groups
    }

    private static func splitNameLabelPart(for text: String) -> OCRSplitNameLabelPart? {
        switch normalizedSplitNameLabelText(text) {
        case "姓":
            return .surname
        case "名":
            return .givenName
        default:
            return nil
        }
    }

    private static func splitNameLabelMatch(
        for item: OCRTextItem
    ) -> (part: OCRSplitNameLabelPart, inlineValue: OCRSplitNameInlineValue?)? {
        if let part = splitNameLabelPart(for: item.text) {
            return (part, nil)
        }

        if let part = emptyFillSplitNameLabelPart(for: item.text) {
            return (part, nil)
        }

        guard let inlineMatch = splitNameInlineValue(in: item) else {
            return nil
        }

        return (inlineMatch.part, inlineMatch.value)
    }

    private static func emptyFillSplitNameLabelPart(for text: String) -> OCRSplitNameLabelPart? {
        let normalizedText = normalizedOCRValueText(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let labelIndex = normalizedText.firstIndex(where: { !$0.isWhitespace }) else {
            return nil
        }

        let part: OCRSplitNameLabelPart
        switch normalizedText[labelIndex] {
        case "姓":
            part = .surname
        case "名":
            part = .givenName
        default:
            return nil
        }

        let remainderStart = normalizedText.index(after: labelIndex)
        let remainder = String(normalizedText[remainderStart...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else {
            return part
        }

        return remainder.allSatisfy(isSplitNameEmptyFillCharacter) ? part : nil
    }

    nonisolated private static func isSplitNameEmptyFillCharacter(_ character: Character) -> Bool {
        if isSplitNameInlineSeparator(character) {
            return true
        }

        return ["_", "-", "—", "–", "－", ".", "．", "·", "•", "|", "/", "\\", "﹕", "∶"].contains(character)
    }

    private static func splitNameInlineValue(
        in item: OCRTextItem
    ) -> (part: OCRSplitNameLabelPart, value: OCRSplitNameInlineValue)? {
        let text = item.text
        guard let labelIndex = text.firstIndex(where: { !$0.isWhitespace }) else {
            return nil
        }

        let part: OCRSplitNameLabelPart
        switch text[labelIndex] {
        case "姓":
            part = .surname
        case "名":
            part = .givenName
        default:
            return nil
        }

        var valueStart = text.index(after: labelIndex)
        var sawSeparator = false
        while valueStart < text.endIndex {
            let character = text[valueStart]
            if character.isWhitespace {
                valueStart = text.index(after: valueStart)
                continue
            }

            guard isSplitNameInlineSeparator(character) else {
                break
            }

            sawSeparator = true
            valueStart = text.index(after: valueStart)
        }

        guard sawSeparator, valueStart < text.endIndex else {
            return nil
        }

        let rawValue = String(text[valueStart...])
        let normalizedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedValue.isEmpty,
              likelyHumanNameDisplayValue(from: normalizedValue) != nil
                  || likelySplitNamePartComponent(from: normalizedValue, for: part) != nil else {
            return nil
        }

        let valueRange = NSRange(valueStart..<text.endIndex, in: text)
        let valueBox = appNormalizedRect(
            for: valueRange,
            in: item.recognizedText,
            text: item.text,
            fallbackBounds: item.boundingBox
        ) ?? item.boundingBox

        return (
            part,
            OCRSplitNameInlineValue(
                part: part,
                text: normalizedValue,
                boundingBox: valueBox,
                confidence: item.confidence
            )
        )
    }

    nonisolated private static func isSplitNameInlineSeparator(_ character: Character) -> Bool {
        [":", "：", "﹕", "∶", "︰", ";", "；", "﹔"].contains(character)
    }

    nonisolated private static func splitNameLabelPrecedes(
        _ left: OCRSplitNameLabelItem,
        _ right: OCRSplitNameLabelItem
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

    private static func splitNameLabelsBelongToSameField(
        _ left: NormalizedRect,
        _ right: NormalizedRect
    ) -> Bool {
        verticallyStackedSplitNameLabels(left, right)
            || horizontallyAdjacentSplitNameLabels(left, right)
    }

    private static func verticallyStackedSplitNameLabels(
        _ left: NormalizedRect,
        _ right: NormalizedRect
    ) -> Bool {
        let horizontalOverlap = min(left.maxX, right.maxX) - max(left.x, right.x)
        let centerDeltaX = abs(left.centerX - right.centerX)
        let verticalGap = max(0, max(left.y, right.y) - min(left.maxY, right.maxY))
        let centerDeltaY = abs(left.centerY - right.centerY)
        let rowHeight = max(left.height, right.height)
        let horizontalAligned = horizontalOverlap >= -max(left.width, right.width) * 0.35
            || centerDeltaX <= max(left.width, right.width) * 1.5 + 0.05

        return horizontalAligned
            && verticalGap <= max(rowHeight * 3.5, 0.08)
            && centerDeltaY <= max(rowHeight * 5.0, 0.14)
    }

    private static func horizontallyAdjacentSplitNameLabels(
        _ left: NormalizedRect,
        _ right: NormalizedRect
    ) -> Bool {
        let verticalOverlap = min(left.maxY, right.maxY) - max(left.y, right.y)
        let centerDeltaY = abs(left.centerY - right.centerY)
        let horizontalGap = max(0, max(left.x, right.x) - min(left.maxX, right.maxX))
        let rowHeight = max(left.height, right.height)
        let sameRow = verticalOverlap > 0
            || centerDeltaY <= max(rowHeight * 0.9, 0.02)

        return sameRow
            && horizontalGap <= max(max(left.width, right.width) * 3.0, 0.12)
    }

    private static func splitNameLabelGroupScore(
        _ left: NormalizedRect,
        _ right: NormalizedRect
    ) -> Double {
        let horizontalGap = max(0, max(left.x, right.x) - min(left.maxX, right.maxX))
        let verticalGap = max(0, max(left.y, right.y) - min(left.maxY, right.maxY))

        return horizontalGap + verticalGap + abs(left.centerX - right.centerX) + abs(left.centerY - right.centerY)
    }

    private static func unionRect(
        _ left: NormalizedRect,
        _ right: NormalizedRect
    ) -> NormalizedRect {
        let x = min(left.x, right.x)
        let y = min(left.y, right.y)
        let maxX = max(left.maxX, right.maxX)
        let maxY = max(left.maxY, right.maxY)

        return NormalizedRect(
            x: x,
            y: y,
            width: maxX - x,
            height: maxY - y
        )
        .clamped()
    }

    private static func candidateNearSplitNameLabel(
        _ group: OCRSplitNameLabelGroup,
        textItems: [OCRTextItem],
        pageID: PageItem.ID,
        options: OCRDetectionOptions,
        context: OCRProcessingContext
    ) -> OCRSensitiveCandidate? {
        if let inlineCandidate = inlineSplitNameValueCandidate(group, pageID: pageID) {
            return inlineCandidate
        }

        if let componentCandidate = splitNameComponentValueCandidate(
            group,
            textItems: textItems,
            pageID: pageID
        ) {
            return componentCandidate
        }

        if let roiCandidate = splitNameROIValueCandidate(
            group,
            textItems: textItems,
            pageID: pageID,
            context: context
        ) {
            return roiCandidate
        }

        if let filteredROICandidate = splitNameFallbackROIValueCandidate(
            group,
            textItems: textItems,
            pageID: pageID,
            context: context
        ) {
            return filteredROICandidate
        }

        let fallbackBox = likelySplitNameFillArea(for: group)
        guard allowsLabelFallback(
            for: .name,
            fallbackBox: fallbackBox,
            options: options
        ),
              fallbackRegionHasVisibleContent(
                  category: .name,
                  labelRule: nil,
                  labelItem: nil,
                  labelBox: group.labelBoundingBox,
                  fallbackBox: fallbackBox,
                  textItems: textItems,
                  excluding: group.itemIndexes,
                  context: context
              ) else {
            return nil
        }

        let candidate = OCRSensitiveCandidate(
            pageID: pageID,
            text: L10n.Review.ocrNoExplicitValue,
            category: .name,
            sourceLabelText: "姓名",
            confidence: group.confidence,
            boundingBox: fallbackBox,
            labelBoundingBox: group.labelBoundingBox,
            detectionKind: .labelFallback
        )
        return candidate
    }

    private static func inlineSplitNameValueCandidate(
        _ group: OCRSplitNameLabelGroup,
        pageID: PageItem.ID
    ) -> OCRSensitiveCandidate? {
        guard !group.inlineValues.isEmpty else {
            return nil
        }

        if let combinedCandidate = combinedSplitNameComponentCandidate(
            from: group.inlineValues.compactMap { inlineValue in
                guard let component = likelySplitNamePartComponent(from: inlineValue.text, for: inlineValue.part) else {
                    return nil
                }

                return OCRSplitNameComponentValue(
                    part: inlineValue.part,
                    text: component,
                    boundingBox: inlineValue.boundingBox,
                    confidence: inlineValue.confidence,
                    sourceIndex: nil
                )
            },
            group: group,
            pageID: pageID
        ) {
            return combinedCandidate
        }

        return nil
    }

    private static func splitNameComponentValueCandidate(
        _ group: OCRSplitNameLabelGroup,
        textItems: [OCRTextItem],
        pageID: PageItem.ID
    ) -> OCRSensitiveCandidate? {
        guard let givenNameBoundingBox = group.givenNameBoundingBox else {
            return nil
        }

        guard let surname = splitNameComponentValue(
            for: .surname,
            labelBox: group.surnameBoundingBox,
            textItems: textItems,
            excluding: group.itemIndexes
        ) else {
            return nil
        }

        var excludedIndexes = group.itemIndexes
        if let sourceIndex = surname.sourceIndex {
            excludedIndexes.insert(sourceIndex)
        }

        guard let givenName = splitNameComponentValue(
            for: .givenName,
            labelBox: givenNameBoundingBox,
            textItems: textItems,
            excluding: excludedIndexes
        ) else {
            return nil
        }

        return combinedSplitNameComponentCandidate(
            from: [surname, givenName],
            group: group,
            pageID: pageID
        )
    }

    private static func splitNameComponentValue(
        for part: OCRSplitNameLabelPart,
        labelBox: NormalizedRect,
        textItems: [OCRTextItem],
        excluding excludedIndexes: Set<Int>
    ) -> OCRSplitNameComponentValue? {
        splitNameComponentValue(
            for: part,
            labelBox: labelBox,
            textItems: textItems,
            excluding: excludedIndexes,
            mode: .sameLineRight
        )
    }

    private static func splitNameComponentValue(
        for part: OCRSplitNameLabelPart,
        labelBox: NormalizedRect,
        textItems: [OCRTextItem],
        excluding excludedIndexes: Set<Int>,
        mode: OCRValueSearchMode
    ) -> OCRSplitNameComponentValue? {
        textItems
            .enumerated()
            .compactMap { index, item -> OCRSplitNameComponentValue? in
                guard !excludedIndexes.contains(index),
                      isLikelyNeighborValue(item.text),
                      let component = likelySplitNamePartComponent(from: item.text, for: part),
                      item.boundingBox.width > 0.005,
                      item.boundingBox.height > 0.005,
                      splitNameComponentValueIsInExpectedArea(
                          item.boundingBox,
                          labelBox: labelBox,
                          mode: mode
                      ) else {
                    return nil
                }

                return OCRSplitNameComponentValue(
                    part: part,
                    text: component,
                    boundingBox: item.boundingBox,
                    confidence: item.confidence,
                    sourceIndex: index
                )
            }
            .sorted { left, right in
                valueDistance(from: labelBox, to: left.boundingBox, mode: mode)
                    < valueDistance(from: labelBox, to: right.boundingBox, mode: mode)
            }
            .first
    }

    private static func splitNameComponentValueIsInExpectedArea(
        _ valueBox: NormalizedRect,
        labelBox: NormalizedRect,
        mode: OCRValueSearchMode
    ) -> Bool {
        switch mode {
        case .sameLineRight:
            let verticalCenterDelta = abs(valueBox.centerY - labelBox.centerY)
            let rightGap = valueBox.x - labelBox.maxX

            return rightGap >= -0.015
                && rightGap <= 0.32
                && verticalCenterDelta <= max(labelBox.height, valueBox.height) * 0.80
                && valueBox.maxX <= min(labelBox.maxX + 0.46, 1)
        case .below:
            return false
        }
    }

    private static func splitNameComponentValueIsInLooseRowBand(
        _ valueBox: NormalizedRect,
        labelBox: NormalizedRect
    ) -> Bool {
        let verticalCenterDelta = abs(valueBox.centerY - labelBox.centerY)
        let rightGap = valueBox.x - labelBox.maxX

        return rightGap >= -0.015
            && rightGap <= 0.38
            && verticalCenterDelta <= max(labelBox.height, valueBox.height) * 1.45 + 0.006
            && valueBox.maxX <= min(labelBox.maxX + 0.50, 1)
    }

    private static func combinedSplitNameComponentCandidate(
        from components: [OCRSplitNameComponentValue],
        group: OCRSplitNameLabelGroup,
        pageID: PageItem.ID
    ) -> OCRSensitiveCandidate? {
        guard let surname = components.first(where: { $0.part == .surname }),
              let givenName = components.first(where: { $0.part == .givenName }) else {
            return nil
        }

        if let surnameIndex = surname.sourceIndex,
           let givenNameIndex = givenName.sourceIndex,
           surnameIndex == givenNameIndex {
            return nil
        }

        let combinedValue = surname.text + givenName.text
        guard let nameValue = likelyHumanNameDisplayValue(from: combinedValue) else {
            return nil
        }

        let combinedBox = unionRect(surname.boundingBox, givenName.boundingBox)

        return OCRSensitiveCandidate(
            pageID: pageID,
            text: nameValue,
            category: .name,
            sourceLabelText: "姓名",
            confidence: min(group.confidence, surname.confidence, givenName.confidence),
            boundingBox: combinedBox.padded(horizontal: 0.003, vertical: 0.004),
            labelBoundingBox: group.labelBoundingBox,
            detectionKind: .labelValue
        )
    }

    private static func observedLabel(
        for labelRule: OCRLabelRule,
        in labelItem: OCRTextItem
    ) -> OCRObservedLabel? {
        guard let labelMatch = labelTextMatch(for: labelRule, in: labelItem.text) else {
            return nil
        }

        let bounds = appNormalizedRect(
            for: labelMatch.range,
            in: labelItem.recognizedText,
            text: labelItem.text,
            fallbackBounds: labelItem.boundingBox
        ) ?? labelItem.boundingBox

        return OCRObservedLabel(
            title: labelMatch.title,
            range: labelMatch.range,
            boundingBox: bounds
        )
    }

    private static func sourceLabelObservation(
        for category: OCRCandidateCategory,
        in item: OCRTextItem,
        before targetRange: NSRange
    ) -> OCRObservedLabel? {
        guard let labelRule = sourceLabelRule(for: category),
              targetRange.location > 0 else {
            return nil
        }

        let nsText = item.text as NSString
        let prefixRange = NSRange(location: 0, length: min(targetRange.location, nsText.length))
        let prefix = nsText.substring(with: prefixRange)
        guard let labelMatch = labelTextMatch(for: labelRule, in: prefix) else {
            return nil
        }

        let labelBounds = appNormalizedRect(
            for: labelMatch.range,
            in: item.recognizedText,
            text: item.text,
            fallbackBounds: item.boundingBox
        ) ?? item.boundingBox

        return OCRObservedLabel(
            title: labelMatch.title,
            range: labelMatch.range,
            boundingBox: labelBounds
        )
    }

    private static func sourceLabelRule(for category: OCRCandidateCategory) -> OCRLabelRule? {
        switch category {
        case .documentNumber:
            return labelRules.first { $0.category == .chineseID }
        default:
            return labelRules.first { $0.category == category }
        }
    }

    private static func labelTextMatch(
        for labelRule: OCRLabelRule,
        in text: String
    ) -> OCRLabelTextMatch? {
        guard labelRule.matches(text) else {
            return nil
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        for pattern in labelRule.labelPatterns.sorted(by: { $0.count > $1.count }) {
            let normalizedPattern = normalizedOCRLabelText(pattern)
            if isSingleCharacterSplitNameLabelPattern(normalizedPattern),
               normalizedSplitNameLabelText(text) != normalizedPattern {
                continue
            }

            let escapedPattern = NSRegularExpression.escapedPattern(for: pattern)
            let regex = try! NSRegularExpression(
                pattern: "\(escapedPattern)\\s*[:：;；.。｡﹕∶︰﹔]?",
                options: [.caseInsensitive]
            )

            if let match = regex.firstMatch(in: text, range: fullRange) {
                return OCRLabelTextMatch(
                    title: sanitizedSourceLabelTitle(pattern),
                    range: match.range
                )
            }

            if normalizedOCRLabelText(text).localizedCaseInsensitiveContains(normalizedPattern) {
                let rangeLength = min((pattern as NSString).length, nsText.length)
                guard rangeLength > 0 else {
                    continue
                }

                return OCRLabelTextMatch(
                    title: sanitizedSourceLabelTitle(pattern),
                    range: NSRange(location: 0, length: rangeLength)
                )
            }
        }

        if labelRule.category == .staffSignature,
           let fuzzyMatch = fuzzyStaffSignatureLabelTextMatch(in: text) {
            return fuzzyMatch
        }

        return nil
    }

    private static func lastLabelTextMatch(
        for labelRule: OCRLabelRule,
        in text: String
    ) -> OCRLabelTextMatch? {
        if labelRule.category == .name, isForbiddenNameLabelText(text) {
            return nil
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var bestMatch: OCRLabelTextMatch?

        for pattern in labelRule.labelPatterns {
            let normalizedPattern = normalizedOCRLabelText(pattern)
            if isSingleCharacterSplitNameLabelPattern(normalizedPattern),
               normalizedSplitNameLabelText(text) != normalizedPattern {
                continue
            }

            let escapedPattern = NSRegularExpression.escapedPattern(for: pattern)
            let regex = try! NSRegularExpression(
                pattern: "\(escapedPattern)\\s*[:：;；.。｡﹕∶︰﹔]?",
                options: [.caseInsensitive]
            )

            for match in regex.matches(in: text, range: fullRange) {
                let candidate = OCRLabelTextMatch(
                    title: sanitizedSourceLabelTitle(pattern),
                    range: match.range
                )
                guard let currentBest = bestMatch else {
                    bestMatch = candidate
                    continue
                }

                let candidateEnd = rangeUpperBound(candidate.range)
                let bestEnd = rangeUpperBound(currentBest.range)
                if candidateEnd > bestEnd
                    || (candidateEnd == bestEnd && candidate.range.length > currentBest.range.length) {
                    bestMatch = candidate
                }
            }
        }

        return bestMatch
    }

    private static func rangeUpperBound(_ range: NSRange) -> Int {
        range.location + range.length
    }

    private static func sanitizedSourceLabelTitle(_ text: String) -> String {
        normalizedOCRValueText(text)
            .trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines
                    .union(CharacterSet(charactersIn: ":：;；,，.。\"'“”‘’()（）[]【】"))
            )
    }

    private static func phoneFallbackBox(
        toRightOf labelBox: NormalizedRect,
        labelRule: OCRLabelRule,
        labelItem: OCRTextItem,
        textItems: [OCRTextItem],
        excluding excludedIndexes: Set<Int>
    ) -> NormalizedRect {
        var fallbackBox = likelyPhoneFillArea(toRightOf: labelBox)

        if let inlineValueRange = labelRule.inlineValueRange(in: labelItem.text),
           phoneValueCandidateText((labelItem.text as NSString).substring(with: inlineValueRange)),
           let inlineValueBox = appNormalizedRect(
               for: inlineValueRange,
               in: labelItem.recognizedText,
               text: labelItem.text,
               fallbackBounds: labelItem.boundingBox
           ),
           phoneValueBox(inlineValueBox, isSameRowRightOf: labelBox) {
            fallbackBox = unionRect(fallbackBox, inlineValueBox).clamped()
        }

        for (index, item) in textItems.enumerated() {
            guard !excludedIndexes.contains(index),
                  phoneValueCandidateText(item.text),
                  phoneValueBox(item.boundingBox, isSameRowRightOf: labelBox) else {
                continue
            }

            fallbackBox = unionRect(fallbackBox, item.boundingBox).clamped()
        }

        return fallbackBox
    }

    private static func phoneRowOCRValueCandidate(
        labelRule: OCRLabelRule,
        labelItem: OCRTextItem,
        observedLabel: OCRObservedLabel,
        pageID: PageItem.ID,
        context: OCRProcessingContext
    ) -> OCRSensitiveCandidate? {
        guard let sourceImage = context.sourceImage else {
            return nil
        }

        let rowBox = phoneRowOCRRegion(toRightOf: observedLabel.boundingBox)
        guard let croppedImage = croppedImage(sourceImage, to: rowBox) else {
            return nil
        }

        if let candidate = phoneRowOCRValueCandidate(
            in: croppedImage,
            rowBox: rowBox,
            labelBox: observedLabel.boundingBox,
            labelTitle: observedLabel.title,
            labelConfidence: labelItem.confidence,
            pageID: pageID
        ) {
            return candidate
        }

        guard let scaledImage = scaledImage(croppedImage, scale: 3) else {
            return nil
        }

        return phoneRowOCRValueCandidate(
            in: scaledImage,
            rowBox: rowBox,
            labelBox: observedLabel.boundingBox,
            labelTitle: observedLabel.title,
            labelConfidence: labelItem.confidence,
            pageID: pageID
        )
    }

    private static func phoneSameRowValueCandidate(
        labelRule: OCRLabelRule,
        labelItem: OCRTextItem,
        observedLabel: OCRObservedLabel,
        textItems: [OCRTextItem],
        excluding excludedIndexes: Set<Int>,
        pageID: PageItem.ID
    ) -> OCRSensitiveCandidate? {
        var fragments: [OCRPhoneValueFragment] = []

        if let inlineValueRange = labelRule.inlineValueRange(in: labelItem.text),
           let match = phoneValueMatch(
               in: (labelItem.text as NSString).substring(with: inlineValueRange),
               minimumDigits: 1
           ),
           let inlineValueBox = appNormalizedRect(
               for: inlineValueRange,
               in: labelItem.recognizedText,
               text: labelItem.text,
               fallbackBounds: labelItem.boundingBox
           ),
           phoneValueBox(inlineValueBox, isSameRowRightOf: observedLabel.boundingBox) {
            fragments.append(
                OCRPhoneValueFragment(
                    value: match.value,
                    boundingBox: inlineValueBox,
                    confidence: labelItem.confidence
                )
            )
        }

        for (index, item) in textItems.enumerated() {
            guard !excludedIndexes.contains(index),
                  let match = phoneValueMatch(in: item.text, minimumDigits: 1) else {
                continue
            }

            let valueBox = appNormalizedRect(
                for: match.range,
                in: item.recognizedText,
                text: item.text,
                fallbackBounds: item.boundingBox
            ) ?? item.boundingBox
            guard phoneValueBox(valueBox, isSameRowRightOf: observedLabel.boundingBox) else {
                continue
            }

            fragments.append(
                OCRPhoneValueFragment(
                    value: match.value,
                    boundingBox: valueBox,
                    confidence: item.confidence
                )
            )
        }

        let selectedFragments = fragments
            .sorted { left, right in
                if abs(left.boundingBox.centerY - right.boundingBox.centerY) > max(left.boundingBox.height, right.boundingBox.height) {
                    return left.boundingBox.y < right.boundingBox.y
                }

                return left.boundingBox.x < right.boundingBox.x
            }
            .filter {
                abs($0.boundingBox.centerY - observedLabel.boundingBox.centerY) <= max($0.boundingBox.height, observedLabel.boundingBox.height) * 0.95
            }

        guard !selectedFragments.isEmpty else {
            return nil
        }

        let combinedDigits = selectedFragments.map(\.value).joined().filter(\.isNumber)
        guard phoneValueIsAcceptable(combinedDigits) else {
            return nil
        }

        let combinedBox = selectedFragments
            .dropFirst()
            .reduce(selectedFragments[0].boundingBox) { currentBox, fragment in
                let x = min(currentBox.x, fragment.boundingBox.x)
                let y = min(currentBox.y, fragment.boundingBox.y)
                let maxX = max(currentBox.x + currentBox.width, fragment.boundingBox.x + fragment.boundingBox.width)
                let maxY = max(currentBox.y + currentBox.height, fragment.boundingBox.y + fragment.boundingBox.height)

                return NormalizedRect(
                    x: x,
                    y: y,
                    width: maxX - x,
                    height: maxY - y
                )
                .clamped()
            }
        let outputBox = unionRect(
            likelyPhoneFillArea(toRightOf: observedLabel.boundingBox),
            combinedBox
        )

        return OCRSensitiveCandidate(
            pageID: pageID,
            text: combinedDigits,
            category: .phone,
            sourceLabelText: observedLabel.title,
            confidence: min(labelItem.confidence, selectedFragments.map(\.confidence).min() ?? labelItem.confidence),
            boundingBox: outputBox.padded(horizontal: 0.003, vertical: 0.001),
            labelBoundingBox: observedLabel.boundingBox,
            detectionKind: .labelValue
        )
    }

    private static func phoneRowOCRValueCandidate(
        in rowImage: CGImage,
        rowBox: NormalizedRect,
        labelBox: NormalizedRect,
        labelTitle: String,
        labelConfidence: Double,
        pageID: PageItem.ID
    ) -> OCRSensitiveCandidate? {
        guard let observations = try? recognizedTextObservations(in: rowImage) else {
            return nil
        }

        let fragments = recognizedTextItems(from: observations, minimumConfidence: 0.08)
            .compactMap { item -> OCRPhoneValueFragment? in
                guard let match = phoneValueMatch(in: item.text, minimumDigits: 1) else {
                    return nil
                }

                let localBox = appNormalizedRect(
                    for: match.range,
                    in: item.recognizedText,
                    text: item.text,
                    fallbackBounds: item.boundingBox
                ) ?? item.boundingBox
                let pageBox = pageRect(from: localBox, in: rowBox)
                guard phoneValueBox(pageBox, isSameRowRightOf: labelBox) else {
                    return nil
                }

                return OCRPhoneValueFragment(
                    value: match.value,
                    boundingBox: pageBox,
                    confidence: item.confidence
                )
            }
            .sorted { left, right in
                if abs(left.boundingBox.centerY - right.boundingBox.centerY) > max(left.boundingBox.height, right.boundingBox.height) {
                    return left.boundingBox.y < right.boundingBox.y
                }

                return left.boundingBox.x < right.boundingBox.x
            }

        guard !fragments.isEmpty else {
            return nil
        }

        let sameRowFragments = fragments.filter {
            abs($0.boundingBox.centerY - labelBox.centerY) <= max($0.boundingBox.height, labelBox.height) * 0.95
        }
        let selectedFragments = sameRowFragments.isEmpty ? fragments : sameRowFragments
        let combinedDigits = selectedFragments.map(\.value).joined().filter(\.isNumber)
        guard phoneValueIsAcceptable(combinedDigits) else {
            return nil
        }

        let combinedBox = selectedFragments
            .dropFirst()
            .reduce(selectedFragments[0].boundingBox) { currentBox, fragment in
                let x = min(currentBox.x, fragment.boundingBox.x)
                let y = min(currentBox.y, fragment.boundingBox.y)
                let maxX = max(currentBox.x + currentBox.width, fragment.boundingBox.x + fragment.boundingBox.width)
                let maxY = max(currentBox.y + currentBox.height, fragment.boundingBox.y + fragment.boundingBox.height)

                return NormalizedRect(
                    x: x,
                    y: y,
                    width: maxX - x,
                    height: maxY - y
                )
                .clamped()
            }
        let outputBox = unionRect(likelyPhoneFillArea(toRightOf: labelBox), combinedBox)

        return OCRSensitiveCandidate(
            pageID: pageID,
            text: combinedDigits,
            category: .phone,
            sourceLabelText: labelTitle,
            confidence: min(labelConfidence, selectedFragments.map(\.confidence).min() ?? labelConfidence),
            boundingBox: outputBox.padded(horizontal: 0.003, vertical: 0.001),
            labelBoundingBox: labelBox,
            detectionKind: .labelValue
        )
    }

    private static func phoneRowOCRRegion(toRightOf labelBox: NormalizedRect) -> NormalizedRect {
        let gap = max(0.008, labelBox.height * 0.28)
        let x = min(labelBox.maxX + gap, 0.96)
        let height = min(max(labelBox.height * 2.15, 0.034), 0.060)
        let y = max(labelBox.centerY - height / 2, 0)
        let width = min(max(0.26, labelBox.width * 4.4), 0.46, 0.98 - x)

        return NormalizedRect(
            x: x,
            y: y,
            width: width,
            height: min(height, 1 - y)
        )
        .clamped()
    }

    private static func phoneValueMatch(
        in text: String,
        minimumDigits: Int = 5
    ) -> OCRPhoneValueMatch? {
        guard !isEmailLikeText(text),
              normalizedDateValue(text) == nil,
              !isKnownLabelOnlyText(text) else {
            return nil
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let pattern = minimumDigits <= 1
            ? #"[0-9０-９][0-9０-９\s().\-]{0,24}"#
            : #"(?:\+?86[\s\-]?)?(?:[0-9０-９][0-9０-９\s().\-]{2,24}[0-9０-９]|[0-9０-９]{4,18})"#
        let regex = try! NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        )

        return regex
            .matches(in: text, range: fullRange)
            .compactMap { match -> OCRPhoneValueMatch? in
                let rawValue = nsText.substring(with: match.range)
                let normalizedValue = normalizedOCRValueText(rawValue)
                let digits = String(normalizedValue.filter(\.isNumber))
                guard phoneValueIsAcceptable(digits, minimumDigits: minimumDigits) else {
                    return nil
                }

                return OCRPhoneValueMatch(
                    value: digits,
                    range: match.range,
                    digitCount: digits.count
                )
            }
            .sorted { left, right in
                if left.digitCount != right.digitCount {
                    return left.digitCount > right.digitCount
                }

                return left.range.location < right.range.location
            }
            .first
    }

    private static func chineseIDMatch(in text: String) -> OCRChineseIDMatch? {
        if let targetMatch = targetRules
            .filter({ $0.category == .chineseID })
            .flatMap({ $0.matches(in: text) })
            .first {
            return OCRChineseIDMatch(
                value: targetMatch.text,
                range: targetMatch.targetRange
            )
        }

        let normalizedText = normalizedOCRValueText(text)
        let nsText = normalizedText as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let regex = try! NSRegularExpression(
            pattern: #"(?<![0-9A-Za-z])\d{17}[0-9Xx](?![0-9A-Za-z])"#,
            options: []
        )

        guard let match = regex.firstMatch(in: normalizedText, range: fullRange) else {
            return nil
        }

        return OCRChineseIDMatch(
            value: nsText.substring(with: match.range),
            range: match.range
        )
    }

    private static func phoneValueIsAcceptable(
        _ digits: String,
        minimumDigits: Int = 5
    ) -> Bool {
        let digitCount = digits.count
        guard digitCount >= minimumDigits, digitCount <= 18 else {
            return false
        }

        if digitCount == 18, isChineseIDLikeText(digits) {
            return false
        }

        return true
    }

    private static func candidateNearLabel(
        labelRule: OCRLabelRule,
        labelItem: OCRTextItem,
        labelIndex: Int,
        textItems: [OCRTextItem],
        pageID: PageItem.ID,
        options: OCRDetectionOptions,
        context: OCRProcessingContext
    ) -> OCRSensitiveCandidate? {
        guard let observedLabel = observedLabel(for: labelRule, in: labelItem) else {
            return nil
        }

        if labelRule.category == .staffSignature {
            return staffSignatureCandidate(
                labelRule: labelRule,
                labelItem: labelItem,
                labelIndex: labelIndex,
                observedLabel: observedLabel,
                textItems: textItems,
                pageID: pageID,
                options: options,
                context: context
            )
        }

        if let inlineValue = inlineValueCandidate(
            labelRule: labelRule,
            labelItem: labelItem,
            observedLabel: observedLabel,
            options: options,
            pageID: pageID
        ) {
            return inlineValue
        }

        if labelRule.category == .name,
           options.preset == .standard,
           labelRule.inlineValueRange(
               in: labelItem.text,
               allowsNameWithSpaces: true
           ) != nil {
            return nil
        }

        let valueItem = if usesStandardPhoneExtraction(
            for: labelRule.category,
            options: options
        ) {
            nearestValueItem(
                for: observedLabel.boundingBox,
                category: labelRule.category,
                in: textItems,
                excluding: [labelIndex],
                mode: .sameLineRight
            )
        } else {
            nearestValueItem(
                for: observedLabel.boundingBox,
                category: labelRule.category,
                in: textItems,
                excluding: [labelIndex],
                mode: .sameLineRight
            ) ?? nearestValueItem(
                for: observedLabel.boundingBox,
                category: labelRule.category,
                in: textItems,
                excluding: [labelIndex],
                mode: .below
            )
        }

        if let valueItem {
            return OCRSensitiveCandidate(
                pageID: pageID,
                text: displayText(valueItem.text, for: labelRule.category),
                category: labelRule.category,
                sourceLabelText: sourceLabelText(
                    observedLabel.title,
                    for: labelRule.category,
                    options: options
                ),
                confidence: min(labelItem.confidence, valueItem.confidence),
                boundingBox: valueItem.boundingBox.padded(horizontal: 0.003, vertical: 0.004),
                labelBoundingBox: observedLabel.boundingBox,
                detectionKind: .labelValue
            )
        }

        if options.preset == .strict,
           labelRule.category == .birthday,
           let idBirthdayCandidate = birthdayFromNearbyIDValueCandidate(
               observedLabel: observedLabel,
               labelConfidence: labelItem.confidence,
               textItems: textItems,
               excluding: [labelIndex],
               pageID: pageID
           ) {
            return idBirthdayCandidate
        }

        if usesStandardPhoneExtraction(for: labelRule.category, options: options),
           let sameRowCandidate = phoneSameRowValueCandidate(
               labelRule: labelRule,
               labelItem: labelItem,
               observedLabel: observedLabel,
               textItems: textItems,
               excluding: [labelIndex],
               pageID: pageID
           ) {
            return sameRowCandidate
        }

        if usesStandardPhoneExtraction(for: labelRule.category, options: options),
           let roiCandidate = phoneRowOCRValueCandidate(
               labelRule: labelRule,
               labelItem: labelItem,
               observedLabel: observedLabel,
               pageID: pageID,
               context: context
           ) {
            return roiCandidate
        }

        let fallbackBox: NormalizedRect
        if labelRule.category == .name,
           options.preset == .standard || options.preset == .strict {
            fallbackBox = likelyNameFillArea(toRightOf: observedLabel.boundingBox)
        } else if usesStandardPhoneExtraction(for: labelRule.category, options: options) {
            fallbackBox = phoneFallbackBox(
                toRightOf: observedLabel.boundingBox,
                labelRule: labelRule,
                labelItem: labelItem,
                textItems: textItems,
                excluding: [labelIndex]
            )
        } else {
            fallbackBox = likelyFillArea(toRightOf: observedLabel.boundingBox)
        }
        guard allowsLabelFallback(
            for: labelRule.category,
            fallbackBox: fallbackBox,
            options: options
        ),
              let fallbackValueState = fallbackRegionValueState(
                  category: labelRule.category,
                  labelRule: labelRule,
                  labelItem: labelItem,
                  labelBox: observedLabel.boundingBox,
                  fallbackBox: fallbackBox,
                  textItems: textItems,
                  excluding: [labelIndex],
                  context: context,
                  emitsEmptyField: shouldEmitEmptyLabelFallback(for: labelRule.category, options: options)
              ) else {
            return nil
        }

        return OCRSensitiveCandidate(
            pageID: pageID,
            text: L10n.Review.ocrNoExplicitValue,
            category: labelRule.category,
            valueState: fallbackValueState,
            sourceLabelText: sourceLabelText(
                observedLabel.title,
                for: labelRule.category,
                options: options
            ),
            confidence: labelItem.confidence,
            boundingBox: fallbackBox,
            labelBoundingBox: observedLabel.boundingBox,
            detectionKind: .labelFallback
        )
    }

    private static func staffSignatureCandidate(
        labelRule: OCRLabelRule,
        labelItem: OCRTextItem,
        labelIndex: Int,
        observedLabel: OCRObservedLabel,
        textItems: [OCRTextItem],
        pageID: PageItem.ID,
        options: OCRDetectionOptions,
        context: OCRProcessingContext
    ) -> OCRSensitiveCandidate? {
        let labelTitle = sourceLabelText(
            observedLabel.title,
            for: labelRule.category,
            options: options
        )

        if let valueRange = staffSignatureInlineValueRange(
            labelRule: labelRule,
            in: labelItem.text
        ),
           let valueBox = appNormalizedRect(
               for: valueRange,
               in: labelItem.recognizedText,
               text: labelItem.text,
               fallbackBounds: labelItem.boundingBox
           ) {
            let rawValue = (labelItem.text as NSString)
                .substring(with: valueRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return staffSignatureCandidate(
                rawValue: rawValue,
                valueBox: valueBox,
                confidence: labelItem.confidence,
                labelTitle: labelTitle,
                labelBox: observedLabel.boundingBox,
                pageID: pageID
            )
        }

        if let valueItem = nearestValueItem(
            for: observedLabel.boundingBox,
            category: .staffSignature,
            in: textItems,
            excluding: [labelIndex],
            mode: .sameLineRight
        ) {
            return staffSignatureCandidate(
                rawValue: valueItem.text,
                valueBox: valueItem.boundingBox,
                confidence: min(labelItem.confidence, valueItem.confidence),
                labelTitle: labelTitle,
                labelBox: observedLabel.boundingBox,
                pageID: pageID
            )
        }

        guard let fallback = staffSignatureFallbackAnalysis(
            toRightOf: observedLabel.boundingBox,
            labelRule: labelRule,
            labelItem: labelItem,
            textItems: textItems,
            excluding: [labelIndex],
            context: context,
            emitsEmptyField: shouldEmitEmptyLabelFallback(for: .staffSignature, options: options)
        ) else {
            return nil
        }
        guard allowsLabelFallback(
            for: .staffSignature,
            fallbackBox: fallback.boundingBox,
            options: options
        ) else {
            return nil
        }

        return OCRSensitiveCandidate(
            pageID: pageID,
            text: L10n.Review.ocrNoExplicitValue,
            category: .staffSignature,
            valueState: fallback.valueState,
            sourceLabelText: labelTitle,
            confidence: labelItem.confidence,
            boundingBox: fallback.boundingBox,
            labelBoundingBox: observedLabel.boundingBox,
            detectionKind: .labelFallback
        )
    }

    private static func staffSignatureCandidate(
        rawValue: String,
        valueBox: NormalizedRect,
        confidence: Double,
        labelTitle: String?,
        labelBox: NormalizedRect,
        pageID: PageItem.ID
    ) -> OCRSensitiveCandidate {
        guard let value = staffSignatureDisplayValue(from: rawValue) else {
            return OCRSensitiveCandidate(
                pageID: pageID,
                text: L10n.Review.ocrNoExplicitValue,
                category: .staffSignature,
                valueState: .unreadableContent,
                sourceLabelText: labelTitle,
                confidence: confidence,
                boundingBox: valueBox.padded(horizontal: 0.003, vertical: 0.004),
                labelBoundingBox: labelBox,
                detectionKind: .labelFallback
            )
        }

        let valueState = staffSignatureValueState(confidence: confidence)
        return OCRSensitiveCandidate(
            pageID: pageID,
            text: value,
            category: .staffSignature,
            valueState: valueState,
            sourceLabelText: labelTitle,
            confidence: confidence,
            boundingBox: valueBox.padded(horizontal: 0.003, vertical: 0.004),
            labelBoundingBox: labelBox,
            detectionKind: .labelValue
        )
    }

    private static func staffSignatureValueState(confidence: Double) -> OCRCandidateValueState {
        if confidence >= 0.80 {
            return .valueRecognized
        }

        return .valueUncertain
    }

    private struct StaffSignatureFallbackAnalysis {
        let valueState: OCRCandidateValueState
        let boundingBox: NormalizedRect
    }

    private static func staffSignatureFallbackAnalysis(
        toRightOf labelBox: NormalizedRect,
        labelRule: OCRLabelRule,
        labelItem: OCRTextItem,
        textItems: [OCRTextItem],
        excluding excludedIndexes: Set<Int>,
        context: OCRProcessingContext,
        emitsEmptyField: Bool
    ) -> StaffSignatureFallbackAnalysis? {
        let fallbackBox = staffSignatureFallbackBox(
            toRightOf: labelBox,
            labelRule: labelRule,
            labelItem: labelItem,
            textItems: textItems,
            excluding: excludedIndexes
        )

        let textEvidenceBoxes = textItems.enumerated().compactMap { index, item -> NormalizedRect? in
            guard !excludedIndexes.contains(index),
                  staffSignatureFallbackEvidenceBox(item.boundingBox, overlaps: fallbackBox),
                  valueRegionTextHasVisibleContent(item.text) else {
                return nil
            }

            return item.boundingBox
        }
        if let textEvidenceBox = textEvidenceBoxes.reduce(nil as NormalizedRect?, { partial, box -> NormalizedRect? in
            partial.map { unionRect($0, box) } ?? box
        }) {
            return StaffSignatureFallbackAnalysis(
                valueState: .unreadableContent,
                boundingBox: staffSignatureBox(
                    textEvidenceBox.padded(horizontal: 0.003, vertical: 0.004),
                    constrainedTo: fallbackBox
                )
            )
        }

        let emptyBox = conservativeStaffSignatureEmptyBox(toRightOf: labelBox, inside: fallbackBox)
        let imageContentProbeBoxes = [
            (box: fallbackBox, excludedBoxes: [labelBox]),
            (box: emptyBox, excludedBoxes: [labelBox]),
            (
                box: staffSignatureInkProbeArea(around: labelBox),
                excludedBoxes: [labelBox.padded(horizontal: 0.006, vertical: 0.006)]
            )
        ]
        if let sourceImage = context.sourceImage,
           let inkBox = imageContentProbeBoxes.compactMap({
               imageRegionMeaningfulInkBoundingBox(
                   sourceImage,
                   in: $0.box,
                   sensitivity: .handwriting,
                   excluding: $0.excludedBoxes
               )
           }).first {
            return StaffSignatureFallbackAnalysis(
                valueState: .unreadableContent,
                boundingBox: staffSignatureBox(
                    inkBox.padded(horizontal: 0.003, vertical: 0.004),
                    constrainedTo: staffSignatureInkProbeArea(around: labelBox)
                )
            )
        }

        if context.sourceImage != nil, labelItem.recognizedText != nil {
            return StaffSignatureFallbackAnalysis(
                valueState: .unreadableContent,
                boundingBox: emptyBox
            )
        }

        guard emitsEmptyField else {
            return nil
        }

        return StaffSignatureFallbackAnalysis(
            valueState: .emptyField,
            boundingBox: emptyBox
        )
    }

    private static func staffSignatureFallbackBox(
        toRightOf labelBox: NormalizedRect,
        labelRule _: OCRLabelRule,
        labelItem _: OCRTextItem,
        textItems: [OCRTextItem],
        excluding excludedIndexes: Set<Int>
    ) -> NormalizedRect {
        staffSignatureSearchArea(
            toRightOf: labelBox,
            textItems: textItems,
            excluding: excludedIndexes
        )
    }

    private static func staffSignatureInlineValueRange(
        labelRule: OCRLabelRule,
        in text: String
    ) -> NSRange? {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        for pattern in labelRule.labelPatterns.sorted(by: { $0.count > $1.count }) {
            let escapedPattern = NSRegularExpression.escapedPattern(for: pattern)
            let regex = try! NSRegularExpression(
                pattern: "\(escapedPattern)\\s*[:：;；.。｡﹕∶︰﹔]?\\s*([^\\s:：;；.。｡﹕∶︰﹔]{1,80})",
                options: [.caseInsensitive]
            )

            guard let match = regex.firstMatch(in: text, range: fullRange),
                  match.range(at: 1).location != NSNotFound,
                  match.range(at: 1).length > 0 else {
                continue
            }

            let valueRange = match.range(at: 1)
            guard valueRegionTextHasVisibleContent(nsText.substring(with: valueRange)) else {
                continue
            }

            return valueRange
        }

        let compact = normalizedOCRLabelText(text)
        if labelRule.labelPatterns.contains(where: { compact == normalizedOCRLabelText($0) }) {
            return nil
        }

        if let fuzzyMatch = fuzzyStaffSignatureLabelTextMatch(in: text),
           let valueRange = staffSignatureInlineValueRange(after: fuzzyMatch.range, in: text) {
            return valueRange
        }

        return nil
    }

    private static func staffSignatureInlineValueRange(
        after labelRange: NSRange,
        in text: String
    ) -> NSRange? {
        let nsText = text as NSString
        var location = min(max(0, rangeUpperBound(labelRange)), nsText.length)
        var upperBound = nsText.length
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ":：;；.。｡﹕∶︰﹔"))

        while location < upperBound,
              separators.contains(character(at: location, in: text)) {
            location += 1
        }

        while upperBound > location,
              separators.contains(character(at: upperBound - 1, in: text)) {
            upperBound -= 1
        }

        guard upperBound > location else {
            return nil
        }

        return NSRange(location: location, length: upperBound - location)
    }

    private static func birthdayFromNearbyIDValueCandidate(
        observedLabel: OCRObservedLabel,
        labelConfidence: Double,
        textItems: [OCRTextItem],
        excluding excludedIndexes: Set<Int>,
        pageID: PageItem.ID
    ) -> OCRSensitiveCandidate? {
        textItems
            .enumerated()
            .compactMap { index, item -> OCRSensitiveCandidate? in
                guard !excludedIndexes.contains(index),
                      let match = chineseIDMatch(in: item.text),
                      let idBounds = appNormalizedRect(
                          for: match.range,
                          in: item.recognizedText,
                          text: item.text,
                          fallbackBounds: item.boundingBox
                      ),
                      birthdayIDValueIsNear(labelBox: observedLabel.boundingBox, valueBox: idBounds) else {
                    return nil
                }

                let idText = match.value
                let birthStart = idText.index(idText.startIndex, offsetBy: 6)
                let birthEnd = idText.index(birthStart, offsetBy: 8)
                let birthDigits = String(idText[birthStart..<birthEnd])
                guard let birthdayText = normalizedDateValue(birthDigits) else {
                    return nil
                }

                let birthRange = NSRange(location: match.range.location + 6, length: 8)
                let birthBounds = appNormalizedRect(
                    for: birthRange,
                    in: item.recognizedText,
                    text: item.text,
                    fallbackBounds: item.boundingBox
                ) ?? idBounds

                return OCRSensitiveCandidate(
                    pageID: pageID,
                    text: birthdayText,
                    category: .birthday,
                    confidence: min(labelConfidence, item.confidence),
                    boundingBox: birthBounds.padded(horizontal: 0.003, vertical: 0.004),
                    labelBoundingBox: observedLabel.boundingBox,
                    detectionKind: .labelValue
                )
            }
            .sorted { left, right in
                fallbackMergeScore(value: left, fallback: OCRSensitiveCandidate(
                    pageID: pageID,
                    text: L10n.Review.ocrNoExplicitValue,
                    category: .birthday,
                    confidence: labelConfidence,
                    boundingBox: observedLabel.boundingBox,
                    labelBoundingBox: observedLabel.boundingBox,
                    detectionKind: .labelFallback
                )) < fallbackMergeScore(value: right, fallback: OCRSensitiveCandidate(
                    pageID: pageID,
                    text: L10n.Review.ocrNoExplicitValue,
                    category: .birthday,
                    confidence: labelConfidence,
                    boundingBox: observedLabel.boundingBox,
                    labelBoundingBox: observedLabel.boundingBox,
                    detectionKind: .labelFallback
                ))
            }
            .first
    }

    private static func inlineValueCandidate(
        labelRule: OCRLabelRule,
        labelItem: OCRTextItem,
        observedLabel: OCRObservedLabel,
        options: OCRDetectionOptions,
        pageID: PageItem.ID
    ) -> OCRSensitiveCandidate? {
        guard let valueRange = labelRule.inlineValueRange(
            in: labelItem.text,
            allowsNameWithSpaces: options.preset == .standard
        ),
              let bounds = appNormalizedRect(
                  for: valueRange,
                  in: labelItem.recognizedText,
                  text: labelItem.text,
                  fallbackBounds: labelItem.boundingBox
              ) else {
            return nil
        }

        let text = (labelItem.text as NSString)
            .substring(with: valueRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard isLikelyValue(text, for: labelRule.category) else {
            return nil
        }

        return OCRSensitiveCandidate(
            pageID: pageID,
            text: displayText(text, for: labelRule.category),
            category: labelRule.category,
            sourceLabelText: sourceLabelText(
                observedLabel.title,
                for: labelRule.category,
                options: options
            ),
            confidence: labelItem.confidence,
            boundingBox: bounds.padded(horizontal: 0.003, vertical: 0.004),
            labelBoundingBox: observedLabel.boundingBox,
            detectionKind: .labelValue
        )
    }

    private static func sourceLabelText(
        _ title: String,
        for category: OCRCandidateCategory,
        options: OCRDetectionOptions
    ) -> String? {
        if options.preset == .strict,
           category == .birthday || category == .examDate {
            return nil
        }

        return title
    }

    private static func usesStandardPhoneExtraction(
        for category: OCRCandidateCategory,
        options: OCRDetectionOptions
    ) -> Bool {
        category == .phone && (options.preset == .standard || options.preset == .strict)
    }

    private static func nearestValueItem(
        for labelItem: OCRTextItem,
        category: OCRCandidateCategory,
        in textItems: [OCRTextItem],
        mode: OCRValueSearchMode
    ) -> OCRTextItem? {
        let labelBox = labelItem.boundingBox

        return textItems
            .filter { item in
                guard item.text != labelItem.text,
                      isLikelyNeighborValue(item.text),
                      isLikelyValue(item.text, for: category),
                      item.boundingBox.width > 0.01,
                      item.boundingBox.height > 0.005 else {
                    return false
                }

                switch mode {
                case .sameLineRight:
                    let verticalCenterDelta = abs(item.boundingBox.centerY - labelBox.centerY)
                    let rightGap = item.boundingBox.x - labelBox.maxX

                    return rightGap >= -0.015
                        && rightGap <= 0.45
                        && verticalCenterDelta <= max(labelBox.height, item.boundingBox.height) * 0.75
                        && item.boundingBox.maxX <= min(labelBox.maxX + 0.62, 1)
                case .below:
                    let verticalGap = item.boundingBox.y - labelBox.maxY
                    let horizontalOverlap = min(item.boundingBox.maxX, labelBox.maxX + 0.50) - max(item.boundingBox.x, labelBox.x - 0.04)

                    return verticalGap >= -0.005
                        && verticalGap <= max(labelBox.height * 2.4, 0.08)
                        && horizontalOverlap > 0
                        && item.boundingBox.x <= min(labelBox.x + 0.45, 1)
                }
            }
            .sorted { left, right in
                valueDistance(from: labelBox, to: left.boundingBox, mode: mode)
                    < valueDistance(from: labelBox, to: right.boundingBox, mode: mode)
            }
            .first
    }

    private static func nearestValueItem(
        for labelBoxes: [NormalizedRect],
        category: OCRCandidateCategory,
        in textItems: [OCRTextItem],
        excluding excludedIndexes: Set<Int>,
        mode: OCRValueSearchMode
    ) -> OCRTextItem? {
        labelBoxes
            .compactMap { labelBox -> (item: OCRTextItem, score: Double)? in
                guard let item = nearestValueItem(
                    for: labelBox,
                    category: category,
                    in: textItems,
                    excluding: excludedIndexes,
                    mode: mode
                ) else {
                    return nil
                }

                return (item, valueDistance(from: labelBox, to: item.boundingBox, mode: mode))
            }
            .sorted { left, right in
                left.score < right.score
            }
            .first?
            .item
    }

    private static func nearestValueItem(
        for labelBox: NormalizedRect,
        category: OCRCandidateCategory,
        in textItems: [OCRTextItem],
        excluding excludedIndexes: Set<Int>,
        mode: OCRValueSearchMode
    ) -> OCRTextItem? {
        textItems
            .enumerated()
            .filter { index, item in
                guard !excludedIndexes.contains(index),
                      isLikelyNeighborValue(item.text),
                      isLikelyValue(item.text, for: category),
                      item.boundingBox.width > 0.01,
                      item.boundingBox.height > 0.005 else {
                    return false
                }

                switch mode {
                case .sameLineRight:
                    let verticalCenterDelta = abs(item.boundingBox.centerY - labelBox.centerY)
                    let rightGap = item.boundingBox.x - labelBox.maxX

                    return rightGap >= -0.015
                        && rightGap <= 0.45
                        && verticalCenterDelta <= max(labelBox.height, item.boundingBox.height) * 0.75
                        && item.boundingBox.maxX <= min(labelBox.maxX + 0.62, 1)
                case .below:
                    let verticalGap = item.boundingBox.y - labelBox.maxY
                    let horizontalOverlap = min(item.boundingBox.maxX, labelBox.maxX + 0.50) - max(item.boundingBox.x, labelBox.x - 0.04)

                    return verticalGap >= -0.005
                        && verticalGap <= max(labelBox.height * 2.4, 0.08)
                        && horizontalOverlap > 0
                        && item.boundingBox.x <= min(labelBox.x + 0.45, 1)
                }
            }
            .sorted { left, right in
                valueDistance(from: labelBox, to: left.element.boundingBox, mode: mode)
                    < valueDistance(from: labelBox, to: right.element.boundingBox, mode: mode)
            }
            .first?
            .element
    }

    private static func likelyFillArea(toRightOf labelBox: NormalizedRect) -> NormalizedRect {
        let gap = 0.015
        let x = min(labelBox.maxX + gap, 0.94)
        let width = min(max(0.18, labelBox.width * 2.2), 0.50, 0.98 - x)
        let height = min(max(labelBox.height * 1.35, 0.028), 0.06)
        let y = max(labelBox.centerY - height / 2, 0)

        return NormalizedRect(
            x: x,
            y: y,
            width: width,
            height: height
        )
        .clamped()
    }

    private static func likelyPhoneFillArea(toRightOf labelBox: NormalizedRect) -> NormalizedRect {
        let gap = 0.014
        let x = min(labelBox.maxX + gap, 0.94)
        let width = min(max(0.24, labelBox.width * 3.2), 0.44, 0.98 - x)
        let height = min(max(labelBox.height * 1.05, 0.018), 0.034)
        let y = max(labelBox.centerY - height / 2, 0)

        return NormalizedRect(
            x: x,
            y: y,
            width: width,
            height: height
        )
        .clamped()
    }

    private static func phoneValueCandidateText(_ text: String) -> Bool {
        let digitCount = text.filter(\.isNumber).count
        return digitCount > 0 && digitCount <= 18
    }

    private static func phoneValueBox(
        _ valueBox: NormalizedRect,
        isSameRowRightOf labelBox: NormalizedRect
    ) -> Bool {
        let verticalCenterDelta = abs(valueBox.centerY - labelBox.centerY)
        let rightGap = valueBox.x - labelBox.maxX

        return rightGap >= -0.015
            && rightGap <= 0.52
            && verticalCenterDelta <= max(labelBox.height, valueBox.height) * 0.90
            && valueBox.maxX <= min(labelBox.maxX + 0.68, 1)
    }

    private static func likelyNameFillArea(toRightOf labelBox: NormalizedRect) -> NormalizedRect {
        let gap = 0.015
        let x = min(labelBox.maxX + gap, 0.94)
        let width = min(max(0.22, labelBox.width * 2.8), 0.56, 0.98 - x)
        let height = min(max(labelBox.height * 1.45, 0.032), 0.07)
        let y = max(labelBox.centerY - height / 2, 0)

        return NormalizedRect(
            x: x,
            y: y,
            width: width,
            height: height
        )
        .clamped()
    }

    private static func likelyStaffSignatureFillArea(toRightOf labelBox: NormalizedRect) -> NormalizedRect {
        let rowHeight = max(labelBox.height, 0.014)
        let gap = max(0.008, rowHeight * 0.45)
        let x = min(labelBox.maxX + gap, 0.94)
        let width = min(max(0.20, labelBox.width * 3.0), 0.34, 0.98 - x)
        let above = min(max(rowHeight * 2.8, 0.036), 0.058)
        let below = min(max(rowHeight * 1.8, 0.026), 0.044)
        let y = max(labelBox.centerY - above, 0)
        let maxY = min(labelBox.centerY + below, 1)

        return NormalizedRect(
            x: x,
            y: y,
            width: width,
            height: max(0, maxY - y)
        )
        .clamped()
    }

    private static func staffSignatureInkProbeArea(around labelBox: NormalizedRect) -> NormalizedRect {
        let rowHeight = max(labelBox.height, 0.014)
        let x = max(labelBox.maxX - max(rowHeight * 1.30, 0.018), 0)
        let maxX = min(labelBox.maxX + min(max(0.28, labelBox.width * 9.0), 0.38), 0.98)
        let above = min(max(rowHeight * 3.4, 0.048), 0.074)
        let below = min(max(rowHeight * 5.2, 0.084), 0.110)
        let y = max(labelBox.centerY - above, 0)
        let lowerY = min(labelBox.centerY + below, 1)

        return NormalizedRect(
            x: x,
            y: y,
            width: max(0, maxX - x),
            height: max(0, lowerY - y)
        )
        .clamped()
    }

    private static func staffSignatureSearchArea(
        toRightOf labelBox: NormalizedRect,
        textItems: [OCRTextItem],
        excluding excludedIndexes: Set<Int>
    ) -> NormalizedRect {
        let baseArea = likelyStaffSignatureFillArea(toRightOf: labelBox)
        let rowHeight = max(labelBox.height, 0.014)
        let boundaryGap = max(rowHeight * 0.18, 0.003)
        let boundaryBoxes = textItems.enumerated().compactMap { index, item -> NormalizedRect? in
            guard !excludedIndexes.contains(index),
                  staffSignatureBoundaryRowBox(item.boundingBox, near: labelBox) else {
                return nil
            }

            return item.boundingBox
        }

        let previousBoundary = boundaryBoxes
            .filter { $0.centerY < labelBox.centerY - rowHeight * 0.75 }
            .max { $0.centerY < $1.centerY }
        let nextBoundary = boundaryBoxes
            .filter { $0.centerY > labelBox.centerY + rowHeight * 0.75 }
            .min { $0.centerY < $1.centerY }

        let minY = max(baseArea.y, previousBoundary.map { $0.maxY + boundaryGap } ?? 0)
        let maxY = min(baseArea.maxY, nextBoundary.map { $0.y - boundaryGap } ?? 1)
        guard maxY > minY else {
            return conservativeStaffSignatureEmptyBox(toRightOf: labelBox, inside: baseArea)
        }

        return NormalizedRect(
            x: baseArea.x,
            y: minY,
            width: baseArea.width,
            height: maxY - minY
        )
        .clamped()
    }

    private static func staffSignatureBoundaryRowBox(
        _ rowBox: NormalizedRect,
        near labelBox: NormalizedRect
    ) -> Bool {
        let horizontalBoundaryBand = labelBox.maxX + max(labelBox.width * 0.80, 0.035)
        let nearLabelColumn = rowBox.x <= horizontalBoundaryBand
            || rowBox.centerX <= labelBox.centerX + max(labelBox.width * 1.8, 0.090)
        let localVerticalDistance = abs(rowBox.centerY - labelBox.centerY) <= 0.16
        let overlapsLabel = normalizedRectIntersectionArea(rowBox, labelBox) > 0

        return nearLabelColumn
            && localVerticalDistance
            && !overlapsLabel
            && !staffSignatureValueBox(rowBox, isSameRowRightOf: labelBox)
    }

    private static func staffSignatureValueBox(
        _ valueBox: NormalizedRect,
        isSameRowRightOf labelBox: NormalizedRect
    ) -> Bool {
        let searchRegion = likelyStaffSignatureFillArea(toRightOf: labelBox)
        let intersectionArea = normalizedRectIntersectionArea(valueBox, searchRegion)
        let valueArea = valueBox.width * valueBox.height
        let regionArea = searchRegion.width * searchRegion.height
        let overlapsSearchRegion = valueArea > 0 && intersectionArea / valueArea >= 0.18
            || regionArea > 0 && intersectionArea / regionArea >= 0.015
        let rightGap = valueBox.x - labelBox.maxX

        return rightGap >= -0.012
            && rightGap <= 0.38
            && valueBox.maxX <= min(searchRegion.maxX + 0.018, 1)
            && overlapsSearchRegion
    }

    private static func staffSignatureFallbackEvidenceBox(
        _ valueBox: NormalizedRect,
        overlaps fallbackBox: NormalizedRect
    ) -> Bool {
        let intersectionArea = normalizedRectIntersectionArea(valueBox, fallbackBox)
        let valueArea = valueBox.width * valueBox.height
        let fallbackArea = fallbackBox.width * fallbackBox.height

        return valueArea > 0 && intersectionArea / valueArea >= 0.28
            || fallbackArea > 0 && intersectionArea / fallbackArea >= 0.040
    }

    private static func staffSignatureBox(
        _ candidateBox: NormalizedRect,
        constrainedTo fallbackBox: NormalizedRect
    ) -> NormalizedRect {
        normalizedRectIntersection(candidateBox, fallbackBox.padded(horizontal: 0.006, vertical: 0.006))
            ?? candidateBox
    }

    private static func conservativeStaffSignatureEmptyBox(
        toRightOf labelBox: NormalizedRect,
        inside fallbackBox: NormalizedRect
    ) -> NormalizedRect {
        let rowHeight = max(labelBox.height, 0.014)
        let height = min(max(rowHeight * 1.45, 0.024), fallbackBox.height)
        let centeredY = labelBox.centerY - height / 2
        let y = min(max(centeredY, fallbackBox.y), max(fallbackBox.y, fallbackBox.maxY - height))
        let width = min(max(labelBox.width * 2.4, 0.16), fallbackBox.width, 0.28)

        return NormalizedRect(
            x: fallbackBox.x,
            y: y,
            width: width,
            height: height
        )
        .clamped()
    }

    private static func fallbackRegionHasVisibleContent(
        category: OCRCandidateCategory,
        labelRule: OCRLabelRule?,
        labelItem: OCRTextItem?,
        labelBox: NormalizedRect,
        fallbackBox: NormalizedRect,
        textItems: [OCRTextItem],
        excluding excludedIndexes: Set<Int>,
        context: OCRProcessingContext
    ) -> Bool {
        fallbackRegionValueState(
            category: category,
            labelRule: labelRule,
            labelItem: labelItem,
            labelBox: labelBox,
            fallbackBox: fallbackBox,
            textItems: textItems,
            excluding: excludedIndexes,
            context: context,
            emitsEmptyField: false
        ) == .unreadableContent
    }

    private static func fallbackRegionValueState(
        category: OCRCandidateCategory,
        labelRule: OCRLabelRule?,
        labelItem: OCRTextItem?,
        labelBox: NormalizedRect,
        fallbackBox: NormalizedRect,
        textItems: [OCRTextItem],
        excluding excludedIndexes: Set<Int>,
        context: OCRProcessingContext,
        emitsEmptyField: Bool
    ) -> OCRCandidateValueState? {
        if let labelRule,
           let labelItem,
           let inlineValueRange = labelRule.inlineValueRange(
               in: labelItem.text,
               allowsNameWithSpaces: category == .name
           ) {
            let inlineValue = (labelItem.text as NSString)
                .substring(with: inlineValueRange)
            if valueRegionTextIsPlausibleFallbackEvidence(
                inlineValue,
                for: category,
                confidence: labelItem.confidence
            ) || fallbackRegionAcceptsAnyVisibleText(category, emitsEmptyField: emitsEmptyField)
                && valueRegionTextHasVisibleContent(inlineValue) {
                return .unreadableContent
            }
        }

        let textEvidence = textItems.enumerated().contains { index, item in
            guard !excludedIndexes.contains(index),
                  valueEvidenceBox(item.boundingBox, overlaps: fallbackBox, labelBox: labelBox) else {
                return false
            }

            return valueRegionTextIsPlausibleFallbackEvidence(
                item.text,
                for: category,
                confidence: item.confidence
            ) || fallbackRegionAcceptsAnyVisibleText(category, emitsEmptyField: emitsEmptyField)
                && valueRegionTextHasVisibleContent(item.text)
        }
        if textEvidence {
            return .unreadableContent
        }

        if categoryAllowsImageOnlyFallbackContent(category),
           let sourceImage = context.sourceImage,
           let inkBox = imageRegionMeaningfulInkBoundingBox(
               sourceImage,
               in: fallbackBox,
               sensitivity: imageInkDetectionSensitivity(for: category)
           ),
           imageOnlyFallbackInkBoxIsMeaningful(inkBox, in: fallbackBox, for: category) {
            return .unreadableContent
        }

        return emitsEmptyField ? .emptyField : nil
    }

    private static func fallbackRegionAcceptsAnyVisibleText(
        _ category: OCRCandidateCategory,
        emitsEmptyField: Bool
    ) -> Bool {
        emitsEmptyField && category == .staffSignature
    }

    private static func shouldEmitEmptyLabelFallback(
        for category: OCRCandidateCategory,
        options: OCRDetectionOptions
    ) -> Bool {
        guard options.includedCategories.contains(category) else {
            return false
        }

        switch options.preset {
        case .strict, .custom:
            return category == .email
                || category == .phone
                || category == .staffSignature
        case .standard:
            return false
        }
    }

    private static func categoryAllowsImageOnlyFallbackContent(_ category: OCRCandidateCategory) -> Bool {
        category == .name
            || category == .staffSignature
            || category == .email
    }

    private static func valueRegionTextHasVisibleContent(_ text: String) -> Bool {
        let normalized = normalizedOCRValueText(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              !isKnownLabelOnlyText(normalized) else {
            return false
        }

        let nonContentCharacters = CharacterSet(
            charactersIn: "_-—–－=:：;；,.。/\\|·• 　一　"
        )
        if normalized.unicodeScalars.allSatisfy({
            nonContentCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
        }) {
            return false
        }

        return true
    }

    private static func valueRegionTextIsPlausibleFallbackEvidence(
        _ text: String,
        for category: OCRCandidateCategory,
        confidence: Double?
    ) -> Bool {
        guard valueRegionTextHasVisibleContent(text) else {
            return false
        }

        switch category {
        case .email:
            let normalized = normalizedOCRValueText(text).lowercased()
            return normalized.contains("@")
                || normalized.range(of: #"(?i)[a-z0-9._%+\-]{2,}\.[a-z0-9□]{1,}"#, options: .regularExpression) != nil
        case .phone, .fax:
            return !text.filter(\.isNumber).isEmpty
        default:
            return true
        }
    }

    private static func valueEvidenceBox(
        _ valueBox: NormalizedRect,
        overlaps fallbackBox: NormalizedRect,
        labelBox: NormalizedRect
    ) -> Bool {
        let intersectionArea = normalizedRectIntersectionArea(valueBox, fallbackBox)
        let valueArea = valueBox.width * valueBox.height
        let fallbackArea = fallbackBox.width * fallbackBox.height
        let overlapsFallback = valueArea > 0 && intersectionArea / valueArea >= 0.18
            || fallbackArea > 0 && intersectionArea / fallbackArea >= 0.015
        if overlapsFallback {
            return true
        }

        let verticalCenterDelta = abs(valueBox.centerY - labelBox.centerY)
        let rightGap = valueBox.x - labelBox.maxX
        return rightGap >= -0.012
            && rightGap <= 0.58
            && verticalCenterDelta <= max(valueBox.height, labelBox.height) * 1.20
    }

    private enum ImageInkDetectionSensitivity {
        case standard
        case handwriting

        var lumaThreshold: Double {
            switch self {
            case .standard:
                return 185
            case .handwriting:
                return 220
            }
        }

        var coloredLumaThreshold: Double {
            switch self {
            case .standard:
                return 220
            case .handwriting:
                return 235
            }
        }

        var colorDeltaThreshold: Double {
            switch self {
            case .standard:
                return 38
            case .handwriting:
                return 22
            }
        }

        func minimumDarkPixels(totalPixels: Int) -> Int {
            switch self {
            case .standard:
                return max(12, totalPixels / 900)
            case .handwriting:
                return max(8, totalPixels / 1500)
            }
        }

        func minimumActiveRows(height: Int) -> Int {
            switch self {
            case .standard:
                return min(10, max(4, height / 16))
            case .handwriting:
                return min(8, max(3, height / 24))
            }
        }

        func minimumActiveColumns(width: Int) -> Int {
            switch self {
            case .standard:
                return min(10, max(3, width / 80))
            case .handwriting:
                return min(8, max(3, width / 120))
            }
        }
    }

    private static func imageInkDetectionSensitivity(
        for category: OCRCandidateCategory
    ) -> ImageInkDetectionSensitivity {
        switch category {
        case .staffSignature:
            return .handwriting
        default:
            return .standard
        }
    }

    private static func imageOnlyFallbackInkBoxIsMeaningful(
        _ inkBox: NormalizedRect,
        in fallbackBox: NormalizedRect,
        for category: OCRCandidateCategory
    ) -> Bool {
        switch category {
        case .email:
            return inkBox.width >= 0.018
                && inkBox.height >= max(fallbackBox.height * 0.35, 0.008)
                && inkBox.width <= fallbackBox.width * 0.82
        default:
            return true
        }
    }

    private static func imageRegionContainsMeaningfulInk(
        _ sourceImage: CGImage,
        in normalizedRect: NormalizedRect,
        sensitivity: ImageInkDetectionSensitivity = .standard
    ) -> Bool {
        imageRegionMeaningfulInkBoundingBox(
            sourceImage,
            in: normalizedRect,
            sensitivity: sensitivity
        ) != nil
    }

    private static func imageRegionMeaningfulInkBoundingBox(
        _ sourceImage: CGImage,
        in normalizedRect: NormalizedRect,
        sensitivity: ImageInkDetectionSensitivity = .standard,
        excluding excludedRects: [NormalizedRect] = []
    ) -> NormalizedRect? {
        guard let croppedImage = croppedImage(sourceImage, to: normalizedRect) else {
            return nil
        }

        let maxScanWidth = 640
        let maxScanHeight = 240
        let scale = min(
            1.0,
            Double(maxScanWidth) / Double(max(croppedImage.width, 1)),
            Double(maxScanHeight) / Double(max(croppedImage.height, 1))
        )
        let width = max(2, Int(Double(croppedImage.width) * scale))
        let height = max(2, Int(Double(croppedImage.height) * scale))
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 255, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        let drewImage = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }

            context.interpolationQuality = .none
            context.draw(croppedImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drewImage else {
            return nil
        }

        var darkMap = [Bool](repeating: false, count: width * height)
        var rowCounts = [Int](repeating: 0, count: height)
        var columnCounts = [Int](repeating: 0, count: width)
        for y in 0..<height {
            for x in 0..<width {
                if imageRegionPixel(
                    x: x,
                    y: y,
                    width: width,
                    height: height,
                    in: normalizedRect,
                    intersectsAny: excludedRects
                ) {
                    continue
                }

                let offset = y * bytesPerRow + x * bytesPerPixel
                let red = Double(pixels[offset])
                let green = Double(pixels[offset + 1])
                let blue = Double(pixels[offset + 2])
                let alpha = Double(pixels[offset + 3]) / 255.0
                let luma = 0.299 * red + 0.587 * green + 0.114 * blue
                let colorDelta = max(red, green, blue) - min(red, green, blue)
                let visibleInk = luma < sensitivity.lumaThreshold
                    || luma < sensitivity.coloredLumaThreshold
                    && colorDelta >= sensitivity.colorDeltaThreshold
                guard alpha > 0.12, visibleInk else {
                    continue
                }

                darkMap[y * width + x] = true
                rowCounts[y] += 1
                columnCounts[x] += 1
            }
        }

        var rowLongestRuns = [Int](repeating: 0, count: height)
        for y in 0..<height {
            var currentRun = 0
            for x in 0..<width {
                if darkMap[y * width + x] {
                    currentRun += 1
                    rowLongestRuns[y] = max(rowLongestRuns[y], currentRun)
                } else {
                    currentRun = 0
                }
            }
        }

        var columnLongestRuns = [Int](repeating: 0, count: width)
        for x in 0..<width {
            var currentRun = 0
            for y in 0..<height {
                if darkMap[y * width + x] {
                    currentRun += 1
                    columnLongestRuns[x] = max(columnLongestRuns[x], currentRun)
                } else {
                    currentRun = 0
                }
            }
        }

        let horizontalRunThreshold = max(10, Int(Double(width) * 0.55))
        let horizontalCountThreshold = max(16, Int(Double(width) * 0.72))
        let verticalRunThreshold = max(10, Int(Double(height) * 0.55))
        let verticalCountThreshold = max(16, Int(Double(height) * 0.72))
        let horizontalLineRows = zip(rowCounts, rowLongestRuns).map { rowCount, longestRun in
            longestRun >= horizontalRunThreshold || rowCount >= horizontalCountThreshold
        }
        let verticalLineColumns = zip(columnCounts, columnLongestRuns).map { columnCount, longestRun in
            longestRun >= verticalRunThreshold || columnCount >= verticalCountThreshold
        }
        var cleanedDarkPixels = 0
        var activeRows = [Bool](repeating: false, count: height)
        var activeColumns = [Bool](repeating: false, count: width)
        var minInkX = width
        var minInkY = height
        var maxInkX = -1
        var maxInkY = -1

        for y in 0..<height where !horizontalLineRows[y] {
            for x in 0..<width where !verticalLineColumns[x] {
                guard darkMap[y * width + x] else {
                    continue
                }

                cleanedDarkPixels += 1
                activeRows[y] = true
                activeColumns[x] = true
                minInkX = min(minInkX, x)
                minInkY = min(minInkY, y)
                maxInkX = max(maxInkX, x)
                maxInkY = max(maxInkY, y)
            }
        }

        let totalPixels = width * height
        let minimumDarkPixels = sensitivity.minimumDarkPixels(totalPixels: totalPixels)
        let minimumActiveRows = sensitivity.minimumActiveRows(height: height)
        let minimumActiveColumns = sensitivity.minimumActiveColumns(width: width)

        guard cleanedDarkPixels >= minimumDarkPixels,
              activeRows.filter(\.self).count >= minimumActiveRows,
              activeColumns.filter(\.self).count >= minimumActiveColumns,
              minInkX <= maxInkX,
              minInkY <= maxInkY else {
            return nil
        }

        let paddingX = max(2.0, Double(width) * 0.010)
        let paddingY = max(2.0, Double(height) * 0.012)
        let localX = max((Double(minInkX) - paddingX) / Double(width), 0)
        let localY = max((Double(minInkY) - paddingY) / Double(height), 0)
        let localMaxX = min((Double(maxInkX + 1) + paddingX) / Double(width), 1)
        let localMaxY = min((Double(maxInkY + 1) + paddingY) / Double(height), 1)

        return pageRect(
            from: NormalizedRect(
                x: localX,
                y: localY,
                width: max(0, localMaxX - localX),
                height: max(0, localMaxY - localY)
            ),
            in: normalizedRect
        )
    }

    private static func imageRegionPixel(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        in normalizedRect: NormalizedRect,
        intersectsAny excludedRects: [NormalizedRect]
    ) -> Bool {
        guard !excludedRects.isEmpty, width > 0, height > 0 else {
            return false
        }

        let pageX = normalizedRect.x + (Double(x) + 0.5) / Double(width) * normalizedRect.width
        let pageY = normalizedRect.y + (Double(y) + 0.5) / Double(height) * normalizedRect.height

        return excludedRects.contains { excludedRect in
            pageX >= excludedRect.x
                && pageX <= excludedRect.maxX
                && pageY >= excludedRect.y
                && pageY <= excludedRect.maxY
        }
    }

    private static func likelySplitNameFillArea(for group: OCRSplitNameLabelGroup) -> NormalizedRect {
        let labelBoxes = [group.surnameBoundingBox, group.givenNameBoundingBox].compactMap(\.self)
        let labelBox = group.labelBoundingBox
        let rightEdge = labelBoxes.map(\.maxX).max() ?? labelBox.maxX
        let rowHeight = labelBoxes.map(\.height).max() ?? labelBox.height
        let hasGivenNameRow = group.givenNameBoundingBox != nil
        let gap = 0.015
        let x = min(rightEdge + gap, 0.94)
        let width = min(max(0.24, labelBox.width * 2.8), 0.58, 0.98 - x)
        let y = max(labelBox.y - max(rowHeight * 0.35, 0.006), 0)
        let height = hasGivenNameRow
            ? min(max(labelBox.height + rowHeight * 0.70, 0.036), 0.16, 1 - y)
            : min(max(rowHeight * 4.6, 0.085), 0.12, 1 - y)

        return NormalizedRect(
            x: x,
            y: y,
            width: width,
            height: height
        )
        .clamped()
    }

    private static func splitNameGivenNameRowLabelBox(
        for group: OCRSplitNameLabelGroup,
        textItems: [OCRTextItem]
    ) -> NormalizedRect? {
        if let givenNameBoundingBox = group.givenNameBoundingBox {
            return givenNameBoundingBox
        }

        let surnameBox = group.surnameBoundingBox
        let rowHeight = max(surnameBox.height, 0.018)

        if let recognizedGivenLabel = textItems
            .filter({ item in
                guard item.boundingBox.y > surnameBox.y + rowHeight * 0.45,
                      item.boundingBox.y - surnameBox.y <= max(rowHeight * 4.2, 0.075),
                      abs(item.boundingBox.centerX - surnameBox.centerX) <= max(surnameBox.width * 2.0, 0.075),
                      !isStandardForbiddenNameLabelText(item.text) else {
                    return false
                }

                return splitNameLabelMatch(for: item)?.part == .givenName
                    || splitNameFuzzyGivenNameLabelMatch(item.text)
            })
            .sorted(by: { $0.boundingBox.y < $1.boundingBox.y })
            .first {
            return recognizedGivenLabel.boundingBox
        }

        let rowStep = min(max(rowHeight * 1.35, 0.014), 0.040)
        let inferredY = surnameBox.y + rowStep
        guard inferredY - surnameBox.y <= max(rowHeight * 4.0, 0.075),
              inferredY < 1 else {
            return nil
        }

        return NormalizedRect(
            x: surnameBox.x,
            y: inferredY,
            width: surnameBox.width,
            height: surnameBox.height
        )
        .clamped()
    }

    private static func splitNameFuzzyGivenNameLabelMatch(_ text: String) -> Bool {
        let normalized = normalizedSplitNameLabelText(text)
        guard normalized == "名" else {
            return false
        }

        return !isForbiddenNameLabelText(text)
    }

    private static func splitNameROIValueCandidate(
        _ group: OCRSplitNameLabelGroup,
        textItems: [OCRTextItem],
        pageID: PageItem.ID,
        context: OCRProcessingContext
    ) -> OCRSensitiveCandidate? {
        guard let sourceImage = context.sourceImage else {
            return nil
        }

        guard let surname = splitNameRowOCRComponentValue(
            for: .surname,
            labelBox: group.surnameBoundingBox,
            sourceImage: sourceImage
        ) else {
            return nil
        }

        guard let givenNameLabelBox = splitNameGivenNameRowLabelBox(
            for: group,
            textItems: textItems
        ) else {
            return nil
        }

        guard let givenName = splitNameRowOCRComponentValue(
            for: .givenName,
            labelBox: givenNameLabelBox,
            sourceImage: sourceImage
        ) else {
            return nil
        }

        return combinedSplitNameComponentCandidate(
            from: [surname, givenName],
            group: group,
            pageID: pageID
        )
    }

    private static func splitNameFallbackROIValueCandidate(
        _ group: OCRSplitNameLabelGroup,
        textItems: [OCRTextItem],
        pageID: PageItem.ID,
        context: OCRProcessingContext
    ) -> OCRSensitiveCandidate? {
        guard let sourceImage = context.sourceImage else {
            return nil
        }

        let fillArea = likelySplitNameFillArea(for: group)
        guard let croppedImage = croppedImage(sourceImage, to: fillArea) else {
            return nil
        }

        if let candidate = splitNameFallbackROIValueCandidate(
            in: croppedImage,
            fillArea: fillArea,
            group: group,
            textItems: textItems,
            pageID: pageID
        ) {
            return candidate
        }

        guard let scaledImage = scaledImage(croppedImage, scale: 3) else {
            return nil
        }

        return splitNameFallbackROIValueCandidate(
            in: scaledImage,
            fillArea: fillArea,
            group: group,
            textItems: textItems,
            pageID: pageID
        )
    }

    private static func splitNameFallbackROIValueCandidate(
        in fillImage: CGImage,
        fillArea: NormalizedRect,
        group: OCRSplitNameLabelGroup,
        textItems: [OCRTextItem],
        pageID: PageItem.ID
    ) -> OCRSensitiveCandidate? {
        guard let observations = try? recognizedTextObservations(in: fillImage) else {
            return nil
        }

        let roiItems = recognizedTextItems(from: observations, minimumConfidence: 0.08)
            .map { item in
                OCRTextItem(
                    text: item.text,
                    recognizedText: nil,
                    boundingBox: pageRect(from: item.boundingBox, in: fillArea),
                    confidence: item.confidence
                )
            }

        guard !roiItems.isEmpty else {
            return nil
        }

        let surnameCandidates = roiItems
            .compactMap { item -> OCRSplitNameComponentValue? in
                splitNameROIComponentValue(
                    item,
                    part: .surname,
                    referenceLabelBox: group.surnameBoundingBox
                )
            }
            .filter { component in
                splitNameComponentValueIsInLooseRowBand(
                    component.boundingBox,
                    labelBox: group.surnameBoundingBox
                )
            }
            .sorted { left, right in
                valueDistance(from: group.surnameBoundingBox, to: left.boundingBox, mode: .sameLineRight)
                    < valueDistance(from: group.surnameBoundingBox, to: right.boundingBox, mode: .sameLineRight)
            }

        guard let surname = surnameCandidates.first else {
            return nil
        }

        let givenLabelBox = splitNameGivenNameRowLabelBox(for: group, textItems: textItems)
        let givenCandidates = roiItems
            .compactMap { item -> OCRSplitNameComponentValue? in
                splitNameROIComponentValue(
                    item,
                    part: .givenName,
                    referenceLabelBox: givenLabelBox ?? group.surnameBoundingBox
                )
            }
            .filter { component in
                guard !candidateBoxesReferToSameLocation(component.boundingBox, surname.boundingBox) else {
                    return false
                }

                if let givenLabelBox {
                    return splitNameComponentValueIsInLooseRowBand(
                        component.boundingBox,
                        labelBox: givenLabelBox
                    )
                }

                let rowHeight = max(group.surnameBoundingBox.height, component.boundingBox.height)
                let verticalGap = component.boundingBox.y - group.surnameBoundingBox.y
                let rightGap = component.boundingBox.x - group.surnameBoundingBox.maxX

                return verticalGap >= rowHeight * 0.55
                    && verticalGap <= max(rowHeight * 4.2, 0.080)
                    && rightGap >= -0.015
                    && rightGap <= 0.38
            }
            .sorted { left, right in
                if let givenLabelBox {
                    return valueDistance(from: givenLabelBox, to: left.boundingBox, mode: .sameLineRight)
                        < valueDistance(from: givenLabelBox, to: right.boundingBox, mode: .sameLineRight)
                }

                if abs(left.boundingBox.y - right.boundingBox.y) > max(left.boundingBox.height, right.boundingBox.height) {
                    return left.boundingBox.y < right.boundingBox.y
                }

                return left.boundingBox.x < right.boundingBox.x
            }

        guard let givenName = givenCandidates.first else {
            return nil
        }

        return combinedSplitNameComponentCandidate(
            from: [surname, givenName],
            group: group,
            pageID: pageID
        )
    }

    private static func splitNameROIComponentValue(
        _ item: OCRTextItem,
        part: OCRSplitNameLabelPart,
        referenceLabelBox: NormalizedRect
    ) -> OCRSplitNameComponentValue? {
        guard let component = likelySplitNamePartComponent(from: item.text, for: part)
            ?? likelyEmbeddedSplitNamePartComponent(from: item.text, for: part),
              item.boundingBox.width > 0.005,
              item.boundingBox.height > 0.005,
              item.boundingBox.centerY < referenceLabelBox.centerY + max(referenceLabelBox.height * 4.5, 0.090) else {
            return nil
        }

        return OCRSplitNameComponentValue(
            part: part,
            text: component,
            boundingBox: item.boundingBox,
            confidence: item.confidence,
            sourceIndex: nil
        )
    }

    private static func splitNameRowOCRComponentValue(
        for part: OCRSplitNameLabelPart,
        labelBox: NormalizedRect,
        sourceImage: CGImage
    ) -> OCRSplitNameComponentValue? {
        let rowBox = splitNameRowOCRRegion(toRightOf: labelBox)
        guard let croppedImage = croppedImage(sourceImage, to: rowBox) else {
            return nil
        }

        if let value = splitNameRowOCRComponentValue(
            for: part,
            in: croppedImage,
            rowBox: rowBox,
            labelBox: labelBox
        ) {
            return value
        }

        guard let scaledImage = scaledImage(croppedImage, scale: 3) else {
            return nil
        }

        return splitNameRowOCRComponentValue(
            for: part,
            in: scaledImage,
            rowBox: rowBox,
            labelBox: labelBox
        )
    }

    private static func splitNameRowOCRComponentValue(
        for part: OCRSplitNameLabelPart,
        in rowImage: CGImage,
        rowBox: NormalizedRect,
        labelBox: NormalizedRect
    ) -> OCRSplitNameComponentValue? {
        guard let observations = try? recognizedTextObservations(in: rowImage) else {
            return nil
        }

        let rowItems = recognizedTextItems(from: observations, minimumConfidence: 0.08)
            .map { item in
                OCRTextItem(
                    text: item.text,
                    recognizedText: nil,
                    boundingBox: pageRect(from: item.boundingBox, in: rowBox),
                    confidence: item.confidence
                )
            }

        return rowItems
            .compactMap { item -> OCRSplitNameComponentValue? in
                guard let component = likelySplitNamePartComponent(from: item.text, for: part)
                    ?? likelyEmbeddedSplitNamePartComponent(from: item.text, for: part),
                      item.boundingBox.width > 0.005,
                      item.boundingBox.height > 0.005,
                      splitNameComponentValueIsInLooseRowBand(
                          item.boundingBox,
                          labelBox: labelBox
                      ) else {
                    return nil
                }

                return OCRSplitNameComponentValue(
                    part: part,
                    text: component,
                    boundingBox: item.boundingBox,
                    confidence: item.confidence,
                    sourceIndex: nil
                )
            }
            .sorted { left, right in
                valueDistance(from: labelBox, to: left.boundingBox, mode: .sameLineRight)
                    < valueDistance(from: labelBox, to: right.boundingBox, mode: .sameLineRight)
            }
            .first
    }

    private static func splitNameRowOCRRegion(toRightOf labelBox: NormalizedRect) -> NormalizedRect {
        let gap = max(0.008, labelBox.height * 0.30)
        let x = min(labelBox.maxX + gap, 0.96)
        let height = min(max(labelBox.height * 2.0, 0.028), 0.060)
        let y = max(labelBox.centerY - height / 2, 0)
        let width = min(max(0.22, labelBox.width * 5.0), 0.38, 0.98 - x)

        return NormalizedRect(
            x: x,
            y: y,
            width: width,
            height: min(height, 1 - y)
        )
        .clamped()
    }

    private static func pageRect(from localRect: NormalizedRect, in roiBox: NormalizedRect) -> NormalizedRect {
        NormalizedRect(
            x: roiBox.x + localRect.x * roiBox.width,
            y: roiBox.y + localRect.y * roiBox.height,
            width: localRect.width * roiBox.width,
            height: localRect.height * roiBox.height
        )
        .clamped()
    }

    private static func croppedImage(_ sourceImage: CGImage, to normalizedRect: NormalizedRect) -> CGImage? {
        let imageBounds = CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height)
        let cropRect = CGRect(
            x: normalizedRect.x * Double(sourceImage.width),
            y: normalizedRect.y * Double(sourceImage.height),
            width: normalizedRect.width * Double(sourceImage.width),
            height: normalizedRect.height * Double(sourceImage.height)
        )
        .integral
        .intersection(imageBounds)

        guard cropRect.width >= 2, cropRect.height >= 2 else {
            return nil
        }

        return sourceImage.cropping(to: cropRect)
    }

    private static func scaledImage(_ sourceImage: CGImage, scale: Int) -> CGImage? {
        guard scale > 1 else {
            return sourceImage
        }

        let width = sourceImage.width * scale
        let height = sourceImage.height * scale
        let colorSpace = sourceImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func appNormalizedRect(
        for targetRange: NSRange,
        in recognizedText: VNRecognizedText?,
        text: String,
        fallbackBounds: NormalizedRect
    ) -> NormalizedRect? {
        if let recognizedText,
           let stringRange = Range(targetRange, in: recognizedText.string),
           let preciseBounds = try? recognizedText.boundingBox(for: stringRange)?.boundingBox {
            let bounds = appNormalizedRect(fromVisionBounds: preciseBounds)
            if bounds.width > 0, bounds.height > 0 {
                return bounds
            }
        }

        let estimatedBounds = estimatedAppNormalizedRect(
            for: targetRange,
            in: text,
            fallbackBounds: fallbackBounds
        )

        return estimatedBounds.width > 0 && estimatedBounds.height > 0
            ? estimatedBounds
            : fallbackBounds
    }

    private static func estimatedAppNormalizedRect(
        for targetRange: NSRange,
        in text: String,
        fallbackBounds: NormalizedRect
    ) -> NormalizedRect {
        let textLength = (text as NSString).length
        guard textLength > 0,
              targetRange.location >= 0,
              targetRange.length > 0,
              targetRange.location + targetRange.length <= textLength else {
            return fallbackBounds
        }

        let startRatio = Double(targetRange.location) / Double(textLength)
        let widthRatio = Double(targetRange.length) / Double(textLength)

        return NormalizedRect(
            x: fallbackBounds.x + fallbackBounds.width * startRatio,
            y: fallbackBounds.y,
            width: fallbackBounds.width * widthRatio,
            height: fallbackBounds.height
        )
        .clamped()
    }

    private static func appNormalizedRect(fromVisionBounds visionBounds: CGRect) -> NormalizedRect {
        NormalizedRect(
            x: Double(visionBounds.minX),
            y: Double(1 - visionBounds.maxY),
            width: Double(visionBounds.width),
            height: Double(visionBounds.height)
        )
        .clamped()
    }

    private static func appendCandidate(
        _ candidate: OCRSensitiveCandidate,
        to candidates: inout [OCRSensitiveCandidate]
    ) {
        guard candidate.boundingBox.width > 0, candidate.boundingBox.height > 0 else {
            return
        }

        if let duplicateIndex = candidates.firstIndex(where: { existingCandidate in
            candidateCategoriesOverlap(existingCandidate.category, candidate.category)
                && normalizedText(existingCandidate.text) == normalizedText(candidate.text)
                && existingCandidate.boundingBox.substantiallyOverlaps(candidate.boundingBox)
        }) {
            if isPreferredCandidate(candidate, over: candidates[duplicateIndex]) {
                candidates[duplicateIndex] = candidate
            }
            return
        }

        candidates.append(candidate)
    }

    private static func finalizedCandidates(
        _ candidates: [OCRSensitiveCandidate],
        options: OCRDetectionOptions
    ) -> [OCRSensitiveCandidate] {
        let includedCategories = options.includedCategories
        let presetScopedCandidates = candidates.filter { includedCategories.contains($0.category) }
        let validatedCandidates = presetScopedCandidates.filter { candidate in
            isValidCandidateForFinalOutput(candidate)
        }
        let mergedCandidates = mergedLabelFallbackCandidates(validatedCandidates)
        let revalidatedMergedCandidates = mergedCandidates.filter { candidate in
            isValidCandidateForFinalOutput(candidate)
        }
        let deduplicated = deduplicatedCandidates(revalidatedMergedCandidates)
        guard options.preset == .strict else {
            return deduplicated
        }

        return deduplicatedStrictHospitalCandidates(deduplicated)
    }

    private static func isValidCandidateForFinalOutput(_ candidate: OCRSensitiveCandidate) -> Bool {
        if candidate.valueState == .unreadableContent || candidate.valueState == .emptyField {
            return candidate.detectionKind == .labelFallback
                && candidate.boundingBox.width > 0
                && candidate.boundingBox.height > 0
        }

        if candidate.detectionKind == .labelFallback {
            return false
        }

        if candidate.category == .phone,
           candidate.sourceLabelText?.isEmpty == false {
            return phoneValueIsAcceptable(String(candidate.text.filter(\.isNumber)))
        }

        return isLikelyValue(candidate.text, for: candidate.category)
    }

    private static func bindingForDateValue(
        match: OCRTargetMatch,
        valueBox: NormalizedRect,
        valueItem: OCRTextItem,
        textItems: [OCRTextItem],
        includedCategories: Set<OCRCandidateCategory>
    ) -> OCRDateBinding? {
        let labelRules = dateBindingLabelRules(includedCategories: includedCategories)
        let sameObservationBinding = sameObservationDateBinding(
            match: match,
            valueItem: valueItem,
            labelRules: labelRules
        )
        let nearbyBinding = nearbyDateLabelBinding(
            valueBox: valueBox,
            valueItem: valueItem,
            textItems: textItems,
            labelRules: labelRules
        )

        return [sameObservationBinding, nearbyBinding]
            .compactMap(\.self)
            .sorted(by: dateBindingPrecedes)
            .first
    }

    private static func sameObservationDateBinding(
        match: OCRTargetMatch,
        valueItem: OCRTextItem,
        labelRules: [OCRLabelRule]
    ) -> OCRDateBinding? {
        let nsText = valueItem.text as NSString
        guard match.targetRange.location > 0,
              match.targetRange.location <= nsText.length else {
            return nil
        }

        let prefix = nsText.substring(to: match.targetRange.location)
        return labelRules
            .compactMap { labelRule -> OCRDateBinding? in
                guard let labelMatch = lastLabelTextMatch(for: labelRule, in: prefix) else {
                    return nil
                }

                let labelBounds = appNormalizedRect(
                    for: labelMatch.range,
                    in: valueItem.recognizedText,
                    text: valueItem.text,
                    fallbackBounds: valueItem.boundingBox
                ) ?? valueItem.boundingBox
                let labelDistance = max(0, match.targetRange.location - rangeUpperBound(labelMatch.range))
                guard labelDistance <= 16 else {
                    return nil
                }

                let score = Double(labelDistance) / max(Double(nsText.length), 1)
                    + Double(dateCategoryPriority(labelRule.category)) * 0.001

                return OCRDateBinding(
                    category: labelRule.category,
                    labelText: labelMatch.title,
                    labelBoundingBox: labelBounds,
                    reason: "same observation prefix",
                    score: score
                )
            }
            .sorted(by: dateBindingPrecedes)
            .first
    }

    private static func nearbyDateLabelBinding(
        valueBox: NormalizedRect,
        valueItem: OCRTextItem,
        textItems: [OCRTextItem],
        labelRules: [OCRLabelRule]
    ) -> OCRDateBinding? {
        textItems
            .filter { $0.text != valueItem.text || $0.boundingBox != valueItem.boundingBox }
            .flatMap { labelItem in
                labelRules.compactMap { labelRule -> OCRDateBinding? in
                    guard labelRule.matches(labelItem.text),
                          let proximity = labelValueProximity(
                              labelBox: labelItem.boundingBox,
                              valueBox: valueBox
                          ) else {
                        return nil
                    }

                    return OCRDateBinding(
                        category: labelRule.category,
                        labelText: labelItem.text,
                        labelBoundingBox: labelItem.boundingBox,
                        reason: proximity.reason,
                        score: proximity.score + Double(dateCategoryPriority(labelRule.category)) * 0.001
                    )
                }
            }
            .sorted(by: dateBindingPrecedes)
            .first
    }

    nonisolated private static func dateBindingPrecedes(
        _ left: OCRDateBinding,
        _ right: OCRDateBinding
    ) -> Bool {
        if left.score != right.score {
            return left.score < right.score
        }

        if dateCategoryPriority(left.category) != dateCategoryPriority(right.category) {
            return dateCategoryPriority(left.category) < dateCategoryPriority(right.category)
        }

        return false
    }

    private static func dateBindingLabelRules(includedCategories: Set<OCRCandidateCategory>) -> [OCRLabelRule] {
        [.birthday, .examDate]
            .filter { includedCategories.contains($0) }
            .compactMap { category in
                labelRules.first { $0.category == category }
            }
    }

    private static func labelValueProximity(
        labelBox: NormalizedRect,
        valueBox: NormalizedRect
    ) -> (reason: String, score: Double)? {
        if let sameRowScore = sameRowLeftLabelScore(labelBox: labelBox, valueBox: valueBox) {
            return ("same row left label", sameRowScore)
        }

        if let nearScore = nearbyLabelScore(labelBox: labelBox, valueBox: valueBox) {
            return ("nearby or above label", nearScore + 2)
        }

        return nil
    }

    private static func birthdayIDValueIsNear(
        labelBox: NormalizedRect,
        valueBox: NormalizedRect
    ) -> Bool {
        if labelValueProximity(labelBox: labelBox, valueBox: valueBox) != nil {
            return true
        }

        let rowHeight = max(labelBox.height, valueBox.height)
        let rightGap = valueBox.x - labelBox.maxX
        let centerDeltaY = abs(labelBox.centerY - valueBox.centerY)
        if rightGap >= -0.04,
           rightGap <= 0.82,
           centerDeltaY <= max(rowHeight * 1.35, 0.035) {
            return true
        }

        let verticalGap = valueBox.y - labelBox.maxY
        let centerDeltaX = abs(labelBox.centerX - valueBox.centerX)
        return verticalGap >= -0.02
            && verticalGap <= max(labelBox.height * 4.0, 0.14)
            && centerDeltaX <= max(labelBox.width, valueBox.width) * 1.05 + 0.12
    }

    private static func sameRowLeftLabelScore(
        labelBox: NormalizedRect,
        valueBox: NormalizedRect
    ) -> Double? {
        let rightGap = valueBox.x - labelBox.maxX
        let verticalOverlap = min(labelBox.maxY, valueBox.maxY) - max(labelBox.y, valueBox.y)
        let centerDeltaY = abs(labelBox.centerY - valueBox.centerY)
        let rowHeight = max(labelBox.height, valueBox.height)

        guard rightGap >= -0.025,
              rightGap <= 0.70,
              (verticalOverlap >= min(labelBox.height, valueBox.height) * 0.28 || centerDeltaY <= rowHeight * 0.95) else {
            return nil
        }

        return max(0, rightGap) + centerDeltaY * 2
    }

    private static func nearbyLabelScore(
        labelBox: NormalizedRect,
        valueBox: NormalizedRect
    ) -> Double? {
        let verticalGap = valueBox.y - labelBox.maxY
        let horizontalOverlap = min(labelBox.maxX, valueBox.maxX) - max(labelBox.x, valueBox.x)
        let centerDeltaX = abs(labelBox.centerX - valueBox.centerX)
        let centerDeltaY = abs(labelBox.centerY - valueBox.centerY)
        let horizontalAllowance = max(labelBox.width, valueBox.width) * 0.90 + 0.08

        guard verticalGap >= -0.015,
              verticalGap <= max(labelBox.height * 3.0, 0.10),
              (horizontalOverlap > 0 || centerDeltaX <= horizontalAllowance) else {
            return nil
        }

        return max(0, verticalGap) + centerDeltaX * 0.75 + centerDeltaY
    }

    private static func mergedLabelFallbackCandidates(_ candidates: [OCRSensitiveCandidate]) -> [OCRSensitiveCandidate] {
        var mergedCandidates = candidates
        var removedCandidateIDs = Set<OCRSensitiveCandidate.ID>()

        for fallback in candidates where fallback.detectionKind == .labelFallback {
            guard !removedCandidateIDs.contains(fallback.id),
                  let valueIndex = mergedCandidates.indices
                      .filter({ !removedCandidateIDs.contains(mergedCandidates[$0].id) })
                      .filter({ mergedCandidates[$0].detectionKind != .labelFallback })
                      .filter({ valueCandidate(mergedCandidates[$0], canFill: fallback) })
                      .sorted(by: { leftIndex, rightIndex in
                          fallbackMergeScore(value: mergedCandidates[leftIndex], fallback: fallback)
                              < fallbackMergeScore(value: mergedCandidates[rightIndex], fallback: fallback)
                      })
                      .first else {
                continue
            }

            var mergedCandidate = mergedCandidates[valueIndex]
            mergedCandidate.category = fallback.category
            mergedCandidate.text = displayText(mergedCandidate.text, for: fallback.category)
            mergedCandidate.labelBoundingBox = fallback.labelBoundingBox
            mergedCandidate.sourceLabelText = fallback.sourceLabelText ?? mergedCandidate.sourceLabelText
            mergedCandidate.detectionKind = .labelValue
            mergedCandidate.confidence = max(mergedCandidate.confidence ?? 0, fallback.confidence ?? 0)

            mergedCandidates[valueIndex] = mergedCandidate
            removedCandidateIDs.insert(fallback.id)
        }

        return mergedCandidates.filter { !removedCandidateIDs.contains($0.id) }
    }

    private static func valueCandidate(
        _ valueCandidate: OCRSensitiveCandidate,
        canFill fallback: OCRSensitiveCandidate
    ) -> Bool {
        guard valueCandidate.pageID == fallback.pageID,
              candidateCategoriesOverlap(valueCandidate.category, fallback.category),
              !comparableValue(for: valueCandidate).isEmpty else {
            return false
        }

        if isDateCategory(valueCandidate.category) || isDateCategory(fallback.category) {
            guard normalizedDateValue(valueCandidate.text) != nil else {
                return false
            }
        }

        if let labelBox = fallback.labelBoundingBox,
           labelValueProximity(labelBox: labelBox, valueBox: valueCandidate.boundingBox) != nil {
            return true
        }

        return fallback.boundingBox.substantiallyOverlaps(valueCandidate.boundingBox, threshold: 0.20)
            || boxesOverlapOrAreNearby(fallback.boundingBox, valueCandidate.boundingBox)
    }

    private static func fallbackMergeScore(
        value: OCRSensitiveCandidate,
        fallback: OCRSensitiveCandidate
    ) -> Double {
        if let labelBox = fallback.labelBoundingBox,
           let proximity = labelValueProximity(labelBox: labelBox, valueBox: value.boundingBox) {
            return proximity.score
        }

        let centerDeltaX = abs(value.boundingBox.centerX - fallback.boundingBox.centerX)
        let centerDeltaY = abs(value.boundingBox.centerY - fallback.boundingBox.centerY)
        return centerDeltaX + centerDeltaY * 2
    }

    #if DEBUG
    struct DebugStandardNameRegressionCaseResult {
        let caseName: String
        let passed: Bool
        let details: String
    }

    static func debugStandardNamePostProcessingRegressionCheck() -> Bool {
        debugStandardNamePostProcessingRegressionResults().allSatisfy(\.passed)
    }

    static func debugStandardNamePostProcessingRegressionResults() -> [DebugStandardNameRegressionCaseResult] {
        let pageID = UUID()
        let surnameLabelBox = NormalizedRect(x: 0.10, y: 0.10, width: 0.040, height: 0.018)
        let givenNameLabelBox = NormalizedRect(x: 0.10, y: 0.140, width: 0.040, height: 0.018)
        let caseA = debugStandardCandidates(
            pageID: pageID,
            textItems: [
                debugTextItem("姓:", box: surnameLabelBox),
                debugTextItem("张", box: NormalizedRect(x: 0.18, y: 0.10, width: 0.026, height: 0.018)),
                debugTextItem("名:", box: givenNameLabelBox),
                debugTextItem("三", box: NormalizedRect(x: 0.18, y: 0.14, width: 0.052, height: 0.018)),
                debugTextItem("地址:", box: NormalizedRect(x: 0.10, y: 0.18, width: 0.060, height: 0.018)),
                debugTextItem("测试者: 李四", box: NormalizedRect(x: 0.10, y: 0.26, width: 0.180, height: 0.018))
            ]
        )
        let caseB = debugStandardCandidates(
            pageID: pageID,
            textItems: [
                debugTextItem("姓:", box: surnameLabelBox),
                debugTextItem("张", box: NormalizedRect(x: 0.18, y: 0.10, width: 0.026, height: 0.018)),
                debugTextItem("名:", box: givenNameLabelBox),
                debugTextItem("三", box: NormalizedRect(x: 0.18, y: 0.14, width: 0.026, height: 0.018))
            ]
        )
        let caseC = debugStandardCandidates(
            pageID: pageID,
            textItems: [
                debugTextItem("姓: 欧阳", box: NormalizedRect(x: 0.10, y: 0.10, width: 0.140, height: 0.018)),
                debugTextItem("名: 小明", box: NormalizedRect(x: 0.10, y: 0.14, width: 0.140, height: 0.018))
            ]
        )
        let caseD = debugStandardCandidates(
            pageID: pageID,
            textItems: [
                debugTextItem("测试者: 李四", box: NormalizedRect(x: 0.10, y: 0.10, width: 0.180, height: 0.018))
            ]
        )
        let caseE = debugStandardCandidates(
            pageID: pageID,
            textItems: [
                debugTextItem("姓名：张三", box: NormalizedRect(x: 0.10, y: 0.10, width: 0.160, height: 0.018))
            ]
        )
        let caseF = debugStandardCandidates(
            pageID: pageID,
            textItems: [
                debugTextItem("使用协议名称：“合成测试协议”-打印于：2099-12-31 00:00:00", box: NormalizedRect(x: 0.10, y: 0.10, width: 0.620, height: 0.018))
            ]
        )
        let caseG = debugStandardCandidates(
            pageID: pageID,
            textItems: [
                debugTextItem("姓名：30岁", box: NormalizedRect(x: 0.10, y: 0.10, width: 0.130, height: 0.018))
            ]
        )

        return [
            debugRegressionResult(
                "Case A current split-name contamination",
                candidates: caseA,
                passed: caseA.filter { $0.category == .name }.count == 1
                    && debugContains(caseA, category: .name, text: "张三")
                    && !debugCandidateSummary(caseA).contains("三张李四")
                    && !debugCandidateSummary(caseA).contains("张三李四")
                    && !debugCandidateSummary(caseA).contains("李四")
            ),
            debugRegressionResult(
                "Case B split-name order check",
                candidates: caseB,
                passed: caseB.filter { $0.category == .name }.count == 1
                    && debugContains(caseB, category: .name, text: "张三")
                    && !debugContains(caseB, category: .name, text: "三张")
            ),
            debugRegressionResult(
                "Case C compound surname",
                candidates: caseC,
                passed: caseC.filter { $0.category == .name }.count == 1
                    && debugContains(caseC, category: .name, text: "欧阳小明")
            ),
            debugRegressionResult(
                "Case D tester only excluded",
                candidates: caseD,
                passed: caseD.filter { $0.category == .name }.isEmpty
            ),
            debugRegressionResult(
                "Case E combined name layout",
                candidates: caseE,
                passed: caseE.filter { $0.category == .name }.count == 1
                    && debugContains(caseE, category: .name, text: "张三")
            ),
            debugRegressionResult(
                "Case F false positive long text",
                candidates: caseF,
                passed: caseF.filter { $0.category == .name }.isEmpty
                    && !(labelRules.first { $0.category == .name }?.matches("使用协议名称：“合成测试协议\"-打印于：2099-12-31 00:00:00") ?? true)
                    && !(labelRules.first { $0.category == .name }?.matches("名称") ?? true)
            ),
            debugRegressionResult(
                "Case G invalid value blocked",
                candidates: caseG,
                passed: !debugContains(caseG, category: .name, text: "30岁")
                    && !isLikelyValue("30岁", for: .name)
                    && !isLikelyValue("30", for: .name)
                    && !isLikelyValue("Age 30", for: .name)
                    && !isLikelyValue("三十岁", for: .name)
                    && !isLikelyValue("男", for: .name)
                    && !isLikelyValue("女", for: .name)
                    && !isLikelyValue("M", for: .name)
                    && !isLikelyValue("F", for: .name)
                    && !isLikelyValue("中国", for: .name)
                    && !isLikelyValue("身份证号：[已脱敏]", for: .name)
                    && !isLikelyValue("test@example.com", for: .name)
                    && !isLikelyValue("13800138000", for: .name)
                    && !isLikelyValue("2099-12-31", for: .name)
                    && !isLikelyValue("项目名称", for: .name)
                    && !isLikelyValue("Threshold", for: .name)
                    && !isLikelyValue("ABR", for: .name)
                    && !isLikelyValue("测试者", for: .name)
                    && !isLikelyValue("检查者", for: .name)
                    && !isLikelyValue("操作者", for: .name)
                    && !isLikelyValue("医生", for: .name)
                    && !isLikelyValue("技师", for: .name)
            )
        ]
    }

    private static func debugTextItem(_ text: String, box: NormalizedRect) -> OCRTextItem {
        OCRTextItem(text: text, recognizedText: nil, boundingBox: box, confidence: 0.90)
    }

    private static func debugStandardCandidates(
        pageID: PageItem.ID,
        textItems: [OCRTextItem],
        sourceImage: CGImage? = nil
    ) -> [OCRSensitiveCandidate] {
        buildCandidates(
            from: textItems,
            pageID: pageID,
            options: OCRDetectionOptions(preset: .standard, customFields: []),
            context: OCRProcessingContext(sourceImage: sourceImage)
        )
    }

    private static func debugRegressionResult(
        _ caseName: String,
        candidates: [OCRSensitiveCandidate],
        passed: Bool,
        detailsSuffix: String? = nil
    ) -> DebugStandardNameRegressionCaseResult {
        let details = [debugCandidateSummary(candidates), detailsSuffix]
            .compactMap { $0 }
            .joined(separator: "; ")

        return DebugStandardNameRegressionCaseResult(
            caseName: caseName,
            passed: passed,
            details: details
        )
    }

    static func debugSyntheticSplitNamePipelineImageURL() -> URL? {
        let url = URL(fileURLWithPath: "/private/tmp/MedMaskSyntheticSplitName.jpg")
        guard let image = debugSyntheticSplitNamePipelineImage(),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  UTType.jpeg.identifier as CFString,
                  1,
                  nil
              ) else {
            return nil
        }

        let options = [
            kCGImageDestinationLossyCompressionQuality: 0.95
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return url
    }

    private static func debugSyntheticSplitNameROIImage(includeName: Bool) -> CGImage? {
        debugSyntheticSplitNameImage(includeLabels: false, includeName: includeName)
    }

    private static func debugSyntheticSplitNamePipelineImage() -> CGImage? {
        debugSyntheticSplitNameImage(includeLabels: true, includeName: true)
    }

    private static func debugSyntheticSplitNameImage(includeLabels: Bool, includeName: Bool) -> CGImage? {
        let size = CGSize(width: 1200, height: 800)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()

        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 54, weight: .regular),
            .foregroundColor: NSColor.black
        ]
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 66, weight: .medium),
            .foregroundColor: NSColor.black
        ]

        if includeLabels {
            ("姓：" as NSString).draw(at: CGPoint(x: 120, y: 800 - 145), withAttributes: labelAttributes)
            ("名：" as NSString).draw(at: CGPoint(x: 120, y: 800 - 245), withAttributes: labelAttributes)
        }

        if includeName {
            ("张三" as NSString).draw(at: CGPoint(x: 280, y: 800 - 188), withAttributes: valueAttributes)
        }

        image.unlockFocus()
        return image.cgImageValue
    }

    private static func debugHasSingleNameFallback(
        _ candidates: [OCRSensitiveCandidate],
        missingValueText: String,
        minimumWidth: Double,
        minimumHeight: Double = 0.030
    ) -> Bool {
        let nameCandidates = candidates.filter { $0.category == .name }
        guard nameCandidates.count == 1,
              let nameCandidate = nameCandidates.first,
              nameCandidate.text == missingValueText,
              nameCandidate.detectionKind == .labelFallback else {
            return false
        }

        return nameCandidate.boundingBox.width >= minimumWidth
            && nameCandidate.boundingBox.height >= minimumHeight
    }

    private static func debugContains(
        _ candidates: [OCRSensitiveCandidate],
        category: OCRCandidateCategory,
        text: String
    ) -> Bool {
        candidates.contains { $0.category == category && $0.text == text }
    }

    private static func debugCandidateSummary(_ candidates: [OCRSensitiveCandidate]) -> String {
        if candidates.isEmpty {
            return "[]"
        }

        return candidates
            .map { "\($0.category.rawValue)/\($0.text)/\($0.detectionKind.rawValue)" }
            .joined(separator: ", ")
    }
    #endif

    private static func deduplicatedCandidates(_ candidates: [OCRSensitiveCandidate]) -> [OCRSensitiveCandidate] {
        var deduplicated: [OCRSensitiveCandidate] = []

        for candidate in candidates {
            guard candidate.boundingBox.width > 0, candidate.boundingBox.height > 0 else {
                continue
            }

            if let duplicateIndex = deduplicated.firstIndex(where: { areDuplicateCandidates($0, candidate) }) {
                if isPreferredCandidate(candidate, over: deduplicated[duplicateIndex]) {
                    deduplicated[duplicateIndex] = candidate
                }
            } else {
                deduplicated.append(candidate)
            }
        }

        return deduplicated
    }

    private static func deduplicatedStrictHospitalCandidates(
        _ candidates: [OCRSensitiveCandidate]
    ) -> [OCRSensitiveCandidate] {
        var bestHospitalByPage: [PageItem.ID: OCRSensitiveCandidate] = [:]

        for candidate in candidates where candidate.category == .hospital {
            guard isCleanHospitalCandidateValue(candidate.text) else {
                continue
            }

            if let existing = bestHospitalByPage[candidate.pageID] {
                if isPreferredHospitalCandidate(candidate, over: existing) {
                    bestHospitalByPage[candidate.pageID] = candidate
                }
            } else {
                bestHospitalByPage[candidate.pageID] = candidate
            }
        }

        return candidates.filter { candidate in
            guard candidate.category == .hospital else {
                return true
            }

            return bestHospitalByPage[candidate.pageID]?.id == candidate.id
        }
    }

    private static func areDuplicateCandidates(
        _ left: OCRSensitiveCandidate,
        _ right: OCRSensitiveCandidate
    ) -> Bool {
        guard left.pageID == right.pageID,
               candidateCategoriesOverlap(left.category, right.category) else {
            return false
        }

        let sameLocation = sameCandidateLocation(left, right)

        if left.detectionKind == .labelFallback || right.detectionKind == .labelFallback {
            guard sameLocation else {
                return false
            }

            if left.detectionKind == .labelFallback && right.detectionKind == .labelFallback {
                return comparableValue(for: left) == comparableValue(for: right)
            }

            return true
        }

        let leftValue = comparableValue(for: left)
        let rightValue = comparableValue(for: right)

        if left.category == .hospital,
           right.category == .hospital,
           sameLocation {
            let leftHospital = normalizedOCRLabelText(left.text)
            let rightHospital = normalizedOCRLabelText(right.text)
            return !leftHospital.isEmpty
                && !rightHospital.isEmpty
                && (leftHospital.hasSuffix(rightHospital) || rightHospital.hasSuffix(leftHospital))
        }

        guard !leftValue.isEmpty,
              leftValue == rightValue else {
            return false
        }

        if isDateCategory(left.category), isDateCategory(right.category) {
            return true
        }

        return sameLocation
    }

    private static func sameCandidateLocation(
        _ left: OCRSensitiveCandidate,
        _ right: OCRSensitiveCandidate
    ) -> Bool {
        if candidateBoxesReferToSameLocation(left.boundingBox, right.boundingBox) {
            return true
        }

        if sameNearbyLabel(left, right) || sameSplitLabelArea(left, right) {
            return true
        }

        if let leftLabel = left.labelBoundingBox,
           candidateBoxesReferToSameLocation(leftLabel, right.boundingBox) {
            return true
        }

        if let rightLabel = right.labelBoundingBox,
           candidateBoxesReferToSameLocation(left.boundingBox, rightLabel) {
            return true
        }

        return false
    }

    private static func isPreferredHospitalCandidate(
        _ candidate: OCRSensitiveCandidate,
        over existingCandidate: OCRSensitiveCandidate
    ) -> Bool {
        let candidateLength = normalizedOCRLabelText(candidate.text).count
        let existingLength = normalizedOCRLabelText(existingCandidate.text).count
        if candidateLength != existingLength {
            return candidateLength > existingLength
        }

        if detectionRank(candidate.detectionKind) != detectionRank(existingCandidate.detectionKind) {
            return detectionRank(candidate.detectionKind) < detectionRank(existingCandidate.detectionKind)
        }

        return (candidate.confidence ?? 0) > (existingCandidate.confidence ?? 0)
    }

    private static func candidateBoxesReferToSameLocation(
        _ left: NormalizedRect,
        _ right: NormalizedRect
    ) -> Bool {
        normalizedRectIoU(left, right) >= 0.18
            || left.substantiallyOverlaps(right, threshold: 0.30)
            || boxesOverlapOrAreNearby(left, right)
            || candidateBoxCentersAreClose(left, right)
    }

    private static func candidateBoxCentersAreClose(
        _ left: NormalizedRect,
        _ right: NormalizedRect
    ) -> Bool {
        let centerDeltaX = abs(left.centerX - right.centerX)
        let centerDeltaY = abs(left.centerY - right.centerY)
        let xAllowance = max(left.width, right.width) * 0.85 + 0.08
        let yAllowance = max(left.height, right.height) * 1.25 + 0.045

        return centerDeltaX <= xAllowance && centerDeltaY <= yAllowance
    }

    private static func normalizedRectIoU(
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

    private static func normalizedRectIntersectionArea(
        _ left: NormalizedRect,
        _ right: NormalizedRect
    ) -> Double {
        let width = max(0, min(left.maxX, right.maxX) - max(left.x, right.x))
        let height = max(0, min(left.maxY, right.maxY) - max(left.y, right.y))

        return width * height
    }

    private static func normalizedRectIntersection(
        _ left: NormalizedRect,
        _ right: NormalizedRect
    ) -> NormalizedRect? {
        let x = max(left.x, right.x)
        let y = max(left.y, right.y)
        let maxX = min(left.maxX, right.maxX)
        let maxY = min(left.maxY, right.maxY)
        guard maxX > x, maxY > y else {
            return nil
        }

        return NormalizedRect(
            x: x,
            y: y,
            width: maxX - x,
            height: maxY - y
        )
        .clamped()
    }

    private static func isPreferredCandidate(
        _ candidate: OCRSensitiveCandidate,
        over existingCandidate: OCRSensitiveCandidate
    ) -> Bool {
        let candidateHasExplicitValue = candidate.detectionKind != .labelFallback
        let existingHasExplicitValue = existingCandidate.detectionKind != .labelFallback

        if candidateHasExplicitValue != existingHasExplicitValue {
            return candidateHasExplicitValue
        }

        if (candidate.sourceLabelText?.isEmpty == false) != (existingCandidate.sourceLabelText?.isEmpty == false) {
            return candidate.sourceLabelText?.isEmpty == false
        }

        if candidate.category != existingCandidate.category {
            let categories = Set([candidate.category, existingCandidate.category])

            if categories == Set([.chineseID, .documentNumber]) {
                return candidate.category == .chineseID
            }

            if isDateCategory(candidate.category),
               isDateCategory(existingCandidate.category),
               dateDuplicatePreferencePriority(candidate.category) != dateDuplicatePreferencePriority(existingCandidate.category) {
                return dateDuplicatePreferencePriority(candidate.category) < dateDuplicatePreferencePriority(existingCandidate.category)
            }

            if candidate.detectionKind == .labelValue,
               existingCandidate.detectionKind == .directValue {
                return true
            }

            if candidate.detectionKind == .directValue,
               existingCandidate.detectionKind == .labelValue {
                return false
            }
        }

        if detectionRank(candidate.detectionKind) != detectionRank(existingCandidate.detectionKind) {
            return detectionRank(candidate.detectionKind) < detectionRank(existingCandidate.detectionKind)
        }

        if candidate.category == .hospital,
           existingCandidate.category == .hospital {
            let candidateHospital = normalizedOCRLabelText(candidate.text)
            let existingHospital = normalizedOCRLabelText(existingCandidate.text)
            if candidateHospital.count != existingHospital.count,
               (candidateHospital.hasSuffix(existingHospital) || existingHospital.hasSuffix(candidateHospital)) {
                return candidateHospital.count > existingHospital.count
            }
        }

        return (candidate.confidence ?? 0) > (existingCandidate.confidence ?? 0)
    }

    private static func detectionRank(_ kind: OCRCandidateDetectionKind) -> Int {
        switch kind {
        case .directValue:
            0
        case .labelValue:
            1
        case .labelFallback:
            2
        }
    }

    private static func dateDuplicatePreferencePriority(_ category: OCRCandidateCategory) -> Int {
        switch category {
        case .examDate:
            0
        case .birthday:
            1
        case .date:
            2
        default:
            3
        }
    }

    private static func comparableValue(for candidate: OCRSensitiveCandidate) -> String {
        comparableValue(candidate.text, for: candidate.category)
    }

    private static func comparableValue(
        _ text: String,
        for category: OCRCandidateCategory
    ) -> String {
        if isDateCategory(category),
           let normalizedDate = normalizedDateValue(text) {
            return normalizedDate
        }

        let normalized = normalizedOCRValueText(text)

        switch category {
        case .phone, .fax, .chineseID, .documentNumber, .medicalNumber:
            return normalized.filter { $0.isLetter || $0.isNumber }.lowercased()
        default:
            return normalized.lowercased()
        }
    }

    private static func displayText(
        _ text: String,
        for category: OCRCandidateCategory
    ) -> String {
        if isDateCategory(category),
           let normalizedDate = normalizedDateValue(text) {
            return normalizedDate
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sameNearbyLabel(
        _ left: OCRSensitiveCandidate,
        _ right: OCRSensitiveCandidate
    ) -> Bool {
        guard let leftLabel = left.labelBoundingBox,
              let rightLabel = right.labelBoundingBox else {
            return false
        }

        return boxesOverlapOrAreNearby(leftLabel, rightLabel)
    }

    private static func sameSplitLabelArea(
        _ left: OCRSensitiveCandidate,
        _ right: OCRSensitiveCandidate
    ) -> Bool {
        guard left.category == .name,
              right.category == .name,
              let leftLabel = left.labelBoundingBox,
              let rightLabel = right.labelBoundingBox else {
            return false
        }

        return splitNameLabelBoxesAreAligned(leftLabel, rightLabel)
    }

    private static func splitNameLabelBoxesAreAligned(
        _ left: NormalizedRect,
        _ right: NormalizedRect
    ) -> Bool {
        let horizontalOverlap = min(left.maxX, right.maxX) - max(left.x, right.x)
        let centerDeltaX = abs(left.centerX - right.centerX)
        let verticalGap = min(
            abs(left.maxY - right.y),
            abs(right.maxY - left.y)
        )
        let centerDeltaY = abs(left.centerY - right.centerY)
        let horizontalAligned = horizontalOverlap > 0
            || centerDeltaX <= max(left.width, right.width) * 0.90 + 0.035

        return horizontalAligned
            && verticalGap <= max(left.height, right.height) * 2.4 + 0.035
            && centerDeltaY <= max(left.height, right.height) * 4.0 + 0.06
    }

    private static func boxesOverlapOrAreNearby(
        _ left: NormalizedRect,
        _ right: NormalizedRect
    ) -> Bool {
        if left.substantiallyOverlaps(right, threshold: 0.35) {
            return true
        }

        let centerDeltaX = abs(left.centerX - right.centerX)
        let centerDeltaY = abs(left.centerY - right.centerY)
        let nearbyX = max(left.width, right.width) * 0.75 + 0.025
        let nearbyY = max(left.height, right.height) * 0.75 + 0.018

        return centerDeltaX <= nearbyX && centerDeltaY <= nearbyY
    }

    private static func allowsLabelFallback(
        for category: OCRCandidateCategory,
        fallbackBox: NormalizedRect,
        options: OCRDetectionOptions
    ) -> Bool {
        guard options.includedCategories.contains(category) else {
            return false
        }

        switch options.preset {
        case .strict:
            return true
        case .custom:
            return true
        case .standard:
            return OCRDetectionOptions.standardCategories.contains(category)
        }
    }

    private static func containsDirectValue(
        for category: OCRCandidateCategory,
        in text: String,
        includedCategories: Set<OCRCandidateCategory>
    ) -> Bool {
        targetRules
            .filter {
                includedCategories.contains($0.category)
                    && ($0.category == category
                        || ($0.category == .chineseID && category == .documentNumber)
                        || ($0.category == .documentNumber && category == .chineseID))
            }
            .contains { !$0.matches(in: text).isEmpty }
    }

    private static func candidateCategoriesOverlap(
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

    private static func isDateCategory(_ category: OCRCandidateCategory) -> Bool {
        category == .date || category == .birthday || category == .examDate
    }

    nonisolated private static func dateCategoryPriority(_ category: OCRCandidateCategory) -> Int {
        switch category {
        case .birthday:
            0
        case .examDate:
            1
        case .date:
            2
        default:
            3
        }
    }

    private static func isLikelyNeighborValue(_ text: String) -> Bool {
        let normalized = normalizedText(text)

        guard normalized.count >= 1,
              normalized.count <= 80,
              !isKnownLabelOnlyText(text) else {
            return false
        }

        let punctuationOnly = CharacterSet(charactersIn: "_-—:：/\\|·.。")
        if text.unicodeScalars.allSatisfy({ punctuationOnly.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }) {
            return false
        }

        return true
    }

    private static func isLikelyValue(_ text: String, for category: OCRCandidateCategory) -> Bool {
        let normalized = normalizedText(text)

        guard !normalized.isEmpty,
              normalized.count <= 80,
              !isKnownLabelOnlyText(text) else {
            return false
        }

        switch category {
        case .sex:
            return ["男", "女", "male", "female", "m", "f"].contains(normalized)
        case .age:
            return normalized.range(of: #"^\d{1,3}(岁|y|Y|years?)?$"#, options: .regularExpression) != nil
        case .email:
            return normalized.range(of: #"(?i)^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}$"#, options: .regularExpression) != nil
        case .phone:
            let digitCount = normalized.filter(\.isNumber).count
            return digitCount >= 7 && digitCount <= 18
        case .fax:
            let digitCount = normalized.filter(\.isNumber).count
            return digitCount >= 6 && digitCount <= 18
        case .chineseID:
            return normalized.range(of: #"^\d{17}[0-9x]$"#, options: .regularExpression) != nil
        case .documentNumber, .medicalNumber:
            return normalized.range(of: #"^[a-z0-9][a-z0-9/_]{2,31}$"#, options: .regularExpression) != nil
        case .date, .birthday, .examDate:
            let digitString = String(text.filter(\.isNumber))
            return text.range(of: #"(?<!\d)(?:19|20)\d{2}[-/.年](?:0?[1-9]|1[0-2])[-/.月](?:0?[1-9]|[12]\d|3[01])日?(?!\d)"#, options: .regularExpression) != nil
                || digitString.range(of: #"^(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])$"#, options: .regularExpression) != nil
        case .name:
            return isLikelyHumanNameValue(text)
        case .address:
            return normalized.count >= 2
        case .hospital:
            return isCleanHospitalCandidateValue(text)
        case .department:
            return normalized.count >= 1 && normalized.count <= 30
        case .doctor:
            return normalized.count >= 1 && normalized.count <= 20
        case .staffSignature:
            return staffSignatureDisplayValue(from: text) != nil
        case .bedNumber:
            return normalized.count >= 1 && normalized.count <= 16
        case .custom, .unknown:
            return normalized.count >= 1
        }
    }

    private static func isLikelyHumanNameValue(_ text: String) -> Bool {
        let valueText = normalizedOCRValueText(text)
        let compactText = normalizedOCRLabelText(valueText)
        let asciiDigits = valueText.unicodeScalars.filter { (48...57).contains($0.value) }

        guard compactText.count >= 2,
              compactText.count <= 40,
              !isKnownLabelOnlyText(valueText),
              !isAgeLikeText(valueText),
              !isGenderLikeText(valueText),
              normalizedDateValue(valueText) == nil,
              !isEmailLikeText(valueText),
              !isPhoneLikeText(valueText),
              !isChineseIDLikeText(valueText),
              !isPureNumberLikeText(valueText),
              !isForbiddenNameText(valueText),
              !isAddressLikeNameFalsePositive(valueText) else {
            return false
        }

        if !asciiDigits.isEmpty {
            return false
        }

        if compactText.range(of: #"^[一-龥·]{2,6}$"#, options: .regularExpression) != nil {
            return true
        }

        return valueText.range(
            of: #"(?i)^[A-Z][A-Z'\-]{1,24}(?:\s+[A-Z][A-Z'\-]{1,24}){0,3}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func likelyHumanNameDisplayValue(from text: String) -> String? {
        guard !isStandardForbiddenNameLabelText(text) else {
            return nil
        }

        for match in targetRules.filter({ $0.category == .name }).flatMap({ $0.matches(in: text) }) {
            if let value = likelyHumanNameDisplayValueFromRawValue(match.text) {
                return value
            }
        }

        if let nameLabelRule = labelRules.first(where: { $0.category == .name }),
           let valueRange = nameLabelRule.inlineValueRange(in: text, allowsNameWithSpaces: true) {
            let inlineText = (text as NSString)
                .substring(with: valueRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = likelyHumanNameDisplayValueFromRawValue(inlineText) {
                return value
            }
        }

        return likelyHumanNameDisplayValueFromRawValue(text)
    }

    private static func staffSignatureDisplayValue(from text: String) -> String? {
        guard let value = likelyHumanNameDisplayValueFromRawValue(text),
              !isStandardForbiddenNameLabelText(value),
              !containsForbiddenStaffSignatureValueText(value) else {
            return nil
        }

        return value
    }

    private static func likelyHumanNameDisplayValueFromRawValue(_ text: String) -> String? {
        let valueText = normalizedOCRValueText(text)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":：;；,，.。\"'“”‘’()（）[]【】")))
        let compactText = normalizedOCRLabelText(valueText)

        guard isLikelyHumanNameValue(valueText),
              !compactText.isEmpty else {
            return nil
        }

        if compactText.range(of: #"^[一-龥·]{2,6}$"#, options: .regularExpression) != nil {
            return compactText
        }

        return valueText
    }

    private static func likelyHumanNameComponent(from text: String) -> String? {
        let compactText = normalizedOCRLabelText(text)
        let isSingleChineseNameComponent = compactText.range(
            of: #"^[一-龥·]$"#,
            options: .regularExpression
        ) != nil

        guard compactText.range(of: #"^[一-龥·]{1,3}$"#, options: .regularExpression) != nil,
              splitNameLabelPart(for: text) == nil,
              !isKnownLabelOnlyText(text),
              !isForbiddenNameText(text),
              (!isAgeLikeText(text) || isSingleChineseNameComponent),
              !isGenderLikeText(text),
              !isAddressLikeNameFalsePositive(text) else {
            return nil
        }

        return compactText
    }

    private static func likelySplitNamePartComponent(
        from text: String,
        for part: OCRSplitNameLabelPart
    ) -> String? {
        let valueText = normalizedOCRValueText(text)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":：;；,，.。\"'“”‘’()（）[]【】")))
        let compactText = normalizedOCRLabelText(valueText)
        let isSingleChineseNameComponent = compactText.range(
            of: #"^[一-龥]$"#,
            options: .regularExpression
        ) != nil

        guard !compactText.isEmpty,
              splitNameLabelPart(for: valueText) == nil,
              !isKnownLabelOnlyText(valueText),
              !isForbiddenNameText(valueText),
              !containsForbiddenSplitNamePartText(valueText),
              (!isAgeLikeText(valueText) || isSingleChineseNameComponent),
              !isGenderLikeText(valueText),
              normalizedDateValue(valueText) == nil,
              !isEmailLikeText(valueText),
              !isPhoneLikeText(valueText),
              !isChineseIDLikeText(valueText),
              (!isPureNumberLikeText(valueText) || isSingleChineseNameComponent),
              !isAddressLikeNameFalsePositive(valueText) else {
            return nil
        }

        switch part {
        case .surname:
            guard compactText.range(of: #"^[一-龥]{1,2}$"#, options: .regularExpression) != nil else {
                return nil
            }
        case .givenName:
            guard compactText.range(of: #"^[一-龥]{1,4}$"#, options: .regularExpression) != nil else {
                return nil
            }
        }

        return compactText
    }

    private static func likelyEmbeddedSplitNamePartComponent(
        from text: String,
        for part: OCRSplitNameLabelPart
    ) -> String? {
        guard !isKnownLabelOnlyText(text),
              !isForbiddenNameText(text),
              !containsForbiddenSplitNamePartText(text),
              !isAddressLikeNameFalsePositive(text) else {
            return nil
        }

        let normalized = normalizedOCRValueText(text)
        let nsText = normalized as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let regex = try! NSRegularExpression(
            pattern: #"[一-龥·]{1,4}"#,
            options: []
        )

        return regex
            .matches(in: normalized, range: fullRange)
            .compactMap { match in
                likelySplitNamePartComponent(
                    from: nsText.substring(with: match.range),
                    for: part
                )
            }
            .first
    }

    private static func containsForbiddenSplitNamePartText(_ text: String) -> Bool {
        let compact = normalizedOCRLabelText(text)
        guard !compact.isEmpty else {
            return false
        }

        return splitNamePartForbiddenTexts.contains { forbiddenText in
            let forbidden = normalizedOCRLabelText(forbiddenText)
            return !forbidden.isEmpty && compact.contains(forbidden)
        }
    }

    private static func containsForbiddenStaffSignatureValueText(_ text: String) -> Bool {
        let compact = normalizedOCRLabelText(text)
        guard !compact.isEmpty else {
            return false
        }

        return staffSignatureForbiddenValueTexts.contains { forbiddenText in
            let forbidden = normalizedOCRLabelText(forbiddenText)
            return !forbidden.isEmpty && (compact == forbidden || compact.hasPrefix(forbidden) || compact.contains(forbidden))
        }
    }

    private static func isAgeLikeText(_ text: String) -> Bool {
        let normalized = normalizedOCRValueText(text).lowercased()
        let compact = normalizedOCRLabelText(normalized)

        return compact.range(of: #"^(?:age)?\d{1,3}(?:岁|years?|y)?$"#, options: .regularExpression) != nil
            || compact.range(of: #"^[一二三四五六七八九十百零〇两]{1,4}岁$"#, options: .regularExpression) != nil
    }

    private static func isGenderLikeText(_ text: String) -> Bool {
        ["男", "女", "m", "f", "male", "female"].contains(normalizedOCRLabelText(text))
    }

    private static func isEmailLikeText(_ text: String) -> Bool {
        normalizedOCRValueText(text).range(
            of: #"(?i)^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isPhoneLikeText(_ text: String) -> Bool {
        let digits = text.filter(\.isNumber)

        return digits.count >= 7 && digits.count <= 18
    }

    private static func isChineseIDLikeText(_ text: String) -> Bool {
        normalizedText(text).range(of: #"^\d{17}[0-9x]$"#, options: .regularExpression) != nil
    }

    private static func isPureNumberLikeText(_ text: String) -> Bool {
        let compact = normalizedOCRLabelText(text)

        return !compact.isEmpty && compact.allSatisfy(\.isNumber)
    }

    private static func isForbiddenNameText(_ text: String) -> Bool {
        isForbiddenNameValueText(text)
    }

    private static func isForbiddenPatientNameTargetMatch(
        rule: OCRTargetRule,
        match: OCRTargetMatch,
        in text: String,
        options: OCRDetectionOptions
    ) -> Bool {
        guard options.preset == .standard || options.preset == .strict,
              rule.category == .name else {
            return false
        }

        let nsText = text as NSString
        let prefixLength = max(0, min(match.targetRange.location, nsText.length))
        let prefix = nsText.substring(to: prefixLength)

        return isStandardForbiddenNameLabelText(prefix)
    }

    private static func isForbiddenPatientNameLabelMatch(
        labelRule: OCRLabelRule,
        labelText: String,
        options: OCRDetectionOptions
    ) -> Bool {
        (options.preset == .standard || options.preset == .strict)
            && labelRule.category == .name
            && isStandardForbiddenNameLabelText(labelText)
    }

    private static func isAddressLikeNameFalsePositive(_ text: String) -> Bool {
        let compact = normalizedOCRLabelText(text)

        return [
            "中国",
            "china",
            "地址",
            "住址",
            "家庭地址",
            "联系地址"
        ].contains(compact)
    }

    private static func valueDistance(
        from labelBox: NormalizedRect,
        to valueBox: NormalizedRect,
        mode: OCRValueSearchMode
    ) -> Double {
        switch mode {
        case .sameLineRight:
            return max(0, valueBox.x - labelBox.maxX) + abs(valueBox.centerY - labelBox.centerY) * 2
        case .below:
            return max(0, valueBox.y - labelBox.maxY) + abs(valueBox.x - labelBox.x) * 0.75
        }
    }

    private static func normalizedText(_ text: String) -> String {
        normalizedOCRText(text)
    }

    private static func isKnownLabelOnlyText(_ text: String) -> Bool {
        let trimmedText = normalizedOCRValueText(text)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":："))
        let normalized = normalizedOCRLabelText(trimmedText)

        return allOCRLabelPatterns.contains { pattern in
            normalized == normalizedOCRLabelText(pattern)
        }
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

private struct OCRRecognitionInput {
    let cgImage: CGImage
}

private struct OCRProcessingContext {
    let sourceImage: CGImage?

    static let empty = OCRProcessingContext(sourceImage: nil)
}

private struct OCRTextItem {
    let text: String
    let recognizedText: VNRecognizedText?
    let boundingBox: NormalizedRect
    let confidence: Double
}

private struct OCRObservedLabel {
    let title: String
    let range: NSRange
    let boundingBox: NormalizedRect
}

private struct OCRLabelTextMatch {
    let title: String
    let range: NSRange
}

private func fuzzyStaffSignatureLabelTextMatch(in text: String) -> OCRLabelTextMatch? {
    let compact = normalizedOCRLabelText(text)
    guard !compact.isEmpty else {
        return nil
    }

    let exclusions = [
        "测试日期",
        "测试时间",
        "检查日期",
        "检查时间",
        "检查名称",
        "检查项目",
        "项目名称",
        "使用协议名称",
        "医院名称",
        "报告单",
        "检查报告",
        "检验报告",
        "threshold",
        "abr"
    ]
    if exclusions.contains(where: { compact.contains(normalizedOCRLabelText($0)) }) {
        return nil
    }

    for fuzzyLabel in staffSignatureFuzzyLabelPatterns {
        let normalizedNeedle = normalizedOCRLabelText(fuzzyLabel.needle)
        guard compact == normalizedNeedle
            || (compact.hasPrefix(normalizedNeedle) && compact.count <= normalizedNeedle.count + 2) else {
            continue
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let range = nsText.range(of: fuzzyLabel.needle, options: [.caseInsensitive], range: fullRange)
        return OCRLabelTextMatch(
            title: fuzzyLabel.title,
            range: range.location == NSNotFound
                ? NSRange(location: 0, length: min((fuzzyLabel.needle as NSString).length, nsText.length))
                : range
        )
    }

    return nil
}

private struct OCRPhoneValueMatch {
    let value: String
    let range: NSRange
    let digitCount: Int
}

private struct OCRChineseIDMatch {
    let value: String
    let range: NSRange
}

private struct OCRPhoneValueFragment {
    let value: String
    let boundingBox: NormalizedRect
    let confidence: Double
}

private enum OCRSplitNameLabelPart {
    case surname
    case givenName
}

private struct OCRSplitNameLabelItem {
    let index: Int
    let part: OCRSplitNameLabelPart
    let boundingBox: NormalizedRect
    let confidence: Double
    let inlineValue: OCRSplitNameInlineValue?
}

private struct OCRSplitNameLabelGroup {
    let surnameIndex: Int
    let givenNameIndex: Int?
    let surnameBoundingBox: NormalizedRect
    let givenNameBoundingBox: NormalizedRect?
    let labelBoundingBox: NormalizedRect
    let confidence: Double
    let inlineValues: [OCRSplitNameInlineValue]

    var itemIndexes: Set<Int> {
        var indexes = Set([surnameIndex])
        if let givenNameIndex {
            indexes.insert(givenNameIndex)
        }
        return indexes
    }
}

private struct OCRSplitNameInlineValue {
    let part: OCRSplitNameLabelPart
    let text: String
    let boundingBox: NormalizedRect
    let confidence: Double
}

private struct OCRSplitNameComponentValue {
    let part: OCRSplitNameLabelPart
    let text: String
    let boundingBox: NormalizedRect
    let confidence: Double
    let sourceIndex: Int?
}

private struct OCRDateBinding {
    let category: OCRCandidateCategory
    let labelText: String
    let labelBoundingBox: NormalizedRect
    let reason: String
    let score: Double
}

private struct OCRHeaderLine {
    let text: String
    let segments: [OCRHeaderLineSegment]
}

private struct OCRHeaderLineSegment {
    let itemIndex: Int
    let item: OCRTextItem
    let textRange: NSRange
}

private struct OCRHeaderField {
    let category: OCRCandidateCategory
    let text: String
    let range: NSRange
}

private enum OCRValueSearchMode {
    case sameLineRight
    case below
}

private struct OCRTargetRule {
    let category: OCRCandidateCategory
    let regex: NSRegularExpression
    let captureGroup: Int

    func matches(in line: String) -> [OCRTargetMatch] {
        let fullRange = NSRange(location: 0, length: (line as NSString).length)

        return regex
            .matches(in: line, range: fullRange)
            .compactMap { result in
                let range = captureGroup == 0 ? result.range : result.range(at: captureGroup)
                guard range.location != NSNotFound, range.length > 0 else {
                    return nil
                }

                let text = (line as NSString).substring(with: range)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    return nil
                }

                return OCRTargetMatch(text: text, targetRange: range)
            }
    }
}

private struct OCRTargetMatch {
    let text: String
    let targetRange: NSRange
}

private struct OCRLabelRule {
    let category: OCRCandidateCategory
    let labelPatterns: [String]

    func matches(_ text: String) -> Bool {
        if category == .name, isForbiddenNameLabelText(text) {
            return false
        }

        if category == .staffSignature,
           fuzzyStaffSignatureLabelTextMatch(in: text) != nil {
            return true
        }

        let normalized = normalizedOCRLabelText(text)

        return labelPatterns.contains { pattern in
            let normalizedPattern = normalizedOCRLabelText(pattern)
            if isSingleCharacterSplitNameLabelPattern(normalizedPattern) {
                return normalizedSplitNameLabelText(text) == normalizedPattern
            }

            return normalized.localizedCaseInsensitiveContains(normalizedPattern)
        }
    }

    func inlineValueRange(in text: String, allowsNameWithSpaces: Bool = false) -> NSRange? {
        if category == .name, isForbiddenNameLabelText(text) {
            return nil
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        for pattern in labelPatterns.sorted(by: { $0.count > $1.count }) {
            let escapedPattern = NSRegularExpression.escapedPattern(for: pattern)
            let valuePattern = category == .name && allowsNameWithSpaces ? "(.{1,80})" : #"([^\s:：]{1,80})"#
            let regex = try! NSRegularExpression(
                pattern: "\(escapedPattern)\\s*[:：]?\\s*\(valuePattern)",
                options: [.caseInsensitive]
            )

            guard let match = regex.firstMatch(in: text, range: fullRange),
                  match.range(at: 1).location != NSNotFound,
                  match.range(at: 1).length > 0 else {
                continue
            }

            return valueRangeByTrimmingTrailingLabels(from: match.range(at: 1), in: text)
        }

        return nil
    }

    private func valueRangeByTrimmingTrailingLabels(from range: NSRange, in text: String) -> NSRange {
        let nsText = text as NSString
        let capturedValue = nsText.substring(with: range)
        let earliestStop = allOCRLabelPatterns
            .compactMap { pattern -> Int? in
                guard let stopRange = capturedValue.range(of: pattern, options: [.caseInsensitive]) else {
                    return nil
                }

                return capturedValue.distance(from: capturedValue.startIndex, to: stopRange.lowerBound)
            }
            .filter { $0 > 0 }
            .min()

        guard let earliestStop, earliestStop > 0 else {
            return range
        }

        let trimmedRange = NSRange(location: range.location, length: earliestStop)
        let trimmedText = nsText.substring(with: trimmedRange).trimmingCharacters(in: .whitespacesAndNewlines)

        return trimmedText.isEmpty ? range : trimmedRange
    }
}

private let targetRules: [OCRTargetRule] = [
    OCRTargetRule(
        category: .phone,
        pattern: #"(?<!\d)(?:\+?86[-\s]?)?1[3-9]\d[-\s]?\d{4}[-\s]?\d{4}(?!\d)"#
    ),
    OCRTargetRule(
        category: .phone,
        pattern: #"(?<!\d)0\d{2,3}[-\s]?\d{7,8}(?!\d)"#
    ),
    OCRTargetRule(
        category: .chineseID,
        pattern: #"(?<![0-9A-Za-z])\d{6}(?:18|19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[0-9Xx](?![0-9A-Za-z])"#
    ),
    OCRTargetRule(
        category: .email,
        pattern: #"(?i)[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#
    ),
    OCRTargetRule(
        category: .date,
        pattern: #"(?<!\d)(?:19|20)\d{2}[-/.年](?:0?[1-9]|1[0-2])[-/.月](?:0?[1-9]|[12]\d|3[01])日?(?!\d)"#
    ),
    OCRTargetRule(
        category: .documentNumber,
        pattern: #"(?:身份证号|身份证号码|证件号|证件号码|身份证|ID\s*Number|ID\s*No\.?|Identification\s*Number)\s*[:：]?\s*([A-Za-z0-9][A-Za-z0-9\-_/]{3,31})"#,
        captureGroup: 1
    ),
    OCRTargetRule(
        category: .medicalNumber,
        pattern: #"(?:门诊号|住院号|病案号|病历号|样本号|检查号|报告号|申请单号|就诊号|患者编号|条码号|门诊号码|住院号码|病案号码|病历号码|样本编号|检查编号|报告编号|申请编号|医疗记录号|标本号|检验号|报告单号|Patient\s*ID|Medical\s*Record\s*Number|MRN|Accession\s*Number|Sample\s*ID|Report\s*ID)\s*[:：]?\s*([A-Za-z0-9][A-Za-z0-9\-_/]{2,31})"#,
        captureGroup: 1
    ),
    OCRTargetRule(
        category: .name,
        pattern: #"(?:患者姓名|病人姓名|受检者|受检人|被检者|姓名|名字|Name|Patient\s*Name|Subject\s*Name)\s*[:：]?\s*([一-龥·]{2,4})(?=\s|性别|年龄|科室|床号|门诊号|住院号|病案号|样本号|检验号|报告单号|条码号|$)"#,
        captureGroup: 1
    )
]

private let nameLabelPatterns: [String] = [
    "姓名",
    "名字",
    "患者姓名",
    "病人姓名",
    "受检者",
    "受检人",
    "被检者",
    "姓 名",
    "姓：",
    "姓:",
    "名：",
    "名:",
    "Name",
    "Patient Name",
    "Subject Name"
]

private let forbiddenNameLabelTexts: [String] = [
    "使用协议名称",
    "协议名称",
    "项目名称",
    "检查名称",
    "医院名称",
    "文件名称",
    "名称"
]

private let staffSignatureLabelPatterns: [String] = [
    "测试者",
    "测试人员",
    "检查者",
    "检查人员",
    "操作者",
    "操作员",
    "技师",
    "医生",
    "医师",
    "审核者",
    "审核医生",
    "报告医生",
    "送检医生",
    "申请医生",
    "签名",
    "签字",
    "记录者",
    "填表人",
    "Tester",
    "Operator",
    "Technician",
    "Doctor",
    "Physician",
    "Reviewer",
    "Reviewed by",
    "Reported by",
    "Signed by"
]

private let staffSignatureFuzzyLabelPatterns: [(needle: String, title: String)] = [
    ("测试", "测试者"),
    ("试者", "测试者"),
    ("测者", "测试者"),
    ("签", "签名")
]

private let staffSignatureFuzzyNonPatientLabelTexts: [String] = [
    "试者",
    "测者"
]

private let standardNonPatientNameLabelTexts: [String] = staffSignatureLabelPatterns
    + staffSignatureFuzzyNonPatientLabelTexts

private let forbiddenNameValueTexts: [String] = forbiddenNameLabelTexts + [
    "地址",
    "性别",
    "年龄",
    "生日",
    "证件号",
    "身份证号",
    "使用协议",
    "报告单",
    "Threshold",
    "ABR"
] + standardNonPatientNameLabelTexts + [
    "中国"
]

private let splitNamePartForbiddenTexts: [String] = forbiddenNameValueTexts + [
    "电话",
    "手机号",
    "手机",
    "身份证号",
    "身份证号码",
    "电子邮件",
    "男",
    "女",
    "M",
    "F",
    "Age 30"
]

private let staffSignatureForbiddenValueTexts: [String] = forbiddenNameValueTexts + [
    "电话",
    "手机号",
    "手机",
    "身份证号",
    "身份证号码",
    "电子邮件",
    "男",
    "女",
    "M",
    "F",
    "Age 30",
    "报告单",
    "检查报告",
    "检验报告",
    "医院名称",
    "项目名称",
    "检查名称",
    "文件名称"
]

private let phoneLabelPatterns: [String] = [
    "手机号",
    "手机号码",
    "手机",
    "电话",
    "联系电话",
    "电话号码",
    "联系方式",
    "手机号/电话",
    "电话/手机",
    "Tel",
    "Telephone",
    "Phone",
    "Mobile",
    "Contact Number"
]

private let idNumberLabelPatterns: [String] = [
    "身份证号",
    "身份证号码",
    "证件号",
    "证件号码",
    "身份证",
    "ID Number",
    "ID No.",
    "Identification Number"
]

private let medicalNumberLabelPatterns: [String] = [
    "门诊号",
    "住院号",
    "病案号",
    "病历号",
    "样本号",
    "检查号",
    "报告号",
    "申请单号",
    "就诊号",
    "患者编号",
    "条码号",
    "门诊号码",
    "住院号码",
    "病案号码",
    "病历号码",
    "样本编号",
    "检查编号",
    "报告编号",
    "申请编号",
    "Patient ID",
    "Medical Record Number",
    "MRN",
    "Accession Number",
    "Sample ID",
    "Report ID",
    "标本号",
    "检验号",
    "报告单号"
]

private let knownHospitalHeaderNames: [String] = [
    "示例医院"
]

private let hospitalPollutionPrefixPatterns: [String] = [
    "地址",
    "电话",
    "手机",
    "电子邮件",
    "姓名",
    "姓",
    "名",
    "性别",
    "年龄",
    "生日",
    "测试日期",
    "检查日期",
    "身份证号",
    "证件号",
    "测试者",
    "检查者",
    "操作者",
    "医生",
    "技师"
]

private let hospitalPollutionLabelPatterns: [String] = [
    "地址",
    "电话",
    "手机",
    "电子邮件",
    "姓名",
    "性别",
    "年龄",
    "生日",
    "测试日期",
    "检查日期",
    "身份证号",
    "证件号",
    "测试者",
    "检查者",
    "操作者",
    "医生",
    "技师"
]

private let hospitalHeaderSuffixes: [String] = [
    "妇幼保健院",
    "医疗中心",
    "医学中心",
    "中心医院",
    "专科医院",
    "卫生院",
    "门诊部",
    "医院"
]

private let departmentHeaderSuffixes: [String] = [
    "耳鼻咽喉头颈外科",
    "耳鼻咽喉科",
    "神经内科",
    "内分泌科",
    "检验科",
    "影像科",
    "外科",
    "内科",
    "门诊",
    "病区",
    "科"
]

private let reportTitlePatterns: [String] = [
    "检查报告单",
    "检验报告单",
    "检查报告",
    "检验报告",
    "门诊病历",
    "住院病历",
    "报告单",
    "申请单",
    "处方笺",
    "病历"
]

private let headerTrimCharacters = CharacterSet.whitespacesAndNewlines
    .union(CharacterSet(charactersIn: ":：;；,，.。|/\\-_—–－"))

private let birthdayLabelPatterns: [String] = [
    "生日",
    "出生日期",
    "出生年月",
    "出生年月日",
    "出生时间",
    "出生",
    "出生日",
    "出生日期/年龄",
    "出生年月/年龄",
    "出生资料",
    "出生信息",
    "患者生日",
    "病人生日",
    "受检者生日",
    "受检人生日",
    "儿童生日",
    "婴儿生日",
    "新生儿生日",
    "生 日",
    "出 生 日 期",
    "出生 日期",
    "出生年月 日",
    "出生年月日：",
    "生日：",
    "出生日期：",
    "DOB",
    "D.O.B.",
    "Date of Birth",
    "Birth Date",
    "Birthday",
    "Birthdate",
    "Birth",
    "Patient DOB",
    "Patient Date of Birth",
    "Subject DOB",
    "Subject Date of Birth"
]

private let examDateLabelPatterns: [String] = [
    "检查日期",
    "测试日期",
    "检测日期",
    "采样日期",
    "采集日期",
    "报告日期",
    "送检日期",
    "申请日期",
    "就诊日期",
    "门诊日期",
    "入院日期",
    "出院日期",
    "打印日期",
    "打印于",
    "审核日期",
    "发布日期",
    "诊断日期",
    "检验日期",
    "检验时间",
    "测试时间",
    "检查时间",
    "报告时间",
    "采样时间",
    "接收时间",
    "送检时间",
    "Exam Date",
    "Examination Date",
    "Test Date",
    "Collection Date",
    "Sample Date",
    "Sampling Date",
    "Report Date",
    "Request Date",
    "Visit Date",
    "Admission Date",
    "Discharge Date",
    "Print Date",
    "Review Date",
    "Release Date",
    "Diagnosis Date",
    "Inspection Date",
    "Detection Date",
    "Collection Time",
    "Report Time",
    "Test Time"
]

private let labelRules: [OCRLabelRule] = [
    OCRLabelRule(category: .address, labelPatterns: ["地址", "住址", "家庭地址", "联系地址"]),
    OCRLabelRule(category: .phone, labelPatterns: phoneLabelPatterns),
    OCRLabelRule(category: .name, labelPatterns: nameLabelPatterns),
    OCRLabelRule(category: .sex, labelPatterns: ["性别"]),
    OCRLabelRule(category: .age, labelPatterns: ["年龄"]),
    OCRLabelRule(category: .chineseID, labelPatterns: idNumberLabelPatterns),
    OCRLabelRule(category: .medicalNumber, labelPatterns: medicalNumberLabelPatterns),
    OCRLabelRule(category: .birthday, labelPatterns: birthdayLabelPatterns),
    OCRLabelRule(category: .examDate, labelPatterns: examDateLabelPatterns),
    OCRLabelRule(category: .fax, labelPatterns: ["传真"]),
    OCRLabelRule(category: .email, labelPatterns: ["电子邮件", "邮箱", "Email", "E-mail"]),
    OCRLabelRule(category: .hospital, labelPatterns: ["医院名称", "医院", "医疗机构", "机构名称"]),
    OCRLabelRule(category: .department, labelPatterns: ["科室", "科别", "病区", "就诊科室", "申请科室", "检查科室"]),
    OCRLabelRule(category: .staffSignature, labelPatterns: staffSignatureLabelPatterns),
    OCRLabelRule(category: .bedNumber, labelPatterns: ["床号", "床位号", "病床号"])
]

private let allOCRLabelPatterns = labelRules.flatMap(\.labelPatterns)
    + staffSignatureFuzzyNonPatientLabelTexts

private extension OCRTargetRule {
    init(
        category: OCRCandidateCategory,
        pattern: String,
        captureGroup: Int = 0
    ) {
        self.category = category
        self.regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        self.captureGroup = captureGroup
    }
}

private extension NormalizedRect {
    var maxX: Double {
        x + width
    }

    var maxY: Double {
        y + height
    }

    var centerY: Double {
        y + height / 2
    }

    var centerX: Double {
        x + width / 2
    }
}

private func normalizedOCRText(_ text: String) -> String {
    text.replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: "_", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
}

private func isForbiddenNameLabelText(_ text: String) -> Bool {
    let compact = normalizedOCRLabelText(text)

    return forbiddenNameLabelTexts.contains { forbiddenLabel in
        let forbidden = normalizedOCRLabelText(forbiddenLabel)

        if forbidden == "名称" {
            return compact == forbidden
        }

        return compact == forbidden || compact.hasPrefix(forbidden)
    }
}

private func isStandardForbiddenNameLabelText(_ text: String) -> Bool {
    let compact = normalizedOCRLabelText(text)
    guard !compact.isEmpty else {
        return false
    }

    return (forbiddenNameLabelTexts + standardNonPatientNameLabelTexts).contains { forbiddenText in
        let forbidden = normalizedOCRLabelText(forbiddenText)
        return compact == forbidden || compact.hasPrefix(forbidden)
    }
}

private func isForbiddenNameValueText(_ text: String) -> Bool {
    let compact = normalizedOCRLabelText(text)

    return forbiddenNameValueTexts.contains { forbiddenText in
        let forbidden = normalizedOCRLabelText(forbiddenText)

        if forbidden == "名称" || forbidden == "abr" || forbidden == "threshold" {
            return compact == forbidden
        }

        return compact == forbidden || compact.hasPrefix(forbidden)
    }
}

private func normalizedOCRLabelText(_ text: String) -> String {
    normalizedOCRValueText(text)
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: "_", with: "")
        .replacingOccurrences(of: ".", with: "")
        .replacingOccurrences(of: "/", with: "")
        .replacingOccurrences(of: "\\", with: "")
        .replacingOccurrences(of: ":", with: "")
        .replacingOccurrences(of: "：", with: "")
        .replacingOccurrences(of: ";", with: "")
        .replacingOccurrences(of: "；", with: "")
        .replacingOccurrences(of: "﹔", with: "")
        .replacingOccurrences(of: ",", with: "")
        .replacingOccurrences(of: "，", with: "")
        .replacingOccurrences(of: "。", with: "")
        .replacingOccurrences(of: "．", with: "")
        .replacingOccurrences(of: "｡", with: "")
        .replacingOccurrences(of: "﹕", with: "")
        .replacingOccurrences(of: "∶", with: "")
        .replacingOccurrences(of: "︰", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
}

private func normalizedSplitNameLabelText(_ text: String) -> String {
    normalizedOCRValueText(text)
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: ":", with: "")
        .replacingOccurrences(of: "：", with: "")
        .replacingOccurrences(of: "﹕", with: "")
        .replacingOccurrences(of: "∶", with: "")
        .replacingOccurrences(of: "︰", with: "")
        .replacingOccurrences(of: ";", with: "")
        .replacingOccurrences(of: "；", with: "")
        .replacingOccurrences(of: "﹔", with: "")
        .replacingOccurrences(of: "｡", with: "")
        .replacingOccurrences(of: "。", with: "")
        .replacingOccurrences(of: "．", with: "")
        .replacingOccurrences(of: ".", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
}

private func isSingleCharacterSplitNameLabelPattern(_ normalizedPattern: String) -> Bool {
    normalizedPattern == "姓" || normalizedPattern == "名"
}

private func normalizedOCRValueText(_ text: String) -> String {
    let halfWidthText = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
    let normalizedPunctuation = halfWidthText
        .replacingOccurrences(of: "：", with: ":")
        .replacingOccurrences(of: "－", with: "-")
        .replacingOccurrences(of: "—", with: "-")
        .replacingOccurrences(of: "–", with: "-")
        .replacingOccurrences(of: "／", with: "/")
        .replacingOccurrences(of: "。", with: ".")
        .replacingOccurrences(of: "｡", with: ".")

    return normalizedPunctuation
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func normalizedDateValue(_ text: String) -> String? {
    let normalizedText = normalizedOCRValueText(text)
    let nsText = normalizedText as NSString
    let fullRange = NSRange(location: 0, length: nsText.length)
    let pattern = #"(?<!\d)((?:19|20)\d{2})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})\s*日?(?!\d)"#

    if let regex = try? NSRegularExpression(pattern: pattern),
       let match = regex.firstMatch(in: normalizedText, range: fullRange),
       match.numberOfRanges == 4,
       let year = Int(nsText.substring(with: match.range(at: 1))),
       let month = Int(nsText.substring(with: match.range(at: 2))),
       let day = Int(nsText.substring(with: match.range(at: 3))),
       isValidDateParts(year: year, month: month, day: day) {
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    let digits = normalizedText.filter(\.isNumber)
    guard digits.count == 8,
          let year = Int(String(digits.prefix(4))),
          let month = Int(String(digits.dropFirst(4).prefix(2))),
          let day = Int(String(digits.suffix(2))),
          isValidDateParts(year: year, month: month, day: day) else {
        return nil
    }

    return String(format: "%04d-%02d-%02d", year, month, day)
}

private func isValidDateParts(year: Int, month: Int, day: Int) -> Bool {
    (1900...2099).contains(year) && (1...12).contains(month) && (1...31).contains(day)
}
