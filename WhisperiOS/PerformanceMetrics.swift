import Foundation

struct PerformanceMetrics: Identifiable {
    enum Operation: String {
        case stt = "STT"
        case tts = "TTS"
    }

    let id = UUID()
    let operation: Operation
    let latencySeconds: TimeInterval?
    let processingSeconds: TimeInterval?
    let audioDurationSeconds: TimeInterval?
    let realTimeFactor: Double?
    let capturedAt: Date

    static func stt(
        processing: TimeInterval,
        audioDuration: TimeInterval,
        latency: TimeInterval,
        realTimeFactor: Double? = nil
    ) -> PerformanceMetrics {
        let rtf = realTimeFactor ?? (audioDuration > 0 ? (processing / audioDuration) : nil)
        return PerformanceMetrics(
            operation: .stt,
            latencySeconds: latency,
            processingSeconds: processing,
            audioDurationSeconds: audioDuration,
            realTimeFactor: rtf,
            capturedAt: Date()
        )
    }

    static func tts(latency: TimeInterval, total: TimeInterval) -> PerformanceMetrics {
        return PerformanceMetrics(
            operation: .tts,
            latencySeconds: latency,
            processingSeconds: total,
            audioDurationSeconds: total,
            realTimeFactor: nil,
            capturedAt: Date()
        )
    }
}
