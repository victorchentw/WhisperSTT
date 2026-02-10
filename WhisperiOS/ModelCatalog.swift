import Foundation

struct BundledModel: Identifiable, Hashable {
    let id: String
    let displayName: String
    let bundleFolderName: String
}

enum NexaModelCatalog {
    static let bundleSubdirectory = "nexa"
    static let legacyBundleSubdirectory = "Models/nexa"
    static let models: [BundledModel] = [
        BundledModel(
            id: "parakeet-tdt-0.6b-v3-ane",
            displayName: "Parakeet TDT 0.6B v3 (ANE)",
            bundleFolderName: "parakeet-tdt-0.6b-v3-ane"
        )
    ]

    static func bundleURL(for model: BundledModel) -> URL? {
        if let url = Bundle.main.url(
            forResource: model.bundleFolderName,
            withExtension: nil,
            subdirectory: bundleSubdirectory
        ) {
            return url
        }

        if let url = Bundle.main.url(
            forResource: model.bundleFolderName,
            withExtension: nil,
            subdirectory: legacyBundleSubdirectory
        ) {
            return url
        }

        // Compatibility: allow users to place model files directly under bundle's "nexa" folder.
        if let root = Bundle.main.url(
            forResource: bundleSubdirectory,
            withExtension: nil
        ), directoryLooksLikeNexaModel(root) {
            return root
        }
        if let root = Bundle.main.url(
            forResource: legacyBundleSubdirectory,
            withExtension: nil
        ), directoryLooksLikeNexaModel(root) {
            return root
        }
        return nil
    }

    private static func directoryLooksLikeNexaModel(_ url: URL) -> Bool {
        let fm = FileManager.default
        let markerNames = ["nexa.manifest", "tokenizer.vocab", "parakeet_emb.npy"]
        if markerNames.contains(where: { fm.fileExists(atPath: url.appendingPathComponent($0).path) }) {
            return true
        }
        return fm.fileExists(atPath: url.appendingPathComponent("ParakeetEncoder.mlmodelc").path)
    }
}

enum RunAnywhereModelCatalog {
    static let bundleSubdirectory = "runanywhere"
    static let legacyBundleSubdirectory = "Models/runanywhere"
    static let models: [BundledModel] = [
        BundledModel(
            id: "whisper-tiny-onnx",
            displayName: "Whisper Tiny (ONNX)",
            bundleFolderName: "whisper-tiny-onnx"
        ),
        BundledModel(
            id: "whisper-base-onnx",
            displayName: "Whisper Base (ONNX)",
            bundleFolderName: "whisper-base-onnx"
        )
    ]

    static func bundleURL(for model: BundledModel) -> URL? {
        if let url = Bundle.main.url(
            forResource: model.bundleFolderName,
            withExtension: nil,
            subdirectory: bundleSubdirectory
        ) {
            return url
        }
        return Bundle.main.url(
            forResource: model.bundleFolderName,
            withExtension: nil,
            subdirectory: legacyBundleSubdirectory
        )
    }
}
