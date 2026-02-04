import AVFoundation

final class AudioRecorder: NSObject {
    private var recorder: AVAudioRecorder?
    private var currentURL: URL?

    static func configureSessionForVoiceProcessing() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.duckOthers, .defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        )
        try session.setPreferredSampleRate(16_000)
        try? session.setPreferredInputNumberOfChannels(1)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    static func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    var isRecording: Bool {
        recorder?.isRecording ?? false
    }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func startRecording() throws {
        try Self.configureSessionForVoiceProcessing()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording_\(Int(Date().timeIntervalSince1970))")
            .appendingPathExtension("wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]

        recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder?.prepareToRecord()
        recorder?.record()
        currentURL = url
    }

    func stopRecording() -> URL? {
        recorder?.stop()
        recorder = nil
        let url = currentURL
        currentURL = nil
        Self.deactivateSession()
        return url
    }
}
