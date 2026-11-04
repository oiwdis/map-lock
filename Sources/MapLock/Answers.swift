import Foundation

/// Other names people use for a country. All of these count as correct.
let alternateNames: [String: [String]] = [
    "Côte d'Ivoire": ["Ivory Coast", "Cote d'Ivoire", "Cote dIvoire"],
    "Democratic Republic of the Congo": [
        "DRC", "DR Congo", "D.R. Congo", "Dem. Rep. Congo", "Dem Rep Congo",
        "Democratic Republic of Congo", "Congo-Kinshasa", "Congo Kinshasa", "Zaire",
    ],
    "Republic of the Congo": [
        "Congo", "Republic of Congo", "Congo Republic", "Congo-Brazzaville",
        "Congo Brazzaville", "ROC",
    ],
    "Western Sahara": ["W. Sahara", "W Sahara", "Sahrawi Republic", "SADR", "Sahrawi Arab Democratic Republic"],
    "Myanmar": ["Burma"],
    "Eswatini": ["Swaziland", "eSwatini", "Kingdom of Eswatini"],
    "Czechia": ["Czech Republic"],
    "Timor-Leste": ["East Timor", "Timor Leste"],
    "North Macedonia": ["Macedonia"],
    "United States": ["USA", "US", "U.S.", "U.S.A.", "United States of America", "America"],
    "United Kingdom": ["UK", "U.K.", "Great Britain", "Britain"],
    "United Arab Emirates": ["UAE", "Emirates"],
    "North Korea": ["DPRK", "Democratic People's Republic of Korea"],
    "South Korea": ["Korea", "Republic of Korea"],
    "Gambia": ["The Gambia"],
    "Bahamas": ["The Bahamas"],
    "Cabo Verde": ["Cape Verde"],
    "Turkey": ["Türkiye", "Turkiye"],
    "Palestine": ["State of Palestine", "Palestinian Territories"],
    "Central African Republic": ["CAR", "Central African Rep."],
    "Laos": ["Lao PDR", "Lao"],
    "Vietnam": ["Viet Nam"],
    "Russia": ["Russian Federation"],
    "Brunei": ["Brunei Darussalam"],
    "Sao Tome and Principe": ["São Tomé and Príncipe", "Sao Tome", "Sao Tome & Principe"],
    "Vatican City": ["Vatican", "Holy See"],
    "Micronesia": ["Federated States of Micronesia", "FSM"],
    "Netherlands": ["Holland", "The Netherlands"],
    "Bosnia and Herzegovina": ["Bosnia", "Bosnia-Herzegovina", "Bosnia & Herzegovina"],
    "Equatorial Guinea": ["Eq. Guinea"],
    "South Sudan": ["S. Sudan"],
    "Dominican Republic": ["Dominican Rep."],
    "Saint Kitts and Nevis": ["St Kitts and Nevis", "St. Kitts and Nevis", "St Kitts"],
    "Saint Lucia": ["St Lucia", "St. Lucia"],
    "Saint Vincent and the Grenadines": ["St Vincent and the Grenadines", "St Vincent", "Saint Vincent"],
    "Trinidad and Tobago": ["Trinidad"],
    "Antigua and Barbuda": ["Antigua"],
    "Guinea-Bissau": ["Guinea Bissau"],
    "Taiwan": ["Chinese Taipei"],
    "Kyrgyzstan": ["Kyrgyz Republic"],
    "Moldova": ["Republic of Moldova"],
    "Solomon Islands": ["Solomons"],
    "Marshall Islands": ["Marshalls"],
]

enum AnswerChecker {
    /// Lowercase, no accents, no punctuation, single spaces, "st" becomes "saint",
    /// "&" becomes "and", and a leading "the" is dropped.
    static func normalize(_ text: String) -> String {
        var s = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        s = s.lowercased()
        s = s.replacingOccurrences(of: "&", with: " and ")
        // Apostrophes and dots join letters ("d'ivoire" -> "divoire", "u.s." -> "us").
        for mark in ["'", "\u{2019}", "\u{2018}", "`", "."] {
            s = s.replacingOccurrences(of: mark, with: "")
        }
        var cleaned = ""
        for scalar in s.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                cleaned.unicodeScalars.append(scalar)
            } else {
                cleaned.append(" ")
            }
        }
        var words = cleaned.split(separator: " ").map(String.init)
        words = words.map { $0 == "st" ? "saint" : $0 }
        if words.first == "the" && words.count > 1 { words.removeFirst() }
        return words.joined(separator: " ")
    }

    /// Every accepted spelling for a country, already normalized.
    static func acceptedForms(of name: String) -> Set<String> {
        var forms: Set<String> = [normalize(name)]
        for alt in alternateNames[name] ?? [] {
            forms.insert(normalize(alt))
        }
        forms.remove("")
        return forms
    }

    enum Result: Equatable {
        case correct
        case closeEnough   // small typo, still counts
        case wrong
    }

    /// Checks a typed answer against the target. `allNames` is used so a real
    /// different country never counts as a typo of the target.
    static func check(_ typed: String, target: String, allNames: [String]) -> Result {
        let guess = normalize(typed)
        if guess.isEmpty { return .wrong }

        let targetForms = acceptedForms(of: target)
        if targetForms.contains(guess) { return .correct }

        // Exactly another country's name? Then it's wrong, not a typo.
        for other in allNames where other != target {
            if acceptedForms(of: other).contains(guess) { return .wrong }
        }

        // Small typo allowed on longer names.
        let allowed: Int
        switch guess.count {
        case 0..<5: allowed = 0
        case 5..<9: allowed = 1
        default: allowed = 2
        }
        if allowed == 0 { return .wrong }

        let bestTarget = targetForms.map { editDistance(guess, $0) }.min() ?? Int.max
        if bestTarget > allowed { return .wrong }

        // Make sure no other country is just as close.
        for other in allNames where other != target {
            for form in acceptedForms(of: other) where editDistance(guess, form) <= bestTarget {
                return .wrong
            }
        }
        return .closeEnough
    }

    /// Classic Levenshtein distance.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }
}
