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
        .frame(minWidth: 480, minHeight: 420)
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
