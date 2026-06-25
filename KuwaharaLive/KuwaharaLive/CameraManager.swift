import AVFoundation
import CoreVideo
import Combine
import UIKit

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
    @Published var currentHalfResSize: CGSize = CGSize(width: 960, height: 540)

    // Always 16:9 landscape (the dimensions the stream encoder will see).
    var currentStreamSize: CGSize {
        let h = currentHalfResSize
        if h.height > h.width {  // portrait: center-crop to 16:9
            var cropH = (h.width * 9.0 / 16.0).rounded()
            if cropH.truncatingRemainder(dividingBy: 2) != 0 { cropH -= 1 }
            return CGSize(width: h.width, height: cropH)
        }
        return h
    }
    private(set) var frameRate: Int = 30

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

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleOrientationChange),
            name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(
            self, name: UIDevice.orientationDidChangeNotification, object: nil)
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
            applyRotation(to: connection)
        }

        session.commitConfiguration()

        applyFrameRate(to: source?.device)
    }

    func setFrameRate(_ fps: Int) {
        frameRate = fps
        applyFrameRate(to: currentSource?.device)
    }

    private func applyFrameRate(to device: AVCaptureDevice?) {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
    }

    func start() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        guard AVCaptureDevice.authorizationStatus(for: .video) != .denied else { return }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            if granted { self?.session.startRunning() }
        }
    }

    func stop() {
        session.stopRunning()
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    // MARK: - Orientation

    @objc private func handleOrientationChange() {
        let orientation = UIDevice.current.orientation
        guard orientation.isValidInterfaceOrientation else { return }
        if let connection = videoOutput.connection(with: .video) {
            applyRotation(to: connection)
        }
    }

    private func applyRotation(to connection: AVCaptureConnection) {
        let orientation = UIDevice.current.orientation
        if #available(iOS 17.0, *) {
            connection.videoRotationAngle = rotationAngle(for: orientation)
        } else {
            connection.videoOrientation = legacyOrientation(for: orientation)
        }
        let isLandscape = orientation == .landscapeLeft || orientation == .landscapeRight
        currentHalfResSize = isLandscape
            ? CGSize(width: 960, height: 540)
            : CGSize(width: 540, height: 960)
    }

    // LandscapeLeft = home on right = camera sensor's natural landscape orientation
    private func rotationAngle(for orientation: UIDeviceOrientation) -> Double {
        switch orientation {
        case .landscapeLeft:      return 0
        case .landscapeRight:     return 180
        case .portraitUpsideDown: return 270
        default:                  return 90
        }
    }

    private func legacyOrientation(for orientation: UIDeviceOrientation) -> AVCaptureVideoOrientation {
        switch orientation {
        case .landscapeLeft:      return .landscapeRight  // intentionally swapped
        case .landscapeRight:     return .landscapeLeft   // intentionally swapped
        case .portraitUpsideDown: return .portraitUpsideDown
        default:                  return .portrait
        }
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
