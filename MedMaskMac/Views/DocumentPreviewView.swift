import AppKit
import SwiftUI

struct DocumentPreviewView: View {
    let content: DocumentPreviewContent
    let regions: [SensitiveRegion]
    let candidateHighlights: [DocumentPreviewCandidateHighlight]
    let selectedRegionID: SensitiveRegion.ID?
    let focusedCandidateID: OCRSensitiveCandidate.ID?
    let focusedCandidateBounds: NormalizedRect?
    let isEditingEnabled: Bool
    let zoomScale: CGFloat
    @Binding var scrollOffset: CGPoint
    let onViewportSizeChanged: (CGSize) -> Void
    let onSelectRegion: (SensitiveRegion.ID?) -> Void
    let onCreateRegion: (NormalizedRect) -> Void
    let onUpdateRegion: (SensitiveRegion.ID, NormalizedRect) -> Void
    let onEditTransactionBegan: () -> Void
    let onEditTransactionEnded: () -> Void

    private let previewCornerRadius: CGFloat = 24
    private let previewPadding: CGFloat = 16

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: previewCornerRadius, style: .continuous)
                .fill(Color(nsColor: .underPageBackgroundColor))

            previewBody
                .padding(previewPadding)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 480, idealHeight: 560, maxHeight: 640)
        .clipShape(RoundedRectangle(cornerRadius: previewCornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: previewCornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var previewBody: some View {
        switch content {
        case .empty:
            PreviewFallbackView(
                systemImage: "doc.viewfinder",
                message: L10n.Review.canvasPreviewPlaceholder
            )
        case let .raster(rasterContent):
            GeometryReader { proxy in
                scrollablePreviewCanvas(for: rasterContent, in: proxy.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .onAppear {
                        onViewportSizeChanged(proxy.size)
                    }
                    .onChange(of: proxy.size) { _, newSize in
                        onViewportSizeChanged(newSize)
                    }
            }
        case let .failure(message):
            PreviewFallbackView(
                systemImage: "exclamationmark.triangle",
                message: message
            )
        }
    }

    @ViewBuilder
    private func scrollablePreviewCanvas(
        for rasterContent: DocumentPreviewRasterContent,
        in viewportSize: CGSize
    ) -> some View {
        let renderedSize = renderedCanvasSize(for: rasterContent.canvasSize)
        let documentSize = CGSize(
            width: max(renderedSize.width, viewportSize.width),
            height: max(renderedSize.height, viewportSize.height)
        )
        let canvasOrigin = CGPoint(
            x: max((documentSize.width - renderedSize.width) / 2, 0),
            y: max((documentSize.height - renderedSize.height) / 2, 0)
        )
        let focusedRect = focusedCandidateBounds?
            .rect(in: renderedSize)
            .offsetBy(dx: canvasOrigin.x, dy: canvasOrigin.y)

        if renderedSize.width > 0, renderedSize.height > 0 {
            CanvasScrollView(
                documentSize: documentSize,
                focusedID: focusedCandidateID,
                focusedRect: focusedRect,
                scrollOffset: $scrollOffset
            ) {
                previewCanvas(for: rasterContent, renderedSize: renderedSize)
                    .frame(width: documentSize.width, height: documentSize.height, alignment: .center)
            }
        } else {
            PreviewFallbackView(
                systemImage: "exclamationmark.triangle",
                message: L10n.Review.previewUnavailable
            )
        }
    }

    private func renderedCanvasSize(for contentSize: CGSize) -> CGSize {
        guard contentSize.width > 0,
              contentSize.height > 0,
              zoomScale > 0 else {
            return .zero
        }

        return CGSize(
            width: contentSize.width * zoomScale,
            height: contentSize.height * zoomScale
        )
    }

    private func previewCanvas(
        for rasterContent: DocumentPreviewRasterContent,
        renderedSize: CGSize
    ) -> some View {
        ZStack {
            Image(nsImage: rasterContent.image)
                .resizable()
                .interpolation(.high)
                .allowsHitTesting(false)

            if isEditingEnabled {
                CandidateHighlightOverlayView(
                    contentSize: renderedSize,
                    highlights: candidateHighlights
                )
                .allowsHitTesting(false)
            }

            if isEditingEnabled {
                RegionEditorOverlayView(
                    contentSize: renderedSize,
                    regions: regions,
                    selectedRegionID: selectedRegionID,
                    onSelectRegion: onSelectRegion,
                    onCreateRegion: onCreateRegion,
                    onUpdateRegion: onUpdateRegion,
                    onEditTransactionBegan: onEditTransactionBegan,
                    onEditTransactionEnded: onEditTransactionEnded
                )
            }
        }
        .frame(width: renderedSize.width, height: renderedSize.height)
        .overlay(
            Rectangle()
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        )
        .clipped()
        .contentShape(Rectangle())
    }
}

struct DocumentPreviewCandidateHighlight: Identifiable, Hashable {
    enum Status: Hashable {
        case pending
        case masked
        case ignored

        init(_ candidateStatus: OCRCandidateStatus) {
            switch candidateStatus {
            case .pending:
                self = .pending
            case .masked:
                self = .masked
            case .ignored:
                self = .ignored
            }
        }
    }

    let id: OCRSensitiveCandidate.ID
    let bounds: NormalizedRect
    let status: Status
    let isSelected: Bool
}

private struct CandidateHighlightOverlayView: View {
    let contentSize: CGSize
    let highlights: [DocumentPreviewCandidateHighlight]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(highlights) { highlight in
                let rect = highlight.bounds.rect(in: contentSize)

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(fillColor(for: highlight))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(
                                strokeColor(for: highlight),
                                style: strokeStyle(for: highlight)
                            )
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .frame(width: contentSize.width, height: contentSize.height, alignment: .topLeading)
    }

    private func fillColor(for highlight: DocumentPreviewCandidateHighlight) -> Color {
        if highlight.isSelected {
            return Color.accentColor.opacity(0.12)
        }

        switch highlight.status {
        case .pending:
            return Color.red.opacity(0.14)
        case .masked:
            return Color.black.opacity(0.18)
        case .ignored:
            return Color.secondary.opacity(0.06)
        }
    }

    private func strokeColor(for highlight: DocumentPreviewCandidateHighlight) -> Color {
        if highlight.isSelected {
            return Color.accentColor
        }

        switch highlight.status {
        case .pending:
            return Color.red
        case .masked:
            return Color.black.opacity(0.65)
        case .ignored:
            return Color.secondary.opacity(0.65)
        }
    }

    private func strokeStyle(for highlight: DocumentPreviewCandidateHighlight) -> StrokeStyle {
        switch highlight.status {
        case .pending, .masked:
            return StrokeStyle(lineWidth: highlight.isSelected ? 2.5 : 1.5)
        case .ignored:
            return StrokeStyle(lineWidth: highlight.isSelected ? 2.5 : 1.5, dash: [7, 4])
        }
    }
}

private struct CanvasScrollView<Content: View>: NSViewRepresentable {
    let documentSize: CGSize
    let focusedID: OCRSensitiveCandidate.ID?
    let focusedRect: CGRect?
    @Binding var scrollOffset: CGPoint
    let content: Content

    init(
        documentSize: CGSize,
        focusedID: OCRSensitiveCandidate.ID?,
        focusedRect: CGRect?,
        scrollOffset: Binding<CGPoint>,
        @ViewBuilder content: () -> Content
    ) {
        self.documentSize = documentSize
        self.focusedID = focusedID
        self.focusedRect = focusedRect
        self._scrollOffset = scrollOffset
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.usesPredominantAxisScrolling = false
        scrollView.allowsMagnification = false

        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = CGRect(origin: .zero, size: documentSize)
        scrollView.documentView = hostingView
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.startObserving(scrollView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self

        if let hostingView = scrollView.documentView as? NSHostingView<Content> {
            hostingView.rootView = content
            hostingView.setFrameSize(documentSize)
        } else {
            let hostingView = NSHostingView(rootView: content)
            hostingView.frame = CGRect(origin: .zero, size: documentSize)
            scrollView.documentView = hostingView
        }

        scrollView.documentView?.setFrameSize(documentSize)
        context.coordinator.focusIfNeeded(in: scrollView)
        context.coordinator.applyStoredScrollOffset(in: scrollView)
    }

    final class Coordinator: NSObject {
        var parent: CanvasScrollView
        private weak var observedScrollView: NSScrollView?
        private var isApplyingStoredOffset = false
        private var lastFocusedID: OCRSensitiveCandidate.ID?

        init(parent: CanvasScrollView) {
            self.parent = parent
        }

        deinit {
            if let observedScrollView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: observedScrollView.contentView
                )
            }
        }

        func startObserving(_ scrollView: NSScrollView) {
            observedScrollView = scrollView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        func applyStoredScrollOffset(in scrollView: NSScrollView) {
            let clampedOffset = clampedScrollOffset(parent.scrollOffset, in: scrollView)
            let currentOffset = scrollView.contentView.bounds.origin

            guard abs(currentOffset.x - clampedOffset.x) > 0.5 ||
                  abs(currentOffset.y - clampedOffset.y) > 0.5 else {
                return
            }

            isApplyingStoredOffset = true
            scrollView.contentView.setBoundsOrigin(clampedOffset)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isApplyingStoredOffset = false
        }

        func focusIfNeeded(in scrollView: NSScrollView) {
            guard let focusedID = parent.focusedID else {
                lastFocusedID = nil
                return
            }

            guard focusedID != lastFocusedID,
                  let focusedRect = parent.focusedRect else {
                return
            }

            let viewportSize = scrollView.contentView.bounds.size
            let targetOffset = CGPoint(
                x: focusedRect.midX - viewportSize.width / 2,
                y: focusedRect.midY - viewportSize.height / 2
            )
            let clampedOffset = clampedScrollOffset(targetOffset, in: scrollView)
            lastFocusedID = focusedID
            parent.scrollOffset = clampedOffset

            isApplyingStoredOffset = true
            scrollView.contentView.setBoundsOrigin(clampedOffset)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isApplyingStoredOffset = false
        }

        @objc private func boundsDidChange(_ notification: Notification) {
            guard !isApplyingStoredOffset,
                  let clipView = notification.object as? NSClipView else {
                return
            }

            parent.scrollOffset = clampedScrollOffset(clipView.bounds.origin, in: clipView)
        }

        private func clampedScrollOffset(_ offset: CGPoint, in scrollView: NSScrollView) -> CGPoint {
            clampedScrollOffset(offset, in: scrollView.contentView)
        }

        private func clampedScrollOffset(_ offset: CGPoint, in clipView: NSClipView) -> CGPoint {
            let documentSize = parent.documentSize
            let viewportSize = clipView.bounds.size
            let maxX = max(documentSize.width - viewportSize.width, 0)
            let maxY = max(documentSize.height - viewportSize.height, 0)

            return CGPoint(
                x: min(max(offset.x, 0), maxX),
                y: min(max(offset.y, 0), maxY)
            )
        }
    }
}

private struct PreviewFallbackView: View {
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(.secondary)

            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
