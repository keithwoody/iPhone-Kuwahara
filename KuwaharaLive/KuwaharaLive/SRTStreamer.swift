import Foundation
import Combine
import CoreVideo

// ─────────────────────────────────────────────────────────────────────────────
// SRT STREAMING — STUB (no dependency yet)
//
// HaishinKit's Logboard transitive dependency has a Package.swift incompatible
// with current Xcode toolchains. This stub keeps the project buildable so the
// camera + Metal pipeline can be tested on-device.
//
// When the HaishinKit issue is resolved (or a replacement SRT library is chosen),
// replace this stub with the real implementation. The public API below is the
// contract the rest of the app depends on.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class SRTStreamer: ObservableObject {
    @Published var statusMessage: String? = nil

    func connect(host: String, port: UInt16, camera: CameraManager) {
        statusMessage = "SRT not yet wired (stub) — targeting \(host):\(port)"
    }

    func disconnect() {
        statusMessage = nil
    }
}
