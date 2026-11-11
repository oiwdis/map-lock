import SwiftUI

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var countries: [String] = CustomSets.countries()
    @State private var original: [String] = CustomSets.countries()
    @State private var query = ""
    @State private var named: [NamedCustomSet] = CustomSets.namedSets()
    @State private var draftName = ""
    @State private var editingId: UUID?
    @State private var pickMode: CustomPickMode = .type
    @State private var mapFocus: CustomMapFocus = .world
    @State private var highlight = 0
    @State private var saving = false
    @State private var savingAsNew = false
    @State private var renaming = false
    @State private var confirmDelete = false
    @State private var keyMonitor: Any?
    @State private var keys = PickerKeys()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            HStack(spacing: Theme.Space.s3) {
                Button("Cancel") { cancel() }
                    .buttonStyle(AppButtonStyle(kind: .ghost, height: 32))
                VStack(alignment: .leading, spacing: Theme.Space.s1) {
                    Text("Custom countries")
                        .font(Theme.font(Theme.Size.lg, .bold))
                    Text(countLine)
                        .font(Theme.font(Theme.Size.sm))
                        .foregroundStyle(Theme.text2)
                }
                Spacer()
                savedMenu
                Button("Done") { finish() }
                    .buttonStyle(AppButtonStyle(kind: .primary, height: 32))
            }

            SegmentedChoice(
                selection: $pickMode,
                choices: [
                    SegmentChoice(value: CustomPickMode.type, title: "Search countries"),
                    SegmentChoice(value: CustomPickMode.map, title: "Pick on map"),
                ]
            )

            if pickMode == .type {
                typePicker
            } else {
                mapPicker
            }

            selectedChips
        }
        .padding(Theme.Space.s6)
        .frame(width: 720)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: pickMode)
        .background(PickerKeySync(keys: keys, countries: $countries, highlight: $highlight,
                                  mode: $pickMode, query: $query, suggestions: suggestions, close: cancel))
        .onAppear { installKeys() }
        .onDisappear { removeKeys() }
        .onChange(of: query) { _, _ in highlight = 0 }
        .alert("Save as…", isPresented: $saving) {
            TextField("Name, such as Middle East", text: $draftName)
            Button("Save") { saveNamed() }
            Button("Cancel", role: .cancel) { savingAsNew = false }
        } message: {
            Text("At least 2 countries.")
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $draftName)
            Button("Rename") { saveNamed() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this set?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteCurrent() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(currentSet?.name ?? "This saved set")
        }
    }

    private var countLine: String {
        if countries.count < 2 { return "Pick at least 2 countries." }
        return countries.count == 1 ? "1 country." : "\(countries.count) countries."
    }

    private var savedMenu: some View {
        Menu {
            if named.isEmpty {
                Button("No saved sets") {}
                    .disabled(true)
            } else {
                ForEach(named) { set in
                    Button(set.name) { load(set) }
                }
            }
            Divider()
            Button("Save as…") {
                draftName = ""
                savingAsNew = true
                saving = true
            }
            .disabled(countries.count < 2)
            Button("Rename") { renaming = true }
                .disabled(currentSet == nil)
            Button("Delete") { confirmDelete = true }
                .disabled(currentSet == nil)
        } label: {
            Text(currentSet?.name ?? "Saved sets")
                .font(Theme.font(Theme.Size.sm, .semibold))
                .lineLimit(1)
                .frame(maxWidth: 160, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var typePicker: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s3) {
            HStack(spacing: Theme.Space.s2) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.text3)
                TextField("Search by country name", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { addHighlighted() }
                if !query.isEmpty {
                    Button {
                        query = ""
                        highlight = 0
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.text3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear country search")
                }
            }
            .padding(.horizontal, Theme.Space.s3)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).fill(Theme.fill2))

            if !query.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        if suggestions.isEmpty {
                            Text("No matching countries. Try another name or choose from the map.")
                                .font(Theme.font(Theme.Size.sm))
                                .foregroundStyle(Theme.text3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Theme.Space.s3)
                        } else {
                            ForEach(Array(suggestions.enumerated()), id: \.element) { index, name in
                                suggestionRow(name, index: index)
                            }
                        }
                    }
                }
                .frame(height: min(240, CGFloat(max(suggestions.count, 1)) * 40))
                .background(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).fill(Theme.fill))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
            }

            Menu {
                ForEach(Region.allCases, id: \.self) { region in
                    Button(region.title) { addRegion(region) }
                }
            } label: {
                Text("Add all of")
                    .font(Theme.font(Theme.Size.sm, .semibold))
                    .frame(height: 32)
                    .padding(.horizontal, Theme.Space.s3)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func suggestionRow(_ name: String, index: Int) -> some View {
        let added = countries.contains(name)
        let active = index == highlight
        return Button {
            highlight = index
            if !added { add(name) }
        } label: {
            HStack(spacing: Theme.Space.s3) {
                Text(CountryFacts.flagEmoji(for: name) ?? "")
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(name)
                        .font(Theme.font(Theme.Size.body, .medium))
                        .foregroundStyle(Theme.text)
                    Text(continent(of: name))
                        .font(Theme.font(Theme.Size.xs))
                        .foregroundStyle(Theme.text3)
                }
                Spacer(minLength: Theme.Space.s2)
                if added {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, Theme.Space.s3)
            .frame(height: 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? Theme.fill2 : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                onToggle: toggle
            )
            .frame(height: 340)
            .id(mapFocus)
            .transition(.opacity)
            HStack(spacing: Theme.Space.s2) {
                Text(countries.count == 1 ? "1 selected" : "\(countries.count) selected")
                    .font(Theme.font(Theme.Size.sm, .medium))
                    .foregroundStyle(Theme.text2)
                    .monospacedDigit()
                Spacer(minLength: Theme.Space.s3)
                Button(mapFocus.selectTitle) { selectFocus() }
                    .buttonStyle(AppButtonStyle(kind: .ghost, height: 32))
                Button(mapFocus.clearTitle) { clearFocus() }
                    .buttonStyle(AppButtonStyle(kind: .ghost, height: 32))
                    .disabled(focusSelectionCount == 0)
            }
            .padding(.horizontal, Theme.Space.s3)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).fill(Theme.fill))
        }
        .animation(.easeOut(duration: 0.24), value: mapFocus)
    }

    private var selectedChips: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            if countries.isEmpty {
                Text("Type a country or pick on the map.")
                    .font(Theme.font(Theme.Size.sm))
                    .foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Theme.Space.s2)
            } else {
                ScrollView {
                    ChipFlow(spacing: Theme.Space.s2) {
                        ForEach(countries, id: \.self) { name in
                            HStack(spacing: Theme.Space.s1) {
                                Text(CountryFacts.flagEmoji(for: name) ?? "")
                                    .font(.system(size: 13))
                                Text(name)
                                    .font(Theme.font(Theme.Size.sm))
                                    .lineLimit(1)
                                Button { remove(name) } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .frame(width: 16, height: 16)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, Theme.Space.s2)
                            .padding(.vertical, Theme.Space.s1)
                            .background(Capsule().fill(Theme.fill2))
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        }
                    }
                    .padding(.bottom, Theme.Space.s2)
                }
                .frame(height: 120)
            }
            HStack(spacing: Theme.Space.s2) {
                Text(countries.count == 1 ? "1 country" : "\(countries.count) countries")
                    .font(Theme.font(Theme.Size.sm, .medium))
                    .foregroundStyle(Theme.text2)
                    .monospacedDigit()
                Spacer()
                Button("Clear all") {
                    countries = []
                    CustomSets.saveCountries([])
                }
                .buttonStyle(.plain)
                .font(Theme.font(Theme.Size.sm, .semibold))
                .foregroundStyle(countries.isEmpty ? Theme.text3 : Theme.accent)
                .disabled(countries.isEmpty)
            }
        }
        .animation(.easeOut(duration: 0.2), value: countries)
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
        CountrySearch.suggestions(query: query, in: CountryCatalog.all, excluding: [])
    }

    private var currentSet: NamedCustomSet? {
        if let editingId, let set = named.first(where: { $0.id == editingId }) { return set }
        return nil
    }

    private func continent(of name: String) -> String {
        CountryCatalog.all.first { $0.name == name }?.region.title ?? ""
    }

    private func installKeys() {
        guard keyMonitor == nil else { return }
        let keys = keys
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            keys.handle(event)
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func addHighlighted() {
        guard suggestions.indices.contains(highlight) else { return }
        let name = suggestions[highlight]
        if !countries.contains(name) { add(name) }
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
        let forceNew = savingAsNew
        savingAsNew = false
        guard !name.isEmpty, countries.count >= 2 else { return }
        let list = countries.sorted()
        if !forceNew, let id = editingId, let index = named.firstIndex(where: { $0.id == id }) {
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

    private func deleteCurrent() {
        guard let set = currentSet else { return }
        delete(set)
        draftName = ""
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

    /// Drops edits made in this sheet and puts the last saved set back.
    private func cancel() {
        countries = original
        CustomSets.saveCountries(original)
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
                            .fixedSize()
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
        if hovered != name { hovered = name }
    }

    private func tooltipPoint(_ pointer: CGPoint, in size: CGSize) -> CGPoint {
        let x = min(max(pointer.x + 64, 72), max(72, size.width - 72))
        let y = min(max(pointer.y - 20, 16), max(16, size.height - 16))
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
            let inv = max(zoom.scale, 0.001)
            for target in layout.targets where names.contains(target.name) {
                let path = MapDrawing.makePath(target.polygons)
                mapContext.fill(path, with: .color(Theme.accentFill.opacity(0.72)), style: FillStyle(eoFill: true))
                mapContext.stroke(path, with: .color(Theme.accentFill),
                                  style: StrokeStyle(lineWidth: 1.25 / inv, lineJoin: .round))
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

/// Holds the latest picker bindings so a key monitor can add a country or close the sheet.
final class PickerKeys {
    var countries: Binding<[String]> = .constant([])
    var highlight: Binding<Int> = .constant(0)
    var mode: Binding<CustomPickMode> = .constant(.type)
    var query: Binding<String> = .constant("")
    var suggestions: [String] = []
    var close: () -> Void = {}

    func handle(_ event: NSEvent) -> NSEvent? {
        let code = event.keyCode
        if code == 53 {
            close()
            return nil
        }
        guard mode.wrappedValue == .type else { return event }
        let count = suggestions.count
        if code == 125 {
            highlight.wrappedValue = count == 0 ? 0 : min(highlight.wrappedValue + 1, count - 1)
            return nil
        }
        if code == 126 {
            highlight.wrappedValue = max(highlight.wrappedValue - 1, 0)
            return nil
        }
        if code == 36 || code == 76 {
            addHighlighted()
            return nil
        }
        return event
    }

    private func addHighlighted() {
        let index = highlight.wrappedValue
        guard suggestions.indices.contains(index) else { return }
        let name = suggestions[index]
        var list = countries.wrappedValue
        guard !list.contains(name) else { return }
        list.append(name)
        list.sort()
        countries.wrappedValue = list
        query.wrappedValue = ""
        CustomSets.saveCountries(list)
    }
}

private struct PickerKeySync: View {
    let keys: PickerKeys
    var countries: Binding<[String]>
    var highlight: Binding<Int>
    var mode: Binding<CustomPickMode>
    var query: Binding<String>
    var suggestions: [String]
    var close: () -> Void

    var body: some View {
        let _ = apply()
        Color.clear.frame(width: 0, height: 0)
    }

    private func apply() {
        keys.countries = countries
        keys.highlight = highlight
        keys.mode = mode
        keys.query = query
        keys.suggestions = suggestions
        keys.close = close
    }
}

/// Wraps chips onto new lines inside a fixed width.
struct ChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 640
        let rows = rows(width: width, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in rows(width: bounds.width, subviews: subviews) {
            guard subviews.indices.contains(row.index) else { continue }
            subviews[row.index].place(
                at: CGPoint(x: bounds.minX + row.x, y: bounds.minY + row.y),
                proposal: ProposedViewSize(width: row.width, height: row.height)
            )
        }
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [(index: Int, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)] {
        var placed: [(index: Int, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            placed.append((index, x, y, size.width, size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return placed
    }
}
