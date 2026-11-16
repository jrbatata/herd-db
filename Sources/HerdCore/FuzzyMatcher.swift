import Foundation

/// Fuzzy matcher used by "Abrir Qualquer Coisa".
///
/// Syntax:
/// - `^termo` exige que o nome comece com o termo;
/// - `termo$` exige que o nome termine com o termo;
/// - `^termo$` exige o nome exato;
/// - sem âncoras, as letras precisam aparecer na ordem (subsequência).
///
/// Vários termos separados por espaço precisam casar todos. O resultado é uma
/// pontuação maior para melhores correspondências, ou `nil` quando não casa.
public enum FuzzyMatcher {
    public static func score(_ pattern: String, in candidate: String) -> Int? {
        let raw = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return 0 }

        var text = raw
        let anchoredStart = text.hasPrefix("^")
        if anchoredStart { text.removeFirst() }

        var anchoredEnd = false
        if text.hasSuffix("$"), !text.isEmpty {
            anchoredEnd = true
            text.removeLast()
        }

        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return 0 }

        if anchoredStart && anchoredEnd {
            return candidate.compare(text, options: .caseInsensitive) == .orderedSame ? 1_000 : nil
        }
        if anchoredStart {
            return candidate.range(of: text, options: [.caseInsensitive, .anchored]) != nil ? 900 : nil
        }
        if anchoredEnd {
            return candidate.lowercased().hasSuffix(text.lowercased()) ? 900 : nil
        }

        let terms = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return 0 }

        var total = 0
        for term in terms {
            guard let score = fuzzyScore(term, candidate) else { return nil }
            total += score
        }
        return total
    }

    public static func matches(_ pattern: String, in candidate: String) -> Bool {
        score(pattern, in: candidate) != nil
    }

    private static func fuzzyScore(_ pattern: String, _ candidate: String) -> Int? {
        let needle = Array(pattern.lowercased())
        let haystack = Array(candidate.lowercased())
        guard !needle.isEmpty else { return 0 }
        guard needle.count <= haystack.count else { return nil }

        let original = Array(candidate)
        var score = 0
        var needleIndex = 0
        var lastMatch = -2

        for index in haystack.indices {
            guard needleIndex < needle.count else { break }
            guard haystack[index] == needle[needleIndex] else { continue }

            score += 10
            if index == lastMatch + 1 { score += 15 }
            if isBoundary(original, at: index) { score += 20 }

            lastMatch = index
            needleIndex += 1
        }

        guard needleIndex == needle.count else { return nil }
        // Nomes mais curtos ganham quando a correspondência é equivalente.
        score -= haystack.count / 4
        return max(score, 1)
    }

    private static func isBoundary(_ characters: [Character], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        if previous == " " || previous == "_" || previous == "." || previous == "/" || previous == "-" {
            return true
        }
        return previous.isLowercase && characters[index].isUppercase
    }
}
