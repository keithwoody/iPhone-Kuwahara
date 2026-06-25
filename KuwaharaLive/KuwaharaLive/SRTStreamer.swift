import AVFoundation
import CoreMedia
import CoreVideo
import HaishinKit
import SRTHaishinKit
import VideoToolbox

@MainActor
final class SRTStreamer: ObservableObject {
    @Published var statusMessage: String? = nil

    var frameRate: Int = 30

    private let connection = SRTConnection()
    private var srtStream: SRTStream?

    func connect(host: String, port: UInt16, camera: CameraManager) {
        statusMessage = "Connecting to \(host):\(port)…"
        let stream = SRTStream(connection: connection)
        srtStream = stream

        let capturedRate = frameRate
        let capturedSize = camera.currentStreamSize
        Task {
            try? await stream.setVideoSettings(VideoCodecSettings(
                videoSize: capturedSize,
                bitRate: 3_000_000,
                profileLevel: kVTProfileLevel_H264_Baseline_AutoLevel as String,
                maxKeyFrameIntervalDuration: 2,
                isLowLatencyRateControlEnabled: true,
                expectedFrameRate: Double(capturedRate)
            ))
            await stream.setExpectedMedias([.video])

            do {
                guard let url = URL(string: "srt://\(host):\(port)") else { return }
                try await connection.connect(url)
                await stream.publish()
                statusMessage = "Streaming → \(host):\(port)"

                // Wire the Metal completion handler to feed frames into the stream.
                // Capture rate (not self) so the closure is safe on any thread.
                camera.previewView?.onProcessedFrame = { pixelBuffer, pts in
                    SRTStreamer.submitFrame(pixelBuffer, at: pts, frameRate: capturedRate, to: stream)
                }
            } catch {
                statusMessage = "Failed: \(error.localizedDescription)"
            }
        }
    }

    func disconnect() {
        srtStream = nil
        Task {
            await connection.close()
            statusMessage = nil
        }
    }

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
