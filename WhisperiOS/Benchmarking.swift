import Foundation

struct BenchmarkResult: Identifiable {
    let id = UUID()
    let engine: String
    let model: String
    let mode: String
    let text: String
    let latency: TimeInterval?
    let processing: TimeInterval?
    let audioDuration: TimeInterval?
    let realTimeFactor: Double?
    let wer: Double?
    let cer: Double?
    let error: String?
}

enum BenchmarkError: LocalizedError {
    case modelMissing(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing(let name):
            return "Model not found in app bundle: \(name)"
        }
    }
}

enum Benchmarking {
    static func wordErrorRate(reference: String, hypothesis: String) -> Double? {
        let ref = tokenizeWords(normalize(reference))
        let hyp = tokenizeWords(normalize(hypothesis))
        guard !ref.isEmpty else { return nil }
        let distance = levenshtein(ref, hyp)
        return Double(distance) / Double(ref.count)
    }

    static func charErrorRate(reference: String, hypothesis: String) -> Double? {
        let ref = Array(normalize(reference))
        let hyp = Array(normalize(hypothesis))
        guard !ref.isEmpty else { return nil }
        let distance = levenshtein(ref, hyp)
        return Double(distance) / Double(ref.count)
    }

    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let allowed = CharacterSet.letters.union(.decimalDigits).union(.whitespacesAndNewlines)
        let filtered = lowered.unicodeScalars.map { scalar -> Character in
            if allowed.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }
        let cleaned = String(filtered)
        let collapsed = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokenizeWords(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func levenshtein<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)

        for (i, aChar) in a.enumerated() {
            current[0] = i + 1
            for (j, bChar) in b.enumerated() {
                let cost = (aChar == bChar) ? 0 : 1
                current[j + 1] = min(
                    previous[j + 1] + 1,
                    current[j] + 1,
                    previous[j] + cost
                )
            }
            previous = current
        }
        return previous[b.count]
    }
}
