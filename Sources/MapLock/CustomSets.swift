import SwiftUI

/// A named list of countries the player can quiz again.
struct NamedCustomSet: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var countries: [String]
}

/// The last custom set, plus named sets, kept on this Mac.
enum CustomSets {
    private static let countriesKey = "maplock.customCountries"
    private static let namedKey = "maplock.customNamedSets"
    static let separator = "\u{1f}"

    static func countries() -> [String] {
        UserDefaults.standard.stringArray(forKey: countriesKey) ?? []
    }

    static func saveCountries(_ names: [String]) {
        UserDefaults.standard.set(Array(Set(names)).sorted(), forKey: countriesKey)
    }

    static func namedSets() -> [NamedCustomSet] {
        guard let data = UserDefaults.standard.data(forKey: namedKey),
              let sets = try? JSONDecoder().decode([NamedCustomSet].self, from: data) else { return [] }
        return sets
    }

    static func saveNamed(_ sets: [NamedCustomSet]) {
        guard let data = try? JSONEncoder().encode(sets) else { return }
        UserDefaults.standard.set(data, forKey: namedKey)
    }

    /// Stable speedrun and race key for this exact list.
    static func placeKey(_ names: [String]) -> String {
        "custom:" + names.sorted().joined(separator: separator)
    }

    static func names(in placeKey: String) -> [String] {
        guard placeKey.hasPrefix("custom:") else { return [] }
        let unit = Character("\u{1f}")
        return placeKey.dropFirst("custom:".count).split(separator: unit).map(String.init)
    }

    /// The saved name when the list matches, otherwise "Custom (12 countries)".
    static func displayTitle(countries: [String]) -> String {
        let sorted = countries.sorted()
        if let match = namedSets().first(where: { $0.countries.sorted() == sorted }), !match.name.isEmpty {
            return match.name
        }
        let count = sorted.count
        return count == 1 ? "Custom (1 country)" : "Custom (\(count) countries)"
    }
}

enum CountrySearch {
    /// Prefix matches on the name or an alias. Accents and case are ignored.
    static func suggestions(query: String, in world: [Country], excluding: Set<String>, limit: Int = 8) -> [String] {
        let needle = AnswerChecker.normalize(query)
        guard !needle.isEmpty else { return [] }
        var hits: [String] = []
        for country in world where country.quizzable && !excluding.contains(country.name) {
            let forms = [country.name] + (alternateNames[country.name] ?? [])
            let matched = forms.contains { form in
                let normalized = AnswerChecker.normalize(form)
                if normalized.hasPrefix(needle) { return true }
                return normalized.split(separator: " ").contains { $0.hasPrefix(needle) }
            }
            if matched { hits.append(country.name) }
            if hits.count >= limit { break }
        }
        return hits
    }
}

/// Search, chips, continent shortcuts, and named sets.
struct CustomSetEditor: View {
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var countries: [String] = CustomSets.countries()
    @State private var query = ""
    @State private var named: [NamedCustomSet] = CustomSets.namedSets()
    @State private var draftName = ""
    @State private var editingId: UUID?
    @State private var pickMode: CustomPickMode = .type
    @State private var mapFocus: CustomMapFocus = .world
    @State private var hoveredCountry: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s3) {
            HStack {
                Text("Custom set")
                    .font(Theme.font(Theme.Size.lg, .bold))
                Spacer()
                Button("Done") { finish() }
                    .buttonStyle(AppButtonStyle(kind: .primary, height: 32))
            }
            Text("\(countries.count) countries. At least 2 to start.")
                .font(Theme.font(Theme.Size.sm))
                .foregroundStyle(Theme.text2)

            SegmentedChoice(
                selection: $pickMode,
                choices: [
                    SegmentChoice(value: CustomPickMode.type, title: "Type"),
                    SegmentChoice(value: CustomPickMode.map, title: "Pick on map"),
                ]
            )

            if pickMode == .type {
                typePicker
            } else {
                mapPicker
            }

            selectedChips

            Divider()
            Text("Saved sets")
                .font(Theme.font(Theme.Size.sm, .semibold))
                .foregroundStyle(Theme.text3)
            HStack(spacing: Theme.Space.s2) {
                TextField("Name, such as Middle East", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { saveNamed() }
                    .buttonStyle(AppButtonStyle(kind: .primary, height: 32))
                    .disabled(countries.count < 2 || draftName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ForEach(named) { set in
                HStack {
                    Button(set.name) { load(set) }
                        .buttonStyle(.plain)
                        .font(Theme.font(Theme.Size.body, .medium))
                    Spacer()
                    Text("\(set.countries.count)")
                        .font(Theme.font(Theme.Size.xs))
                        .foregroundStyle(Theme.text3)
                    Button("Delete") { delete(set) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.bad)
                }
            }
        }
        .padding(Theme.Space.s5)
        .frame(minWidth: 720, minHeight: pickMode == .map ? 640 : 420)
    }

    private var typePicker: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s3) {
            HStack(spacing: Theme.Space.s2) {
                TextField("Type a country", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addFirst() }
                Button("Add") { addFirst() }
                    .buttonStyle(AppButtonStyle(kind: .ghost, height: 32))
                    .disabled(suggestions.isEmpty)
            }
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(suggestions, id: \.self) { name in
                        Button(name) { add(name) }
                            .buttonStyle(.plain)
                            .font(Theme.font(Theme.Size.body))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            ScrollView(.horizontal) {
                HStack(spacing: Theme.Space.s2) {
                    ForEach(Region.allCases, id: \.self) { region in
                        Button("Add all of \(region.title)") { addRegion(region) }
                            .buttonStyle(AppButtonStyle(kind: .ghost, height: 28))
                    }
                    Button("Clear") {
                        countries = []
                        CustomSets.saveCountries([])
                    }
                    .buttonStyle(AppButtonStyle(kind: .ghost, height: 28))
                    .disabled(countries.isEmpty)
                }
            }
        }
    }

    private var mapPicker: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.s2) {
                    mapChip(.world)
                    ForEach(Region.allCases, id: \.self) { region in
                        mapChip(.region(region))
                    }
                }
            }
            CustomPickMap(
                world: CountryCatalog.all,
                focus: mapFocus,
                selected: Set(countries),
                onToggle: toggle,
                onHover: { hoveredCountry = $0 }
            )
            .frame(height: 300)
            HStack(spacing: Theme.Space.s2) {
                Text(mapStatusLine)
                    .font(Theme.font(Theme.Size.sm))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.s2)
                Button(mapFocus.selectTitle) { selectFocus() }
                    .buttonStyle(AppButtonStyle(kind: .ghost, height: 28))
                Button(mapFocus.clearTitle) { clearFocus() }
                    .buttonStyle(AppButtonStyle(kind: .ghost, height: 28))
                    .disabled(focusSelectionCount == 0)
            }
        }
    }

    private var selectedChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Space.s2) {
                ForEach(countries, id: \.self) { name in
                    HStack(spacing: 4) {
                        Text(name)
                            .font(Theme.font(Theme.Size.sm))
                            .lineLimit(1)
                        Button { remove(name) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Theme.fill2))
                }
            }
        }
        .frame(minHeight: 28)
    }

    private func mapChip(_ focus: CustomMapFocus) -> some View {
        let selected = mapFocus == focus
        return Button {
            mapFocus = focus
        } label: {
            Text(focus.chipTitle)
                .font(Theme.font(Theme.Size.sm, .semibold))
                .foregroundStyle(selected ? Color.white : Theme.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(selected ? Theme.accentFill : Theme.fill2))
        }
        .buttonStyle(.plain)
    }

    private var mapStatusLine: String {
        if let hoveredCountry { return hoveredCountry }
        let count = countries.count
        return count == 1 ? "1 selected" : "\(count) selected"
    }

    private var focusNames: Set<String> {
        let world = CountryCatalog.all
        switch mapFocus {
        case .world:
            return Set(world.filter(\.quizzable).map(\.name))
        case .region(let region):
            return Set(world.filter { $0.quizzable && $0.region == region }.map(\.name))
        }
    }

    private var focusSelectionCount: Int {
        countries.reduce(0) { $0 + (focusNames.contains($1) ? 1 : 0) }
    }

    private var suggestions: [String] {
        CountrySearch.suggestions(query: query, in: CountryCatalog.all, excluding: Set(countries))
    }

    private func addFirst() {
        guard let name = suggestions.first else { return }
        add(name)
    }

    private func add(_ name: String) {
        guard !countries.contains(name) else { return }
        countries.append(name)
        countries.sort()
        query = ""
        CustomSets.saveCountries(countries)
    }

    private func remove(_ name: String) {
        countries.removeAll { $0 == name }
        CustomSets.saveCountries(countries)
    }

    private func toggle(_ name: String) {
        if countries.contains(name) {
            remove(name)
        } else {
            add(name)
        }
    }

    private func selectFocus() {
        countries = Array(Set(countries).union(focusNames)).sorted()
        CustomSets.saveCountries(countries)
    }

    private func clearFocus() {
        countries.removeAll { focusNames.contains($0) }
        CustomSets.saveCountries(countries)
    }

    private func addRegion(_ region: Region) {
        let more = CountryCatalog.all.filter { $0.quizzable && $0.region == region }.map(\.name)
        countries = Array(Set(countries).union(more)).sorted()
        CustomSets.saveCountries(countries)
    }

    private func load(_ set: NamedCustomSet) {
        countries = set.countries.sorted()
        draftName = set.name
        editingId = set.id
        CustomSets.saveCountries(countries)
    }

    private func saveNamed() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, countries.count >= 2 else { return }
        let list = countries.sorted()
        if let id = editingId, let index = named.firstIndex(where: { $0.id == id }) {
            named[index].name = name
            named[index].countries = list
        } else if let index = named.firstIndex(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) {
            named[index].countries = list
            editingId = named[index].id
        } else {
            let set = NamedCustomSet(id: UUID(), name: name, countries: list)
            named.append(set)
            editingId = set.id
        }
        CustomSets.saveNamed(named)
    }

    private func delete(_ set: NamedCustomSet) {
        named.removeAll { $0.id == set.id }
        if editingId == set.id { editingId = nil }
        CustomSets.saveNamed(named)
    }

    private func finish() {
        CustomSets.saveCountries(countries)
        onDone()
        dismiss()
    }
}

struct CustomSetSummary: View {
    var onEdit: () -> Void

    var body: some View {
        let names = CustomSets.countries()
        HStack(spacing: Theme.Space.s2) {
            Text(names.count < 2 ? "Pick at least 2 countries." : "\(names.count) countries")
                .font(Theme.font(Theme.Size.xs))
                .foregroundStyle(Theme.text3)
            Button("Edit", action: onEdit)
                .buttonStyle(.plain)
                .font(Theme.font(Theme.Size.xs, .semibold))
                .foregroundStyle(Theme.accent)
        }
    }
}

/// Filled when the map loads, so the custom picker can search without the window owning the world.
enum CountryCatalog {
    static var all: [Country] = []
}

enum CustomPickMode: Hashable {
    case type
    case map
}

enum CustomMapFocus: Hashable {
    case world
    case region(Region)

    var chipTitle: String {
        switch self {
        case .world: return "World"
        case .region(let region): return region.title
        }
    }

    var selectTitle: String {
        switch self {
        case .world: return "Select all of the world"
        case .region(let region): return "Select all of \(region.title)"
        }
    }

    var clearTitle: String {
        switch self {
        case .world: return "Clear the world"
        case .region(let region): return "Clear \(region.title)"
        }
    }

    var scope: PracticeScope {
        switch self {
        case .world: return .world
        case .region(let region): return .region(region)
        }
    }
}

/// Flat Miller map for choosing countries. A click toggles. A drag pans and does not toggle.
struct CustomPickMap: View {
    let world: [Country]
    let focus: CustomMapFocus
    let selected: Set<String>
    var onToggle: (String) -> Void
    var onHover: (String?) -> Void

    @State private var zoom = MapZoomState()
    @State private var cache = ClickLayoutCache()
    @State private var hovered: String?
    @State private var pointer: CGPoint?
    @State private var panning = false

    var body: some View {
        GeometryReader { geo in
            if let sample = sampleCountry {
                let layout = cache.layout(for: sample, world: world, size: geo.size, scope: focus.scope)
                ZStack {
                    pickBase(layout: layout, zoom: zoom)
                    selectedFill(layout: layout, zoom: zoom)
                    if let hovered, !panning {
                        hoverFill(layout: layout, name: hovered, zoom: zoom, selected: selected.contains(hovered))
                    }
                    MapInteractionOverlay(
                        size: geo.size,
                        zoom: zoom,
                        clicksEnabled: true,
                        onZoomChange: { zoom = $0 },
                        onClick: { viewPoint in
                            let mapPt = zoom.mapPoint(from: viewPoint, in: geo.size)
                            guard let name = ClickMap.hit(mapPt, in: layout.targets), !name.isEmpty else { return }
                            onToggle(name)
                        },
                        onHover: { viewPoint in
                            guard let viewPoint else {
                                setHover(nil)
                                return
                            }
                            let mapPt = zoom.mapPoint(from: viewPoint, in: geo.size)
                            let name = ClickMap.hit(mapPt, in: layout.targets)
                            if let name, !name.isEmpty {
                                NSCursor.pointingHand.set()
                                setHover(name)
                            } else {
                                NSCursor.arrow.set()
                                setHover(nil)
                            }
                        },
                        onPointer: { point, dragging in
                            panning = dragging
                            pointer = dragging ? nil : point
                            if dragging { setHover(nil) }
                        }
                    )
                    pickDots(layout: layout, zoom: zoom)
                    if let hovered, !panning, let pointer {
                        Text(hovered)
                            .font(Theme.font(Theme.Size.sm, .semibold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.black.opacity(0.82))
                            )
                            .position(tooltipPoint(pointer, in: geo.size))
                            .allowsHitTesting(false)
                    }
                    VStack {
                        HStack {
                            Spacer()
                            MapZoomControls(zoom: $zoom, size: geo.size)
                        }
                        Spacer()
                    }
                    .padding(8)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            } else {
                Text("The map is still loading.")
                    .font(Theme.font(Theme.Size.sm))
                    .foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.ocean)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.hairline2, lineWidth: 1)
        )
        .onChange(of: focus) { _, _ in
            zoom.reset()
            setHover(nil)
        }
    }

    private var sampleCountry: Country? {
        switch focus {
        case .world:
            return world.first { $0.quizzable }
        case .region(let region):
            return world.first { $0.quizzable && $0.region == region }
        }
    }

    private func setHover(_ name: String?) {
        if hovered != name {
            hovered = name
            onHover(name)
        }
    }

    private func tooltipPoint(_ pointer: CGPoint, in size: CGSize) -> CGPoint {
        let x = min(max(pointer.x, 56), max(56, size.width - 56))
        let y = min(max(pointer.y - 28, 16), max(16, size.height - 16))
        return CGPoint(x: x, y: y)
    }

    private func pickBase(layout: ClickLayout, zoom: MapZoomState) -> some View {
        Canvas { context, size in
            var mapContext = context
            mapContext.beginMapZoom(zoom, size: size)
            let inv = max(zoom.scale, 0.001)
            let visible = CGRect(origin: .zero, size: size).insetBy(dx: -40 / inv, dy: -40 / inv)
            for country in world where layout.drawsAllRegions || country.region == layout.region {
                let path = MapDrawing.makePath(layout.map.viewPolygons(for: country))
                guard path.boundingRect.intersects(visible) else { continue }
                let land = country.quizzable ? Theme.land : Theme.land.opacity(0.32)
                let border = country.quizzable ? Theme.border : Theme.border.opacity(0.35)
                mapContext.fill(path, with: .color(land), style: FillStyle(eoFill: true))
                mapContext.stroke(path, with: .color(border),
                                  style: StrokeStyle(lineWidth: 0.6 / inv, lineJoin: .round))
            }
        }
        .allowsHitTesting(false)
    }

    private func selectedFill(layout: ClickLayout, zoom: MapZoomState) -> some View {
        let names = selected
        return Canvas { context, size in
            var mapContext = context
            mapContext.beginMapZoom(zoom, size: size)
            for target in layout.targets where names.contains(target.name) {
                mapContext.fill(MapDrawing.makePath(target.polygons), with: .color(Theme.accentFill.opacity(0.72)),
                                style: FillStyle(eoFill: true))
            }
        }
        .allowsHitTesting(false)
    }

    private func hoverFill(layout: ClickLayout, name: String, zoom: MapZoomState, selected: Bool) -> some View {
        let color = selected ? Theme.hover : Theme.accentFill.opacity(0.45)
        return Canvas { context, size in
            var mapContext = context
            mapContext.beginMapZoom(zoom, size: size)
            for target in layout.targets where target.name == name {
                mapContext.fill(MapDrawing.makePath(target.polygons), with: .color(color),
                                style: FillStyle(eoFill: true))
            }
        }
        .allowsHitTesting(false)
    }

    private func pickDots(layout: ClickLayout, zoom: MapZoomState) -> some View {
        let names = selected
        return Canvas { context, size in
            var mapContext = context
            mapContext.beginMapZoom(zoom, size: size)
            let inv = max(zoom.scale, 0.001)
            for target in layout.targets {
                guard target.needsLeader, let anchor = target.anchor, let dot = target.dot else { continue }
                ClickDots.leader(from: anchor, to: dot, in: &mapContext, color: Theme.leader, scale: inv)
            }
            for target in layout.targets {
                guard let dot = target.dot else { continue }
                let circle = Path(ellipseIn: ClickDots.rect(at: dot, scale: inv))
                let fill = names.contains(target.name) ? Theme.accentFill : Theme.dotFill
                mapContext.fill(circle, with: .color(fill))
                mapContext.stroke(circle, with: .color(Theme.dotStroke), lineWidth: 1.5 / inv)
            }
        }
        .allowsHitTesting(false)
    }
}
