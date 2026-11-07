import AppKit
import SwiftUI

/// A full-rectangle click target. The first click still runs when a text field
/// is focused or the window is not key, which a plain SwiftUI button often misses.
struct HitTarget: NSViewRepresentable {
    var enabled: Bool = true
    var action: () -> Void
    var hover: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> HitTargetView {
        let view = HitTargetView()
        view.action = action
        view.enabled = enabled
        view.hover = hover
        return view
    }

    func updateNSView(_ view: HitTargetView, context: Context) {
        view.action = action
        view.enabled = enabled
        view.hover = hover
    }
}

final class HitTargetView: NSView {
    var action: () -> Void = {}
    var hover: ((Bool) -> Void)?
    var enabled = true

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hover?(true) }
    override func mouseExited(with event: NSEvent) { hover?(false) }

    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        window?.makeFirstResponder(nil)
        action()
    }
}

/// Draws `label` and hits the entire frame, not only the glyphs.
struct HitButton<Label: View>: View {
    var enabled: Bool = true
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        label()
            .contentShape(Rectangle())
            .overlay(HitTarget(enabled: enabled, action: action))
    }
}
