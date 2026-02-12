import Foundation

struct BenchmarkClip: Identifiable, Hashable {
    let id: String
    let displayName: String
    let audioFileName: String
    let transcriptFileName: String
}

enum BenchmarkClipCatalog {
    static let bundleSubdirectory = "benchmark-clips"
    static let legacyBundleSubdirectory = "Models/benchmark-clips"
    static let clips: [BenchmarkClip] = [
        BenchmarkClip(
            id: "earnings22_clip_1",
            displayName: "Earnings22 Clip 1 (~60s)",
            audioFileName: "earnings22_1_4482311_3_62.wav",
            transcriptFileName: "earnings22_1_4482311_3_62.txt"
        ),
        BenchmarkClip(
            id: "earnings22_clip_2",
            displayName: "Earnings22 Clip 2 (~64s)",
            audioFileName: "earnings22_2_4482249_1600_1664.wav",
            transcriptFileName: "earnings22_2_4482249_1600_1664.txt"
        ),
        BenchmarkClip(
            id: "earnings22_clip_3",
            displayName: "Earnings22 Clip 3 (~60s)",
            audioFileName: "earnings22_3_4483589_261_321.wav",
            transcriptFileName: "earnings22_3_4483589_261_321.txt"
        ),
        BenchmarkClip(
            id: "fleurs_ja_clip_4",
            displayName: "FLEURS Japanese Clip 4 (~15s)",
            audioFileName: "fleurs_ja_1837_clip4.wav",
            transcriptFileName: "fleurs_ja_1837_clip4.txt"
        ),
        BenchmarkClip(
            id: "fleurs_zh_clip_5",
            displayName: "FLEURS Chinese Clip 5 (~14s)",
            audioFileName: "fleurs_zh_1883_clip5.wav",
            transcriptFileName: "fleurs_zh_1883_clip5.txt"
        ),
        BenchmarkClip(
            id: "fleurs_zh_en_mix_clip_6",
            displayName: "FLEURS Chinese-English Mix Clip 6 (~14s)",
            audioFileName: "fleurs_zh_en_mix_1805_1830_clip6.wav",
            transcriptFileName: "fleurs_zh_en_mix_1805_1830_clip6.txt"
        )
    ]

    static func audioURL(for clip: BenchmarkClip) -> URL? {
        if let url = Bundle.main.url(
            forResource: clip.audioFileName,
            withExtension: nil,
            subdirectory: bundleSubdirectory
        ) {
            return url
        }
        return Bundle.main.url(
            forResource: clip.audioFileName,
            withExtension: nil,
            subdirectory: legacyBundleSubdirectory
        )
    }

    static func transcriptText(for clip: BenchmarkClip) -> String? {
        guard let url = transcriptURL(for: clip) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func transcriptURL(for clip: BenchmarkClip) -> URL? {
        if let url = Bundle.main.url(
            forResource: clip.transcriptFileName,
            withExtension: nil,
            subdirectory: bundleSubdirectory
        ) {
            return url
        }
        return Bundle.main.url(
            forResource: clip.transcriptFileName,
            withExtension: nil,
            subdirectory: legacyBundleSubdirectory
        )
    }
}

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
