package com.whisperandroid

object SherpaOnnxModelCatalog {
    val models = listOf(
        EngineModel(
            id = "whisper-tiny-sherpa",
            displayName = "Whisper Tiny (Sherpa ONNX)",
            assetFolderOrFile = "models/whisper/tiny"
        )
    )
}

object NexaModelCatalog {
    val models = listOf(
        EngineModel(
            id = "nexa-whisper-tiny-cpu",
            displayName = "Whisper Tiny (Nexa whisper_cpp)",
            assetFolderOrFile = "models/nexa/whisper/ggml-tiny.bin"
        ),
        EngineModel(
            id = "nexa-whisper-base-cpu",
            displayName = "Whisper Base (Nexa whisper_cpp)",
            assetFolderOrFile = "models/nexa/whisper/ggml-base.bin"
        )
    )
}

object RunAnywhereModelCatalog {
    val models = listOf(
        EngineModel(
            id = "whisper-tiny-onnx",
            displayName = "Whisper Tiny (ONNX)",
            assetFolderOrFile = "models/runanywhere/whisper-tiny-onnx"
        ),
        EngineModel(
            id = "whisper-base-onnx",
            displayName = "Whisper Base (ONNX)",
            assetFolderOrFile = "models/runanywhere/whisper-base-onnx"
        )
    )
}

object BenchmarkClipCatalog {
    val clips = listOf(
        BenchmarkClip(
            id = "earnings22_clip_1",
            displayName = "Earnings22 Clip 1 (~60s)",
            audioAssetPath = "benchmark-clips/earnings22_1_4482311_3_62.wav",
            transcriptAssetPath = "benchmark-clips/earnings22_1_4482311_3_62.txt"
        ),
        BenchmarkClip(
            id = "earnings22_clip_2",
            displayName = "Earnings22 Clip 2 (~64s)",
            audioAssetPath = "benchmark-clips/earnings22_2_4482249_1600_1664.wav",
            transcriptAssetPath = "benchmark-clips/earnings22_2_4482249_1600_1664.txt"
        ),
        BenchmarkClip(
            id = "earnings22_clip_3",
            displayName = "Earnings22 Clip 3 (~60s)",
            audioAssetPath = "benchmark-clips/earnings22_3_4483589_261_321.wav",
            transcriptAssetPath = "benchmark-clips/earnings22_3_4483589_261_321.txt"
        ),
        BenchmarkClip(
            id = "fleurs_ja_clip_4",
            displayName = "FLEURS Japanese Clip 4 (~15s)",
            audioAssetPath = "benchmark-clips/fleurs_ja_1837_clip4.wav",
            transcriptAssetPath = "benchmark-clips/fleurs_ja_1837_clip4.txt"
        ),
        BenchmarkClip(
            id = "fleurs_zh_clip_5",
            displayName = "FLEURS Chinese Clip 5 (~14s)",
            audioAssetPath = "benchmark-clips/fleurs_zh_1883_clip5.wav",
            transcriptAssetPath = "benchmark-clips/fleurs_zh_1883_clip5.txt"
        ),
        BenchmarkClip(
            id = "fleurs_zh_en_mix_clip_6",
            displayName = "FLEURS Chinese-English Mix Clip 6 (~14s)",
            audioAssetPath = "benchmark-clips/fleurs_zh_en_mix_1805_1830_clip6.wav",
            transcriptAssetPath = "benchmark-clips/fleurs_zh_en_mix_1805_1830_clip6.txt"
        )
    )
}
