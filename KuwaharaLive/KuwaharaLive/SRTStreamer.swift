import AVFoundation
import Combine
import CoreMedia
import CoreVideo
import HaishinKit
import SRTHaishinKit
import VideoToolbox

@MainActor
final class SRTStreamer: ObservableObject {

    /// The streaming lifecycle as an explicit state machine. Replaces the old
    /// free-text status string so the UI can render each state precisely.
    enum State: Equatable {
        case idle
        case connecting
        case live
        case reconnecting(attempt: Int)
        case failed(String)
    }

    /// Live SRT send stats, polled ~1×/sec while streaming.
    struct Health: Equatable {
        var mbps: Double
        var drops: Int
        var retransmits: Int
        var pktsSent: Int
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var health: Health?

    var frameRate: Int = 30

    // Reconnect policy: give up after 5 attempts OR 30s (whichever comes first).
    private let maxAttempts = 5
    private let maxDuration: TimeInterval = 30
    private let retryDelay: TimeInterval = 3
    // Consider the link dead after ~3 consecutive 1s polls with no packets sent.
    private let stallPolls = 3

    private let connection = SRTConnection()
    private var srtStream: SRTStream?
    private var lifecycleTask: Task<Void, Never>?
    private weak var boundCamera: CameraManager?
    private var hasConnected = false

    private enum StreamError: Error { case badURL }

    // MARK: - Public control

    func connect(host: String, port: UInt16, camera: CameraManager) {
        // Reset any prior session without racing a fire-and-forget close — the
        // per-attempt close() inside establish() tears the socket down in order.
        lifecycleTask?.cancel()
        boundCamera?.previewView?.onProcessedFrame = nil
        boundCamera = camera
        hasConnected = false
        health = nil
        lifecycleTask = Task { [weak self] in
            await self?.runLifecycle(host: host, port: port, camera: camera)
        }
    }

    func disconnect() {
        lifecycleTask?.cancel()
        lifecycleTask = nil
        boundCamera?.previewView?.onProcessedFrame = nil
        let conn = connection
        Task { await conn.close() }
        srtStream = nil
        state = .idle
        health = nil
        hasConnected = false
    }

    // MARK: - Lifecycle

    /// Owns the whole session: (re)connect with retries, go live, watch for a
    /// stall, and loop back to reconnect when the link drops — until the user
    /// stops (task cancelled) or a reconnect budget is exhausted.
    private func runLifecycle(host: String, port: UInt16, camera: CameraManager) async {
        while !Task.isCancelled {
            let established = await connectWithRetries(host: host, port: port, camera: camera)
            if Task.isCancelled { return }
            guard established else {
                boundCamera?.previewView?.onProcessedFrame = nil
                state = .failed("Couldn't reach \(host):\(port)")
                return
            }

            state = .live
            hasConnected = true

            let dropped = await monitorUntilStall()
            if Task.isCancelled { return }
            if !dropped { return }
            // Link died → loop; the next connectWithRetries reports .reconnecting.
        }
    }

    /// One connect "episode", bounded by the 5-try / 30-second reconnect budget.
    private func connectWithRetries(host: String, port: UInt16, camera: CameraManager) async -> Bool {
        let start = Date()
        var attempt = 0
        while !Task.isCancelled {
            attempt += 1
            state = (!hasConnected && attempt == 1) ? .connecting : .reconnecting(attempt: attempt)
            do {
                try await establish(host: host, port: port, camera: camera)
                return true
            } catch {
                if Task.isCancelled { return false }
                let exhausted = attempt >= maxAttempts
                    || Date().timeIntervalSince(start) >= maxDuration
                if exhausted { return false }
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            }
        }
        return false
    }

    /// Builds a fresh connection + stream and starts publishing. Throws if the
    /// SRT handshake fails (wrong host/port, receiver not listening).
    private func establish(host: String, port: UInt16, camera: CameraManager) async throws {
        // Reuse the single connection. close() leaves a fresh socket, so it's
        // built to be reconnected; it no-ops on the first connect (uri == nil).
        await connection.close()
        let stream = SRTStream(connection: connection)
        srtStream = stream

        let rate = frameRate
        try? await stream.setVideoSettings(VideoCodecSettings(
            videoSize: camera.currentStreamSize,
            bitRate: 3_000_000,
            profileLevel: kVTProfileLevel_H264_Baseline_AutoLevel as String,
            maxKeyFrameIntervalDuration: 2,
            isLowLatencyRateControlEnabled: true,
            expectedFrameRate: Double(rate)
        ))
        await stream.setExpectedMedias([.video])

        guard let url = URL(string: "srt://\(host):\(port)") else { throw StreamError.badURL }
        try await connection.connect(url)
        await stream.publish()

        // Wire the Metal completion handler to feed frames into the stream.
        // Capture rate (not self) so the closure is safe on any thread.
        camera.previewView?.onProcessedFrame = { pixelBuffer, pts in
            SRTStreamer.submitFrame(pixelBuffer, at: pts, frameRate: rate, to: stream)
        }
    }

    /// Polls SRT send stats ~1×/sec, publishing Health and returning `true` when
    /// the link has stalled (no packets sent for `stallPolls` seconds), or
    /// `false` if the task was cancelled (user stopped).
    private func monitorUntilStall() async -> Bool {
        var lastPkt: Int64 = -1
        var stalls = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return false }
            guard let perf = await connection.performanceData else { continue }

            health = Health(mbps: perf.mbpsSendRate,
                            drops: Int(perf.pktSndDropTotal),
                            retransmits: Int(perf.pktRetransTotal),
                            pktsSent: Int(perf.pktSentTotal))

            if perf.pktSentTotal > lastPkt {
                stalls = 0
                lastPkt = perf.pktSentTotal
            } else if lastPkt > 0 {
                // Only count stalls once real traffic has started (avoids a false
                // drop while the encoder spins up right after connecting).
                stalls += 1
                if stalls >= stallPolls { return true }
            }
        }
        return false
    }

    // MARK: - Frame submission

    // nonisolated so it can be called from the Metal completion handler
    // (a background queue) without crossing through MainActor.
    private nonisolated static func submitFrame(
        _ pixelBuffer: CVPixelBuffer,
        at pts: CMTime,
        frameRate: Int,
        to stream: SRTStream
    ) {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid)
        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc)
        guard let fd = formatDesc else { return }
        var sb: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: nil,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fd,
            sampleTiming: &timing,
            sampleBufferOut: &sb)
        guard let sampleBuffer = sb else { return }
        Task { await stream.append(sampleBuffer) }
    }
}
