import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Zoom and pan for practice / quiz maps. Pure math so it can be tested on Linux.
struct MapZoomState: Equatable {
    static let minScale: CGFloat = 1
    static let maxScale: CGFloat = 8
    static let step: CGFloat = 1.25

    var scale: CGFloat = 1
    var offset: CGSize = .zero

    var isZoomed: Bool { scale > 1.001 }

    mutating func reset() {
        scale = 1
        offset = .zero
    }

    /// Sets scale, clamped, keeping `anchor` (view point) fixed on screen.
    mutating func setScale(_ newScale: CGFloat, anchor: CGPoint, in size: CGSize) {
        let next = min(max(newScale, Self.minScale), Self.maxScale)
        guard abs(next - scale) > 0.0001 else {
            clampOffset(in: size)
            return
        }
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let mapX = (anchor.x - c.x - offset.width) / scale + c.x
        let mapY = (anchor.y - c.y - offset.height) / scale + c.y
        scale = next
        if scale <= 1.001 {
            scale = 1
            offset = .zero
            return
        }
        offset = CGSize(
            width: anchor.x - c.x - (mapX - c.x) * scale,
            height: anchor.y - c.y - (mapY - c.y) * scale
        )
        clampOffset(in: size)
    }

    mutating func zoom(by factor: CGFloat, anchor: CGPoint, in size: CGSize) {
        setScale(scale * factor, anchor: anchor, in: size)
    }

    mutating func zoomIn(anchor: CGPoint, in size: CGSize) {
        zoom(by: Self.step, anchor: anchor, in: size)
    }

    mutating func zoomOut(anchor: CGPoint, in size: CGSize) {
        zoom(by: 1 / Self.step, anchor: anchor, in: size)
    }

    mutating func pan(by delta: CGSize, in size: CGSize) {
        guard isZoomed else { return }
        offset.width += delta.width
        offset.height += delta.height
        clampOffset(in: size)
    }

    mutating func clampOffset(in size: CGSize) {
        if scale <= 1.001 {
            scale = 1
            offset = .zero
            return
        }
        let maxX = size.width * (scale - 1) / 2
        let maxY = size.height * (scale - 1) / 2
        offset.width = min(max(offset.width, -maxX), maxX)
        offset.height = min(max(offset.height, -maxY), maxY)
    }

    /// Top-left of the cursor prompt, in the map view (top-left origin, y down).
    /// These are view points from the flipped map overlay, the same space as SwiftUI `.position`.
    /// Zoom and the window toolbar are not applied: the pointer is already in this view.
    /// The pill is vertically centered on the hotspot, 11pt to the right, and flips left near the right edge.
    static func cursorPromptOrigin(pointer: CGPoint, map: CGSize, pill: CGSize) -> CGPoint {
        let gap: CGFloat = 11
        let margin: CGFloat = 6
        let width = max(pill.width, 0)
        let height = max(pill.height, 0)
        var x = pointer.x + gap
        var y = pointer.y - height / 2
        if width > 0, x + width > map.width - margin {
            x = pointer.x - gap - width
        }
        let maxX = max(margin, map.width - width - margin)
        let maxY = max(margin, map.height - height - margin)
        x = min(max(x, margin), maxX)
        y = min(max(y, margin), maxY)
        return CGPoint(x: x, y: y)
    }

    /// View/screen point -> map layout point (FittedMap coordinates).
    func mapPoint(from viewPoint: CGPoint, in size: CGSize) -> CGPoint {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        return CGPoint(
            x: (viewPoint.x - c.x - offset.width) / scale + c.x,
            y: (viewPoint.y - c.y - offset.height) / scale + c.y
        )
    }
}

#if canImport(SwiftUI)
extension GraphicsContext {
    /// Zoom around the view center + offset. Draw land in this space; use stroke `/ zoom.scale`.
    mutating func beginMapZoom(_ zoom: MapZoomState, size: CGSize) {
        translateBy(x: size.width / 2 + zoom.offset.width, y: size.height / 2 + zoom.offset.height)
        scaleBy(x: zoom.scale, y: zoom.scale)
        translateBy(x: -size.width / 2, y: -size.height / 2)
    }
}

/// +/- and reset controls for the map.
struct MapZoomControls: View {
    @Binding var zoom: MapZoomState
    let size: CGSize

    var body: some View {
        VStack(spacing: 1) {
            zoomButton("plus", enabled: zoom.scale < MapZoomState.maxScale - 0.01) {
                zoom.zoomIn(anchor: CGPoint(x: size.width / 2, y: size.height / 2), in: size)
            }
            Divider().frame(width: 18)
            zoomButton("minus", enabled: zoom.scale > MapZoomState.minScale + 0.01) {
                zoom.zoomOut(anchor: CGPoint(x: size.width / 2, y: size.height / 2), in: size)
            }
            Divider().frame(width: 18)
            zoomButton("arrow.counterclockwise", enabled: zoom.isZoomed) {
                zoom.reset()
            }
            .help("Reset zoom")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private func zoomButton(_ systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        HitButton(enabled: enabled, action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .opacity(enabled ? 1 : 0.35)
    }
}
#endif

#if canImport(AppKit) && canImport(SwiftUI)
/// AppKit interaction layer: pinch/scroll zoom, drag pan when zoomed, click + hover for answers.
struct MapInteractionOverlay: NSViewRepresentable {
    var size: CGSize
    var zoom: MapZoomState
    var clicksEnabled: Bool
    var onZoomChange: (MapZoomState) -> Void
    var onClick: ((CGPoint) -> Void)?
    var onHover: ((CGPoint?) -> Void)?
    /// Pointer in view points, and whether a drag-pan is underway. Nil means it left the map.
    var onPointer: ((CGPoint?, Bool) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MapInteractionView {
        let v = MapInteractionView()
        v.coordinator = context.coordinator
        context.coordinator.parent = self
        return v
    }

    func updateNSView(_ nsView: MapInteractionView, context: Context) {
        context.coordinator.parent = self
        nsView.coordinator = context.coordinator
    }

    final class Coordinator {
        var parent: MapInteractionOverlay?
        var dragStartOffset: CGSize = .zero
        var mouseDownPoint: CGPoint = .zero
        var isDragging = false
        var pinchStartScale: CGFloat = 1
    }
}

final class MapInteractionView: NSView {
    weak var coordinator: MapInteractionOverlay.Coordinator?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let options: NSTrackingArea.Options = [
            .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect,
        ]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    /// Hotspot in this map view. The view is flipped, so y grows downward and matches SwiftUI.
    /// `convert` already subtracts the view's window origin, including any toolbar above the map.
    private func viewPoint(from event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func mutateZoom(_ body: (inout MapZoomState, CGSize) -> Void) {
        guard let c = coordinator, let parent = c.parent else { return }
        var zoom = parent.zoom
        body(&zoom, parent.size)
        parent.onZoomChange(zoom)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let c = coordinator, let parent = c.parent else { return }
        let dy = event.scrollingDeltaY
        let dx = event.scrollingDeltaX
        // When zoomed, two-finger mostly-horizontal or equal pan; vertical wheel zooms.
        if parent.zoom.isZoomed, abs(dx) > abs(dy) + 0.2 {
            mutateZoom { zoom, size in
                let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 2
                zoom.pan(by: CGSize(width: dx * factor, height: dy * factor), in: size)
            }
            return
        }
        let wantsZoom = event.modifierFlags.contains(.command)
            || event.modifierFlags.contains(.control)
            || abs(dy) >= abs(dx)
        guard wantsZoom, abs(dy) > 0.01 else { return }
        let factor: CGFloat = event.hasPreciseScrollingDeltas
            ? (dy > 0 ? 1.03 : 1 / 1.03)
            : (dy > 0 ? 1.12 : 1 / 1.12)
        let anchor = viewPoint(from: event)
        mutateZoom { zoom, size in
            zoom.zoom(by: factor, anchor: anchor, in: size)
        }
    }

    override func magnify(with event: NSEvent) {
        let factor = 1 + event.magnification
        guard factor > 0.05 else { return }
        let anchor = viewPoint(from: event)
        mutateZoom { zoom, size in
            zoom.zoom(by: factor, anchor: anchor, in: size)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let c = coordinator, let parent = c.parent else { return }
        c.mouseDownPoint = viewPoint(from: event)
        c.dragStartOffset = parent.zoom.offset
        c.isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let c = coordinator, let parent = c.parent else { return }
        let p = viewPoint(from: event)
        let dx = p.x - c.mouseDownPoint.x
        let dy = p.y - c.mouseDownPoint.y
        if !c.isDragging, hypot(dx, dy) < 4 { return }
        guard parent.zoom.isZoomed else { return }
        if !c.isDragging { parent.onPointer?(p, true) }
        c.isDragging = true
        mutateZoom { zoom, size in
            zoom.offset = CGSize(width: c.dragStartOffset.width + dx,
                                 height: c.dragStartOffset.height + dy)
            zoom.clampOffset(in: size)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let c = coordinator, let parent = c.parent else { return }
        let p = viewPoint(from: event)
        if !c.isDragging, parent.clicksEnabled {
            parent.onClick?(p)
        }
        c.isDragging = false
        parent.onPointer?(p, false)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let c = coordinator, let parent = c.parent else { return }
        let point = viewPoint(from: event)
        parent.onPointer?(point, false)
        guard parent.clicksEnabled else { return }
        parent.onHover?(point)
    }

    override func mouseExited(with event: NSEvent) {
        coordinator?.parent?.onPointer?(nil, false)
        coordinator?.parent?.onHover?(nil)
    }
}
#endif
