import ONNXRuntime
import RunAnywhere
import SwiftUI

@main
struct WhisperiOSApp: App {
    init() {
        Task { @MainActor in
            ONNX.register()
            do {
                try RunAnywhere.initialize()
            } catch {
                print("[WhisperiOS] RunAnywhere init failed: \(error.localizedDescription)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
