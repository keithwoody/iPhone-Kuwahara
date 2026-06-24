import Foundation
import Combine
import CoreVideo
import HaishinKit
import AVFoundation

@MainActor
final class SRTStreamer: ObservableObject {
    @Published var statusMessage: String?

    private var connection: SRTConnection?
    private var stream: SRTStream?

    func connect(host: String, port: UInt16, camera: CameraManager) {
        let conn = SRTConnection()
        let str = SRTStream(connection: conn)
        self.connection = conn
        self.stream = str

        str.videoSettings = VideoCodecSettings(
            videoSize: CGSize(width: 1920, height: 1080),
            profileLevel: kVTProfileLevel_H264_High_AutoLevel as String,
            bitRate: 6_000_000,
            maxKeyFrameIntervalDuration: 2,
            scalingMode: .trim,
            allowFrameReordering: false,
            isHardwareEncoderEnabled: true,
            H264: .init(),
            HEVC: nil
        )

        camera.onFrame = { [weak str] pixelBuffer in
            let timestamp = CMClockGetTime(CMClockGetHostTimeClock())
            str?.appendPixelBuffer(pixelBuffer, withPresentationTime: timestamp)
        }

        Task {
            do {
                try await conn.connect(URI("srt://\(host):\(port)"))
                await str.publish()
                statusMessage = "Streaming to \(host):\(port)"
            } catch {
                statusMessage = "Connection failed: \(error.localizedDescription)"
            }
        }
    }

    func disconnect() {
        Task {
            await stream?.close()
            await connection?.close()
            stream = nil
            connection = nil
            statusMessage = nil
        }
    }
}
