import Foundation
import WhisperKit

struct NexaStreamingStartConfig {
    let modelPath: String
    let config: NexaStreamingConfig
}

struct RunAnywhereStreamingStartConfig {
    let modelId: String
    let language: String
    let detectLanguage: Bool
    let chunkSeconds: Double
    let overlapSeconds: Double
}

enum STTStreamingStartConfig {
    case whisper(StreamingConfig)
    case nexa(NexaStreamingStartConfig)
    case runAnywhere(RunAnywhereStreamingStartConfig)
}

enum STTStreamingUpdate {
    case replaceText(String)
    case appendChunk(String)
}

enum STTStreamingConfigError: LocalizedError {
    case invalidConfig(engine: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfig(let engine):
            return "Invalid streaming config for \(engine)."
        }
    }
}

protocol STTStreamingEngine {
    var displayName: String { get }

    func prepareStreaming(config: STTStreamingStartConfig) async throws
    func startStreaming(
        config: STTStreamingStartConfig,
        onUpdate: @escaping (STTStreamingUpdate) -> Void
    ) async throws
    func stopStreaming() async
}
