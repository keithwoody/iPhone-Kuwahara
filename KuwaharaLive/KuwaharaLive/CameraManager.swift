import AVFoundation
import CoreVideo
import Combine

struct CameraSource: Identifiable, Equatable {
    let id: String
    let device: AVCaptureDevice
    let label: String

    static func discover() -> [CameraSource] {
        var sources: [CameraSource] = []

        let backOrder: [AVCaptureDevice.DeviceType] = [
            .builtInUltraWideCamera,
            .builtInWideAngleCamera,
            .builtInTelephotoCamera,
        ]
        let backDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: backOrder, mediaType: .video, position: .back
        ).devices.sorted {
            (backOrder.firstIndex(of: $0.deviceType) ?? .max) <
            (backOrder.firstIndex(of: $1.deviceType) ?? .max)
        }
        for device in backDevices {
            let label: String
            switch device.deviceType {
            case .builtInUltraWideCamera: label = "0.5×"
            case .builtInWideAngleCamera: label = "1×"
            case .builtInTelephotoCamera: label = "Tele"
            default:                      label = device.localizedName
            }
            sources.append(CameraSource(id: device.uniqueID, device: device, label: label))
        }

        if let front = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .front
        ).devices.first {
            sources.append(CameraSource(id: front.uniqueID, device: front, label: "Front"))
        }

        return sources
    }
}

final class CameraManager: NSObject, ObservableObject {
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "camera.frames", qos: .userInteractive)

    @Published var availableSources: [CameraSource] = []
    @Published var currentSource: CameraSource?

    weak var previewView: MetalPreviewView?
    var onFrame: ((CVPixelBuffer) -> Void)?

    override init() {
        super.init()
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)

        availableSources = CameraSource.discover()
        let defaultSource = availableSources.first(where: {
            $0.device.deviceType == .builtInWideAngleCamera && $0.device.position == .back
        }) ?? availableSources.first
        configure(with: defaultSource)
    }

    func switchTo(_ source: CameraSource) {
        configure(with: source)
    }

    private func configure(with source: CameraSource?) {
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080

        for input in session.inputs {
            if let di = input as? AVCaptureDeviceInput, di.device.hasMediaType(.video) {
                session.removeInput(di)
            }
        }

        if let source,
           let input = try? AVCaptureDeviceInput(device: source.device),
           session.canAddInput(input) {
            session.addInput(input)
            currentSource = source
        }

        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        if let connection = videoOutput.connection(with: .video) {
            if #available(iOS 17.0, *) {
                connection.videoRotationAngle = 90
            } else {
                connection.videoOrientation = .portrait
            }
        }

        session.commitConfiguration()

        // Pin to 30 fps after committing so the device has an active format.
        // The Kuwahara compute shader is expensive; 60 fps halves the GPU budget per frame.
        if let device = source?.device, (try? device.lockForConfiguration()) != nil {
            let fps30 = CMTime(value: 1, timescale: 30)
            device.activeVideoMinFrameDuration = fps30
            device.activeVideoMaxFrameDuration = fps30
            device.unlockForConfiguration()
        }
    }

    func start() {
        guard AVCaptureDevice.authorizationStatus(for: .video) != .denied else { return }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            if granted { self?.session.startRunning() }
        }
    }

    func stop() {
        session.stopRunning()
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        previewView?.currentPresentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        previewView?.render(pixelBuffer: pixelBuffer)
        onFrame?(pixelBuffer)
    }
}
