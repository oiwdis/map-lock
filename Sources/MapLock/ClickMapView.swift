import AppKit
import SwiftUI

/// The map for a "Click the country" question: the whole region with nothing highlighted.
/// Small countries get a Seterra-style dot. A click picks a country (see ClickMap.swift).
/// Pinch / scroll zoom and drag pan; hits stay correct at any zoom.
struct ClickMapView: View {
    let world: [Country]
    let target: Country
    let state: TargetState
    /// The country that was clicked, once answered (nil for "I don't know").
    let clicked: String?
    let enabled: Bool
    /// Whole-world practice uses the flat world map; nil keeps the region view.
    var mapScope: PracticeScope? = nil
    /// When false, a wrong click only flashes the place that was hit. The real target stays hidden.
    var revealTarget: Bool = true
    /// Speedrun feedback drawn over the live question. It does not take clicks.
    var speedrunCue: SpeedrunMapCue? = nil
    /// Countries already found. They stay white for the rest of the quiz.
    var found: Set<String> = []
    /// Fired once the layout exists, after a warm hit-test, so the clock can start.
    var onReady: (() -> Void)? = nil
    /// Seterra-style label that follows the pointer. Nil hides it.
    var cursorPrompt: MapCursorPrompt? = nil
    /// True while a modal covers the quiz, so the label does not float over the dialog.
    var cursorPromptSuspended = false
    let onClick: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: String? = nil
    @State private var cache = ClickLayoutCache()
    @State private var zoom = MapZoomState()
    @State private var clicks: [(name: String, at: CGPoint)] = []
    @State private var pins: [MapPin] = []
    @State private var pinnedNames: Set<String> = []
    @State private var pointer: CGPoint?
    @State private var panning = false
    @State private var promptSize = CGSize(width: 120, height: 22)
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let layout = cache.layout(for: target, world: world, size: geo.size, scope: mapScope)
            let hoverParts: [ClickTarget] = hovered.map { name in layout.targets.filter { $0.name == name } } ?? []
            ZStack {
                ClickBaseMap(world: world, layout: layout, scheme: scheme, zoom: zoom)
                    .equatable()
                if enabled, !hoverParts.isEmpty {
                    HoverLayer(parts: hoverParts, zoom: zoom, size: geo.size)
                }
                if state == .wrong {
                    ClickResultLayer(layout: layout, target: target.name, state: state,
                                     clicked: clicked, animate: !reduceMotion, zoom: zoom, size: geo.size,
                                     revealTarget: revealTarget)
                        .id(clicked ?? "-")
                }
                if !found.isEmpty {
                    FoundCountriesLayer(layout: layout, names: found, zoom: zoom, scheme: scheme)
                        .allowsHitTesting(false)
                }
                if let speedrunCue, !speedrunCue.right {
                    WrongMapFlash(layout: layout, correctName: speedrunCue.correctName,
                                  wrongName: speedrunCue.wrongName, zoom: zoom,
                                  revealCorrect: speedrunCue.revealsCorrect, animate: !reduceMotion)
                        .id(speedrunCue.token)
                        .allowsHitTesting(false)
                } else if state == .wrong {
                    WrongMapFlash(layout: layout, correctName: target.name, wrongName: clicked,
                                  zoom: zoom, revealCorrect: true, animate: !reduceMotion)
                        .id(clicked ?? target.name)
                        .allowsHitTesting(false)
                }

                MapInteractionOverlay(
                    size: geo.size,
                    zoom: zoom,
                    clicksEnabled: enabled,
                    onZoomChange: { zoom = $0 },
                    onClick: { viewPoint in
                        let mapPt = zoom.mapPoint(from: viewPoint, in: geo.size)
                        guard let name = ClickMap.hit(mapPt, in: layout.targets), !name.isEmpty else { return }
                        if found.contains(name) { return }
                        hovered = nil
                        clicks.append((name, viewPoint))
                        onClick(name)
                    },
                    onHover: { viewPoint in
                        guard let viewPoint else {
                            if hovered != nil { hovered = nil }
                            return
                        }
                        let mapPt = zoom.mapPoint(from: viewPoint, in: geo.size)
                        let name = ClickMap.hit(mapPt, in: layout.targets)
                        if let name, !name.isEmpty, !found.contains(name) {
                            NSCursor.pointingHand.set()
                            if name != hovered { hovered = name }
                        } else {
                            NSCursor.arrow.set()
                            if hovered != nil { hovered = nil }
                        }
                    },
                    onPointer: { point, dragging in
                        panning = dragging
                        pointer = dragging ? nil : point
                    }
                )

                // Above every country fill. Clicks pass through to the overlay, which
                // still asks ClickMap.hit (a dot wins over the country under it).
                ClickDotsLayer(layout: layout, scheme: scheme, zoom: zoom)
                    .equatable()

                MapPinLayer(pins: pins, reduceMotion: reduceMotion)
                    .allowsHitTesting(false)

                VStack {
                    HStack {
                        Spacer()
                        MapZoomControls(zoom: $zoom, size: geo.size)
                    }
                    Spacer()
                }
                .padding(10)
                .allowsHitTesting(true)

                if let cursorPrompt, let pointer, !panning, !cursorPromptSuspended {
                    MapCursorPromptPill(prompt: cursorPrompt)
                        .fixedSize()
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: PromptSizeKey.self, value: proxy.size)
                            }
                        )
                        .position(promptCenter(pointer: pointer, map: geo.size))
                        .transaction { $0.animation = nil }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onPreferenceChange(PromptSizeKey.self) { size in
                guard size.width > 1 else { return }
                if abs(size.width - promptSize.width) > 0.5 || abs(size.height - promptSize.height) > 0.5 {
                    promptSize = size
                }
            }
            .clipShape(Rectangle())
            .contentShape(Rectangle())
            .onAppear {
                let targets = layout.targets
                Task { @MainActor in
                    _ = ClickMap.hit(CGPoint(x: -10_000, y: -10_000), in: targets)
                    onReady?()
                }
            }
            .onChange(of: found) { _, names in
                let layout = layout
                let size = geo.size
                Task { @MainActor in
                    spawnPins(for: names, layout: layout, size: size)
                }
            }
        }
        .task(id: pins.count) {
            while pins.contains(where: { Date().timeIntervalSince($0.born) <= 1.15 }) {
                try? await Task.sleep(nanoseconds: 200_000_000)
                pins.removeAll { Date().timeIntervalSince($0.born) > 1.15 }
            }
        }
        .onChange(of: target.name) { _, _ in
            hovered = nil
            zoom.reset()
        }
        .onChange(of: enabled) { _, on in
            if !on {
                pointer = nil
                panning = false
            }
        }
        .onChange(of: mapScope) { _, _ in
            zoom.reset()
        }
    }

    private func spawnPins(for names: Set<String>, layout: ClickLayout, size: CGSize) {
        let added = names.subtracting(pinnedNames)
        guard !added.isEmpty else { return }
        for name in added {
            guard let click = clicks.last(where: { $0.name == name }) else { continue }
            let at = pinPoint(name: name, click: click.at, layout: layout, size: size)
            pins.append(MapPin(name: name, at: at, born: Date()))
            pinnedNames.insert(name)
        }
    }

    private func promptCenter(pointer: CGPoint, map: CGSize) -> CGPoint {
        let origin = MapZoomState.cursorPromptOrigin(pointer: pointer, map: map, pill: promptSize)
        return CGPoint(x: origin.x + promptSize.width / 2, y: origin.y + promptSize.height / 2)
    }

    /// Dot center for a microstate, otherwise the exact click.
    private func pinPoint(name: String, click: CGPoint, layout: ClickLayout, size: CGSize) -> CGPoint {
        guard let part = layout.targets.first(where: { $0.name == name }), let dot = part.dot else { return click }
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        return CGPoint(
            x: (dot.x - c.x) * zoom.scale + c.x + zoom.offset.width,
            y: (dot.y - c.y) * zoom.scale + c.y + zoom.offset.height
        )
    }
}

/// The small label that rides next to the pointer in click-the-map questions.
struct MapCursorPrompt: Equatable {
    var lead: String
    var emphasis: String?
    var flag: String?
    var note: String?
    var noteIsGood: Bool = false

    static func click(subject: QuizSubject, country: String, detail: String, flag: String? = nil,
                      note: String? = nil, noteIsGood: Bool = false) -> MapCursorPrompt {
        switch subject {
        case .countries:
            return MapCursorPrompt(lead: "Click on", emphasis: country,
                                   flag: flag ?? CountryFacts.flagEmoji(for: country),
                                   note: note, noteIsGood: noteIsGood)
        case .capitals:
            return MapCursorPrompt(lead: "Click on", emphasis: detail, flag: nil,
                                   note: note, noteIsGood: noteIsGood)
        case .flags:
            return MapCursorPrompt(lead: "Click on", emphasis: nil,
                                   flag: flag ?? CountryFacts.flagEmoji(for: country),
                                   note: note, noteIsGood: noteIsGood)
        }
    }
}

private struct PromptSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0 { value = next }
    }
}

struct MapCursorPromptPill: View {
    var prompt: MapCursorPrompt

    var body: some View {
        HStack(spacing: 3) {
            if let note = prompt.note {
                Text(note)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(prompt.noteIsGood
                                     ? Color(red: 0.09, green: 0.45, blue: 0.18)
                                     : Color(red: 0.78, green: 0.16, blue: 0.14))
            }
            Text(prompt.lead)
                .font(.system(size: 10, weight: .medium))
            if let emphasis = prompt.emphasis, !emphasis.isEmpty {
                Text(emphasis)
                    .font(.system(size: 11, weight: .semibold))
            }
            if let flag = prompt.flag, !flag.isEmpty {
                Text(flag)
                    .font(.system(size: 12))
            }
        }
        .foregroundStyle(Color(white: 0.12))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.92))
                .shadow(color: Color.black.opacity(0.10), radius: 4, y: 1)
        )
        .fixedSize()
    }
}

/// Everything ClickMap works out for one region view at one size.
struct ClickLayout {
    let key: String
    let plan: MapPlan
    let map: FittedMap
    let region: Region
    let targets: [ClickTarget]
    /// Whole-world practice draws every region, not only the target's.
    var drawsAllRegions: Bool = false
}

/// Keeps the layout between redraws (hover changes redraw often). Not observed on purpose.
final class ClickLayoutCache {
    private var last: ClickLayout? = nil

    func layout(for target: Country, world: [Country], size: CGSize,
                scope: PracticeScope? = nil) -> ClickLayout {
        let scopeKey: String = {
            switch scope {
            case .none: return target.region.rawValue
            case .some(.world): return "world"
            case .some(.region(let r)): return r.rawValue
            }
        }()
        let key = "\(scopeKey)|\(Int(size.width))x\(Int(size.height))|\(world.count)"
        if let last, last.key == key { return last }
        let plan: MapPlan
        if let scope {
            plan = MapViews.scopePlan(scope, target: target, world: world)
        } else {
            plan = MapViews.regionPlan(for: target, world: world)
        }
        let map = FittedMap(projection: plan.projection, fit: plan.fit, size: size)
        let targets = ClickMap.targets(for: target, world: world, map: map, size: size, scope: scope)
        let worldScope: Bool = { if case .some(.world) = scope { return true }; return false }()
        let layoutRegion: Region = {
            if case .some(.region(let r)) = scope { return r }
            return target.region
        }()
        let made = ClickLayout(key: key, plan: plan, map: map, region: layoutRegion,
                               targets: targets, drawsAllRegions: worldScope)
        last = made
        return made
    }
}

/// All countries, no highlight. Dots are a later layer so a neighbor's fill cannot cover them.
private struct ClickBaseMap: View, Equatable {
    let world: [Country]
    let layout: ClickLayout
    let scheme: ColorScheme
    let zoom: MapZoomState

    nonisolated static func == (lhs: ClickBaseMap, rhs: ClickBaseMap) -> Bool {
        lhs.layout.key == rhs.layout.key && lhs.scheme == rhs.scheme && lhs.zoom == rhs.zoom
    }

    var body: some View {
        let world = self.world
        let layout = self.layout
        let zoom = self.zoom
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(
                Path(rect),
                with: .radialGradient(
                    Gradient(colors: [Theme.oceanTop, Theme.ocean]),
                    center: CGPoint(x: size.width * 0.5, y: size.height * 0.4),
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.7
                )
            )
            var mapContext = context
            mapContext.beginMapZoom(zoom, size: size)
            let inv = max(zoom.scale, 0.001)
            let visible = rect.insetBy(dx: -40 / inv, dy: -40 / inv)
            for country in world where layout.drawsAllRegions || country.region == layout.region {
                let path = MapDrawing.makePath(layout.map.viewPolygons(for: country))
                guard path.boundingRect.intersects(visible) else { continue }
                mapContext.fill(path, with: .color(Theme.land), style: FillStyle(eoFill: true))
                mapContext.stroke(path, with: .color(Theme.border),
                                  style: StrokeStyle(lineWidth: 0.6 / inv, lineJoin: .round))
            }
        }
        .allowsHitTesting(false)
    }
}

enum ClickDots {
    static func rect(at center: CGPoint, scale: CGFloat = 1) -> CGRect {
        let r = ClickMap.dotRadius / max(scale, 0.001)
        return CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
    }

    static func leader(from anchor: CGPoint, to dot: CGPoint, in context: inout GraphicsContext,
                       color: Color, scale: CGFloat = 1) {
        let inv = max(scale, 0.001)
        let dx = dot.x - anchor.x, dy = dot.y - anchor.y
        let d = hypot(dx, dy)
        guard d > 0 else { return }
        let end = CGPoint(x: dot.x - dx / d * ClickMap.dotRadius / inv,
                          y: dot.y - dy / d * ClickMap.dotRadius / inv)
        var line = Path()
        line.move(to: anchor)
        line.addLine(to: end)
        context.stroke(line, with: .color(color), lineWidth: 1.2 / inv)
        let ar = 1.5 / inv
        context.fill(Path(ellipseIn: CGRect(x: anchor.x - ar, y: anchor.y - ar, width: ar * 2, height: ar * 2)),
                     with: .color(color))
    }

    /// Country outline only. The dot is not part of this path: a fill, glow, or
    /// scale on the country would otherwise paint over a neighbor's dot.
    static func shape(for target: ClickTarget) -> Path {
        MapDrawing.makePath(target.polygons)
    }
}

/// Microstate dots and their leader lines, in one pass above every country.
/// Practice, world zoom, unlock, and races all use this click map. Stats has no map.
///
/// The found fill, the hover, the selection ring, the wrong-answer shake, and the
/// correct-answer glow (the shadow on the result layer) are views under this one.
/// A scale on those views, including the correct-answer pop, stays under the dots,
/// so Malaysia cannot cover Singapore while it grows. The rising name tags and the
/// cursor pill are the only labels above the dots. This layer does not take clicks.
/// `ClickMap.hit` still prefers a dot over the country underneath.
private struct ClickDotsLayer: View, Equatable {
    let layout: ClickLayout
    let scheme: ColorScheme
    let zoom: MapZoomState

    nonisolated static func == (lhs: ClickDotsLayer, rhs: ClickDotsLayer) -> Bool {
        lhs.layout.key == rhs.layout.key && lhs.scheme == rhs.scheme && lhs.zoom == rhs.zoom
    }

    var body: some View {
        let layout = self.layout
        let zoom = self.zoom
        Canvas { context, size in
            var mapContext = context
            mapContext.beginMapZoom(zoom, size: size)
            let inv = max(zoom.scale, 0.001)
            for t in layout.targets {
                guard t.needsLeader, let anchor = t.anchor, let dot = t.dot else { continue }
                ClickDots.leader(from: anchor, to: dot, in: &mapContext, color: Theme.leader, scale: inv)
            }
            for t in layout.targets {
                guard let dot = t.dot else { continue }
                let circle = Path(ellipseIn: ClickDots.rect(at: dot, scale: inv))
                mapContext.fill(circle, with: .color(Theme.dotFill))
                mapContext.stroke(circle, with: .color(Theme.dotStroke), lineWidth: 1.5 / inv)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct HoverLayer: View {
    let parts: [ClickTarget]
    let zoom: MapZoomState
    let size: CGSize
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { context, size in
            var ctx = context
            ctx.beginMapZoom(zoom, size: size)
            for target in parts {
                let shape = MapDrawing.makePath(target.polygons)
                ctx.fill(shape, with: .color(Theme.hover), style: FillStyle(eoFill: true))
            }
        }
        .id(scheme)
        .allowsHitTesting(false)
    }
}

private struct ClickResultLayer: View {
    let layout: ClickLayout
    let target: String
    let state: TargetState
    let clicked: String?
    let animate: Bool
    let zoom: MapZoomState
    let size: CGSize
    var revealTarget: Bool = true
    @State private var start = Date()

    static let flashLength = 0.9
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let _ = scheme
        let targetShapes = layout.targets.filter { $0.name == target }
        let wrongShapes = state == .wrong ? layout.targets.filter { $0.name == clicked && $0.name != target } : []
        let flashing = animate && !wrongShapes.isEmpty
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !flashing)) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            let redOpacity: Double = {
                guard flashing, t < Self.flashLength else { return 0.9 }
                return 0.25 + 0.75 * (1 + cos(t / Self.flashLength * 3 * 2 * .pi)) / 2
            }()
            let look: TargetState = state == .right ? .right : .asking
            let targetColor = look.color
            let ringColor = state == .right ? Theme.ringGood : Theme.ringTiny
            let showTarget = revealTarget || state == .right
            let inv = max(zoom.scale, 0.001)

            Canvas { context, size in
                var ctx = context
                ctx.beginMapZoom(zoom, size: size)
                for wrong in wrongShapes {
                    let path = ClickDots.shape(for: wrong)
                    ctx.fill(path, with: .color(Theme.mapBad.opacity(redOpacity)), style: FillStyle(eoFill: true))
                    ctx.stroke(path, with: .color(Theme.mapBadOutline),
                               style: StrokeStyle(lineWidth: 1.2 / inv, lineJoin: .round))
                }
                if showTarget {
                    for shape in targetShapes {
                        let path = ClickDots.shape(for: shape)
                        ctx.fill(path, with: .color(targetColor), style: FillStyle(eoFill: true))
                        ctx.stroke(path, with: .color(look.outline),
                                   style: StrokeStyle(lineWidth: 1.2 / inv, lineJoin: .round))
                    }
                    if let ring = MapDrawing.markerRing(for: targetShapes.flatMap { $0.polygons }) {
                        ctx.stroke(Path(ellipseIn: ring), with: .color(ringColor),
                                   style: StrokeStyle(lineWidth: 2.5 / inv, lineCap: .round, dash: [5 / inv, 4 / inv]))
                    }
                }
            }
            .shadow(color: showTarget ? targetColor.opacity(0.7) : Theme.mapBad.opacity(0.45), radius: 12)
        }
        .allowsHitTesting(false)
        .onAppear { start = Date() }
    }
}

struct MapPin: Identifiable {
    let id = UUID()
    let name: String
    let at: CGPoint
    let born: Date
}

/// Found countries stay white (a light neutral in dark mode). The border stays the map border.
private struct FoundCountriesLayer: View {
    let layout: ClickLayout
    let names: Set<String>
    let zoom: MapZoomState
    let scheme: ColorScheme

    var body: some View {
        let fill = scheme == .dark ? Color(hex: 0xF2F2F7) : Color.white
        Canvas { context, size in
            var ctx = context
            ctx.beginMapZoom(zoom, size: size)
            let inv = max(zoom.scale, 0.001)
            for part in layout.targets where names.contains(part.name) {
                let path = MapDrawing.makePath(part.polygons)
                ctx.fill(path, with: .color(fill), style: FillStyle(eoFill: true))
                ctx.stroke(path, with: .color(Theme.border),
                           style: StrokeStyle(lineWidth: 0.6 / inv, lineJoin: .round))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Rising name tag. It moves up about 25pt and fades out over 1.1s. Clicks pass through.
private struct MapPinLayer: View {
    let pins: [MapPin]
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: pins.isEmpty)) { timeline in
                ZStack {
                    ForEach(pins) { pin in
                        let t = min(1, timeline.date.timeIntervalSince(pin.born) / 1.1)
                        let rise: CGFloat = reduceMotion ? 0 : 25 * CGFloat(t)
                        let labelBottom = pin.at.y - 12 - rise
                        ZStack {
                            Canvas { context, _ in
                                var line = Path()
                                line.move(to: pin.at)
                                line.addLine(to: CGPoint(x: pin.at.x, y: labelBottom))
                                context.stroke(line, with: .color(.black), lineWidth: 1)
                            }
                            Text(pin.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.black)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.white)
                                .border(Color.black, width: 1)
                                .fixedSize()
                                .position(x: pin.at.x, y: labelBottom - 11)
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .opacity(1 - t)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Red shake on the miss, then the right country blinks so it can be learned.
private struct WrongMapFlash: View {
    let layout: ClickLayout
    let correctName: String
    let wrongName: String?
    let zoom: MapZoomState
    var revealCorrect: Bool = true
    let animate: Bool
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animate)) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            let shake: CGFloat = animate && t < 0.35 ? CGFloat(sin(t / 0.35 * .pi * 4)) * 5 * (1 - t / 0.35) : 0
            let yellow = animate && sin(t * 14) > 0
            ZStack {
                if let wrongName {
                    Canvas { context, size in
                        var ctx = context
                        ctx.beginMapZoom(zoom, size: size)
                        fill(wrongName, color: Theme.mapBad.opacity(0.9), outline: Theme.mapBadOutline,
                             in: &ctx, scale: max(zoom.scale, 0.001))
                    }
                    .offset(x: shake)
                }
                if revealCorrect, t > 0.22 || !animate {
                    Canvas { context, size in
                        var ctx = context
                        ctx.beginMapZoom(zoom, size: size)
                        let color = yellow ? Theme.mapTarget.opacity(0.9) : Theme.mapGood.opacity(0.85)
                        fill(correctName, color: color, outline: yellow ? Theme.mapTargetOutline : Theme.mapGoodOutline,
                             in: &ctx, scale: max(zoom.scale, 0.001))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear { start = Date() }
    }

    private func fill(_ name: String, color: Color, outline: Color, in context: inout GraphicsContext, scale: CGFloat) {
        for part in layout.targets where part.name == name {
            let path = ClickDots.shape(for: part)
            context.fill(path, with: .color(color), style: FillStyle(eoFill: true))
            context.stroke(path, with: .color(outline), style: StrokeStyle(lineWidth: 1.6 / scale, lineJoin: .round))
        }
    }
}

/// Green or red flash for the country that was just answered. Clicks pass through.
private struct SpeedrunCountryFlash: View {
    let layout: ClickLayout
    let cue: SpeedrunMapCue
    let zoom: MapZoomState
    let animate: Bool
    @State private var shown = false

    var body: some View {
        Canvas { context, size in
            var ctx = context
            ctx.beginMapZoom(zoom, size: size)
            let inv = max(zoom.scale, 0.001)
            let opacity = shown || !animate ? 0.72 : 0.2
            if cue.right {
                fill(cue.correctName, color: Theme.mapGood.opacity(opacity), outline: Theme.mapGoodOutline, in: &ctx, scale: inv)
            } else {
                if let wrong = cue.wrongName {
                    fill(wrong, color: Theme.mapBad.opacity(opacity), outline: Theme.mapBadOutline, in: &ctx, scale: inv)
                }
                fill(cue.correctName, color: Theme.mapTarget.opacity(0.35), outline: Theme.mapTargetOutline, in: &ctx, scale: inv, dashed: true)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            if animate {
                withAnimation(.easeOut(duration: cue.right ? 0.4 : 0.6)) { shown = true }
            } else {
                shown = true
            }
        }
    }

    private func fill(_ name: String, color: Color, outline: Color, in context: inout GraphicsContext,
                      scale: CGFloat, dashed: Bool = false) {
        for part in layout.targets where part.name == name {
            let path = ClickDots.shape(for: part)
            context.fill(path, with: .color(color), style: FillStyle(eoFill: true))
            let style = dashed
                ? StrokeStyle(lineWidth: 2.4 / scale, lineCap: .round, dash: [6 / scale, 4 / scale])
                : StrokeStyle(lineWidth: 1.6 / scale, lineJoin: .round)
            context.stroke(path, with: .color(outline), style: style)
        }
    }
}
