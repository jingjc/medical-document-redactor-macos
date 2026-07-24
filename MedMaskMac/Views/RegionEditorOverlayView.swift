import SwiftUI

struct RegionEditorOverlayView: View {
    let contentSize: CGSize
    let regions: [SensitiveRegion]
    let selectedRegionID: SensitiveRegion.ID?
    let onSelectRegion: (SensitiveRegion.ID?) -> Void
    let onCreateRegion: (NormalizedRect) -> Void
    let onUpdateRegion: (SensitiveRegion.ID, NormalizedRect) -> Void
    let onEditTransactionBegan: () -> Void
    let onEditTransactionEnded: () -> Void

    @State private var draftCreationRect: CGRect?
    @State private var moveSession: RegionMoveSession?
    @State private var resizeSession: RegionResizeSession?

    private let minimumRegionWidth: CGFloat = 10
    private let minimumRegionHeight: CGFloat = 10
    private let handleDiameter: CGFloat = 12
    private let handleHitDiameter: CGFloat = 30

    var body: some View {
        ZStack(alignment: .topLeading) {
            interactionBackground

            ForEach(regions) { region in
                regionBody(for: region)
            }

            if let selectedRegion {
                resizeHandles(for: selectedRegion)
            }

            if let draftCreationRect {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                Color.accentColor,
                                style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                            )
                    )
                    .frame(width: draftCreationRect.width, height: draftCreationRect.height)
                    .position(x: draftCreationRect.midX, y: draftCreationRect.midY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: contentSize.width, height: contentSize.height, alignment: .topLeading)
        .clipped()
    }

    private var interactionBackground: some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .frame(width: contentSize.width, height: contentSize.height)
            .gesture(createGesture)
            .simultaneousGesture(emptySpaceTapGesture)
            .zIndex(0)
    }

    private var selectedRegion: SensitiveRegion? {
        guard let selectedRegionID else {
            return nil
        }

        return regions.first { $0.id == selectedRegionID }
    }

    private func regionBody(for region: SensitiveRegion) -> some View {
        let rect = region.bounds.rect(in: contentSize)
        let isSelected = region.id == selectedRegionID

        return ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(fillColor(for: region, isSelected: isSelected))

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    strokeColor(for: region, isSelected: isSelected),
                    style: StrokeStyle(
                        lineWidth: isSelected ? 2.5 : 1.5,
                        dash: isSelected ? [] : [8, 4]
                    )
                )

        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .contentShape(Rectangle())
        .simultaneousGesture(selectRegionTapGesture(for: region))
        .applyIf(isSelected) { view in
            view.gesture(moveGesture(for: region))
        }
        .zIndex(isSelected ? 1 : 0.5)
    }

    private func fillColor(for region: SensitiveRegion, isSelected: Bool) -> Color {
        if region.isMasked {
            return Color.black.opacity(isSelected ? 0.24 : 0.18)
        }

        switch region.source {
        case .manual:
            return Color.black.opacity(0.10)
        case .ocr:
            return Color.black.opacity(0.10)
        }
    }

    private func strokeColor(for region: SensitiveRegion, isSelected: Bool) -> Color {
        if isSelected {
            return Color.accentColor
        }

        switch region.source {
        case .manual:
            return Color.black.opacity(0.65)
        case .ocr:
            return Color.black.opacity(0.65)
        }
    }

    private func resizeHandles(for region: SensitiveRegion) -> some View {
        let rect = region.bounds.rect(in: contentSize)

        return ForEach(RegionHandleCorner.allCases, id: \.self) { corner in
            Circle()
                .fill(Color.accentColor)
                .frame(width: handleDiameter, height: handleDiameter)
                .overlay(
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 2)
                )
                .frame(width: handleHitDiameter, height: handleHitDiameter)
                .contentShape(Rectangle())
                .position(handlePosition(for: corner, in: rect))
                .gesture(resizeGesture(for: region, corner: corner))
                .zIndex(2)
        }
    }

    private var createGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard resizeSession == nil,
                      moveSession == nil else {
                    return
                }

                draftCreationRect = clampedDraftRect(
                    from: value.startLocation,
                    to: value.location
                )
            }
            .onEnded { value in
                defer {
                    draftCreationRect = nil
                }

                let proposedRect = clampedDraftRect(
                    from: value.startLocation,
                    to: value.location
                )

                guard isLargeEnough(proposedRect) else {
                    return
                }

                onEditTransactionBegan()
                onCreateRegion(NormalizedRect(rect: proposedRect, in: contentSize))
                onEditTransactionEnded()
            }
    }

    private var emptySpaceTapGesture: some Gesture {
        SpatialTapGesture()
            .onEnded { _ in
                onSelectRegion(nil)
            }
    }

    private func selectRegionTapGesture(for region: SensitiveRegion) -> some Gesture {
        SpatialTapGesture()
            .onEnded { _ in
                onSelectRegion(region.id)
            }
    }

    private func moveGesture(for region: SensitiveRegion) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if moveSession?.regionID != region.id {
                    onEditTransactionBegan()
                    onSelectRegion(region.id)
                    moveSession = RegionMoveSession(
                        regionID: region.id,
                        initialRect: region.bounds.rect(in: contentSize)
                    )
                }

                guard let initialRect = moveSession?.initialRect else {
                    return
                }

                let movedRect = clampedMovingRect(
                    initialRect.offsetBy(
                        dx: value.translation.width,
                        dy: value.translation.height
                    )
                )

                onUpdateRegion(region.id, NormalizedRect(rect: movedRect, in: contentSize))
            }
            .onEnded { _ in
                moveSession = nil
                onEditTransactionEnded()
            }
    }

    private func resizeGesture(for region: SensitiveRegion, corner: RegionHandleCorner) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if resizeSession?.regionID != region.id || resizeSession?.corner != corner {
                    onEditTransactionBegan()
                    onSelectRegion(region.id)
                    resizeSession = RegionResizeSession(
                        regionID: region.id,
                        corner: corner,
                        initialRect: region.bounds.rect(in: contentSize)
                    )
                }

                guard let resizeSession else {
                    return
                }

                let resizedRect = resizedRect(
                    from: resizeSession.initialRect,
                    corner: corner,
                    translation: value.translation
                )

                onUpdateRegion(region.id, NormalizedRect(rect: resizedRect, in: contentSize))
            }
            .onEnded { _ in
                resizeSession = nil
                onEditTransactionEnded()
            }
    }

    private func handlePosition(for corner: RegionHandleCorner, in rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft:
            CGPoint(x: rect.minX, y: rect.minY)
        case .topRight:
            CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft:
            CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight:
            CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    private func clampedDraftRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        let draftRect = CGRect(
            origin: start,
            size: CGSize(width: end.x - start.x, height: end.y - start.y)
        ).standardized

        return draftRect.intersection(contentBounds)
    }

    private func clampedMovingRect(_ rect: CGRect) -> CGRect {
        let minimumSize = minimumRegionSize
        let width = min(max(rect.width, minimumSize.width), contentBounds.width)
        let height = min(max(rect.height, minimumSize.height), contentBounds.height)
        let clampedX = rect.minX.clamped(min: contentBounds.minX, max: contentBounds.maxX - width)
        let clampedY = rect.minY.clamped(min: contentBounds.minY, max: contentBounds.maxY - height)

        return CGRect(
            x: clampedX,
            y: clampedY,
            width: width,
            height: height
        )
    }

    private func resizedRect(from initialRect: CGRect, corner: RegionHandleCorner, translation: CGSize) -> CGRect {
        let minimumSize = minimumRegionSize
        var minX = initialRect.minX
        var minY = initialRect.minY
        var maxX = initialRect.maxX
        var maxY = initialRect.maxY

        switch corner {
        case .topLeft:
            minX = (initialRect.minX + translation.width)
                .clamped(min: contentBounds.minX, max: initialRect.maxX - minimumSize.width)
            minY = (initialRect.minY + translation.height)
                .clamped(min: contentBounds.minY, max: initialRect.maxY - minimumSize.height)
        case .topRight:
            maxX = (initialRect.maxX + translation.width)
                .clamped(min: initialRect.minX + minimumSize.width, max: contentBounds.maxX)
            minY = (initialRect.minY + translation.height)
                .clamped(min: contentBounds.minY, max: initialRect.maxY - minimumSize.height)
        case .bottomLeft:
            minX = (initialRect.minX + translation.width)
                .clamped(min: contentBounds.minX, max: initialRect.maxX - minimumSize.width)
            maxY = (initialRect.maxY + translation.height)
                .clamped(min: initialRect.minY + minimumSize.height, max: contentBounds.maxY)
        case .bottomRight:
            maxX = (initialRect.maxX + translation.width)
                .clamped(min: initialRect.minX + minimumSize.width, max: contentBounds.maxX)
            maxY = (initialRect.maxY + translation.height)
                .clamped(min: initialRect.minY + minimumSize.height, max: contentBounds.maxY)
        }

        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    private func isLargeEnough(_ rect: CGRect) -> Bool {
        let minimumSize = minimumRegionSize

        return rect.width >= minimumSize.width && rect.height >= minimumSize.height
    }

    private var contentBounds: CGRect {
        CGRect(origin: .zero, size: contentSize)
    }

    private var minimumRegionSize: CGSize {
        CGSize(
            width: min(minimumRegionWidth, contentBounds.width),
            height: min(minimumRegionHeight, contentBounds.height)
        )
    }
}

private enum RegionHandleCorner: CaseIterable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

private struct RegionMoveSession {
    let regionID: SensitiveRegion.ID
    let initialRect: CGRect
}

private struct RegionResizeSession {
    let regionID: SensitiveRegion.ID
    let corner: RegionHandleCorner
    let initialRect: CGRect
}

private extension CGFloat {
    func clamped(min lowerBound: CGFloat, max upperBound: CGFloat) -> CGFloat {
        let resolvedLowerBound = Swift.min(lowerBound, upperBound)
        let resolvedUpperBound = Swift.max(lowerBound, upperBound)

        return Swift.min(Swift.max(self, resolvedLowerBound), resolvedUpperBound)
    }
}

private extension View {
    @ViewBuilder
    func applyIf<Content: View>(
        _ condition: Bool,
        transform: (Self) -> Content
    ) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
