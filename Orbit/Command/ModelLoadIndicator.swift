import Foundation

/// Small shared signal for the UI: whether the local model is still being
/// prepared (downloaded on first launch, then loaded from disk) and how far
/// along it is. `MLXResolver` updates it; the view shows a quiet label while it's
/// preparing. On Foundation Models devices this never turns on, since there is
/// nothing to download.
@MainActor
@Observable
final class ModelLoadIndicator {
    static let shared = ModelLoadIndicator()
    private init() {}

    private(set) var isPreparing = false
    private(set) var progress = 0.0   // 0…1

    func begin() {
        isPreparing = true
        progress = 0
    }

    func update(_ fraction: Double) {
        progress = fraction
    }

    func finish() {
        isPreparing = false
    }
}
