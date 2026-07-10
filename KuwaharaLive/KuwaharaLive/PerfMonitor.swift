import Foundation
import Combine
import QuartzCore

/// Collects real-time performance samples from the render/stream path and
/// publishes them for the on-screen HUD.
///
/// Samples arrive on Metal's completion thread (a background queue), one per
/// rendered frame. The `@Published` values that SwiftUI reads are recomputed on
/// the main thread ~4×/sec — we deliberately *don't* publish on every frame, or
/// we'd thrash SwiftUI 30 times a second for numbers a human reads a few times a
/// second.
///
/// Swift/iOS notes (vs. Rails):
/// - `ObservableObject` + `@Published` ≈ a reactive view model: SwiftUI
///   re-renders any view observing this object when a published value changes.
/// - Publishing to `@Published` must happen on the main thread (it drives UI).
///   Frames, though, are produced on a background thread — so we accumulate
///   under a lock there and only *read + reset* on the main thread in `flush()`.
final class PerfMonitor: ObservableObject {
    @Published private(set) var gpuFrameTimeMs: Double = 0
    @Published private(set) var previewFPS: Double = 0
    @Published private(set) var streamFPS: Double = 0
    @Published private(set) var thermalState: ProcessInfo.ThermalState =
        ProcessInfo.processInfo.thermalState

    // Accumulators written from the render thread, drained on main. Guarded by
    // `lock` because two threads touch them.
    private let lock = NSLock()
    private var gpuTimeSumMs: Double = 0
    private var previewFrames: Int = 0
    private var streamFrames: Int = 0

    private var flushTimer: DispatchSourceTimer?
    private var thermalObserver: NSObjectProtocol?
    private var lastFlush = CACurrentMediaTime()

    init() {
        // Thermal changes are infrequent; observe and mirror onto main.
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.thermalState = ProcessInfo.processInfo.thermalState
        }

        // A GCD timer pinned to the main queue: its handler runs on the main
        // thread, so touching @Published inside `flush()` is safe.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        flushTimer = timer
    }

    deinit {
        flushTimer?.cancel()
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
    }

    /// Called once per rendered frame from Metal's completion handler
    /// (background thread). `streamed` is true when this frame was also handed
    /// off to the SRT stream.
    func recordFrame(gpuMs: Double, streamed: Bool) {
        lock.lock()
        gpuTimeSumMs += gpuMs
        previewFrames += 1
        if streamed { streamFrames += 1 }
        lock.unlock()
    }

    /// Runs on the main thread. Converts the accumulated counts into averaged,
    /// per-second figures and resets for the next window.
    private func flush() {
        let now = CACurrentMediaTime()
        let elapsed = now - lastFlush
        lastFlush = now
        guard elapsed > 0 else { return }

        lock.lock()
        let gpuSum = gpuTimeSumMs
        let preview = previewFrames
        let stream = streamFrames
        gpuTimeSumMs = 0
        previewFrames = 0
        streamFrames = 0
        lock.unlock()

        gpuFrameTimeMs = preview > 0 ? gpuSum / Double(preview) : 0
        previewFPS = Double(preview) / elapsed
        streamFPS = Double(stream) / elapsed
    }
}
