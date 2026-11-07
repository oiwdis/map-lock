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

    override func mouseEntered(with event: NSEvent) {
        let hover = hover
        DispatchQueue.main.async { hover?(true) }
    }
    override func mouseExited(with event: NSEvent) {
        let hover = hover
        DispatchQueue.main.async { hover?(false) }
    }

    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        window?.makeFirstResponder(nil)
        action()
    }
}

struct SegmentChoice<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
}

/// Full-width segments. The selected one is an accent fill with white text.
/// Each segment's whole rectangle is the hit target, including the click that leaves a text field.
struct SegmentedChoice<Value: Hashable>: View {
    @Binding var selection: Value
    let choices: [SegmentChoice<Value>]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(choices) { choice in
                let selected = selection == choice.value
                HitButton {
                    selection = choice.value
                } label: {
                    Text(choice.title)
                        .font(Theme.font(Theme.Size.sm, .semibold))
                        .foregroundStyle(selected ? Color.white : Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selected ? Theme.accentFill : Color.clear)
                                .shadow(color: selected ? Color.black.opacity(0.16) : .clear, radius: 3, y: 1)
                        )
                        .contentShape(Rectangle())
                }
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.fill2)
        )
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
