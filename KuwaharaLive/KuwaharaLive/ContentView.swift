import SwiftUI
import AVFoundation
import Photos
import CoreImage

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var streamer = SRTStreamer()

    @State private var host = "192.168.1.20"
    @State private var port = "5000"
    @State private var isStreaming = false
    @State private var controlsCollapsed = false

    @State private var kuwaharaEnabled = true
    @State private var kernelRadius: Double = 9
    @State private var passes: Int = 1
    @State private var sharpness: Double = 8.0
    @State private var hardness: Double = 8.0
    @State private var frameRate: Int = 30

    @FocusState private var focusedField: Field?
    enum Field { case host, port }

    // MARK: - Root layout

    // Still capture feedback
    @State private var captureFlash = false

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            ZStack {
                Color.black
                if isLandscape {
                    landscapeLayout(geo: geo)
                } else {
                    portraitLayout
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: controlsCollapsed)
        }
        .ignoresSafeArea()
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    // MARK: - Landscape: camera left 2/3, controls right 1/3

    private func landscapeLayout(geo: GeometryProxy) -> some View {
        HStack(spacing: 0) {
            cameraPreviewView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture { focusedField = nil }
                .overlay {
                    if captureFlash {
                        Color.white.ignoresSafeArea()
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if camera.availableSources.count > 1 {
                        lensPickerView.padding(16)
                    }
                }
                .overlay(alignment: .trailing) {
                    if controlsCollapsed {
                        Button { withAnimation { controlsCollapsed = false } } label: {
                            Image(systemName: "chevron.left")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 8)
                    }
                }

            if !controlsCollapsed {
                VStack(spacing: 0) {
                    // Collapse handle
                    Button {
                        withAnimation { controlsCollapsed = true; focusedField = nil }
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider()

                    ScrollView(.vertical, showsIndicators: false) {
                        sharedControlContent
                            .padding()
                    }

                    Divider()

                    shutterButton
                        .padding(.vertical, 16)
                }
                .frame(width: geo.size.width / 3)
                .background(.ultraThinMaterial)
            }
        }
    }

    // MARK: - Portrait: camera top, controls bottom

    private var portraitLayout: some View {
        VStack(spacing: 0) {
            cameraPreviewView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: .top)
                .onTapGesture { focusedField = nil }
                .overlay {
                    // White flash on capture
                    if captureFlash {
                        Color.white.ignoresSafeArea()
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottom) {
                    HStack(spacing: 0) {
                        // Lens picker (left-aligned)
                        if camera.availableSources.count > 1 {
                            lensPickerView
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Spacer()
                        }

                        // Shutter button (center)
                        shutterButton
                            .frame(maxWidth: .infinity)

                        Spacer()
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }

            VStack(spacing: 0) {
                // Collapse handle
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        controlsCollapsed.toggle()
                        if controlsCollapsed { focusedField = nil }
                    }
                } label: {
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(Color.secondary.opacity(0.4))
                            .frame(width: 36, height: 5)
                        Image(systemName: controlsCollapsed ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if !controlsCollapsed {
                    sharedControlContent
                        .padding(.bottom, 8)
                }
            }
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Shared control content

    private var sharedControlContent: some View {
        VStack(spacing: 0) {
            // ── Kuwahara toggle ──────────────────────────────────────────────
            Toggle(isOn: $kuwaharaEnabled) {
                Label("Kuwahara Filter", systemImage: "paintpalette")
                    .font(.subheadline.weight(.medium))
            }
            .tint(.purple)
            .padding(.top, 8)
            .padding(.bottom, kuwaharaEnabled ? 8 : 0)

            // ── Parameter sliders ────────────────────────────────────────────
            if kuwaharaEnabled {
                Divider()

                VStack(spacing: 14) {
                    KuwaharaSlider(label: "Radius",
                                   value: $kernelRadius, range: 4...16, step: 1, format: "%.0f")
                    KuwaharaSlider(
                        label: "Passes",
                        value: Binding(get: { Double(passes) }, set: { passes = Int($0) }),
                        range: 1...4, step: 1, format: "%.0f")
                    KuwaharaSlider(label: "Sharpness",
                                   value: $sharpness, range: 1...18, step: 0.5, format: "%.1f")
                    KuwaharaSlider(label: "Hardness",
                                   value: $hardness, range: 1...25, step: 1, format: "%.0f")
                }
                .padding(.top, 12)
                .padding(.bottom, 4)
            }

            Divider().padding(.top, 8)

            // ── Frame rate ───────────────────────────────────────────────────
            HStack {
                Text("Frame rate").font(.subheadline.weight(.medium))
                Spacer()
                Picker("Frame rate", selection: $frameRate) {
                    Text("15 fps").tag(15)
                    Text("24 fps").tag(24)
                    Text("30 fps").tag(30)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .padding(.vertical, 8)
            .onChange(of: frameRate) { fps in
                camera.setFrameRate(fps)
                streamer.frameRate = fps
            }

            Divider()

            // ── Stream controls ──────────────────────────────────────────────
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    TextField("Host / IP", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .host)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .port }

                    TextField("Port", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                        .frame(width: 72)
                        .focused($focusedField, equals: .port)
                }
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { focusedField = nil }
                    }
                }

                Button {
                    isStreaming ? stopStream() : startStream()
                } label: {
                    Label(
                        isStreaming ? "Stop" : "Start Stream",
                        systemImage: isStreaming ? "stop.circle.fill" : "dot.radiowaves.left.and.right"
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(isStreaming ? .red : .blue)
                .disabled(host.isEmpty)

                if let status = streamer.statusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.top, 12)
        }
    }

    // MARK: - Camera preview

    private var cameraPreviewView: some View {
        CameraPreview(
            camera: camera,
            kuwaharaEnabled: kuwaharaEnabled,
            kernelRadius: Int(kernelRadius),
            passes: passes,
            sharpness: Float(sharpness),
            hardness: Float(hardness)
        )
    }

    // MARK: - Shutter button

    private var shutterButton: some View {
        Button {
            capturePhoto()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 3)
                    .frame(width: 62, height: 62)
                Circle()
                    .fill(.white)
                    .frame(width: 52, height: 52)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
    }

    // MARK: - Lens picker

    private var lensPickerView: some View {
        HStack(spacing: 6) {
            ForEach(camera.availableSources) { source in
                Button {
                    camera.switchTo(source)
                } label: {
                    Text(source.label)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(camera.currentSource == source ? .black : .white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            camera.currentSource == source
                                ? Color.yellow
                                : Color.black.opacity(0.45)
                        )
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - Stream control

    private func startStream() {
        guard let portNum = UInt16(port) else { return }
        isStreaming = true
        streamer.connect(host: host, port: portNum, camera: camera)
    }

    private func stopStream() {
        isStreaming = false
        camera.previewView?.onProcessedFrame = nil
        streamer.disconnect()
    }

    // MARK: - Photo capture

    private func capturePhoto() {
        camera.previewView?.onCaptureFrame = { pixelBuffer in
            saveFilteredFrame(pixelBuffer)
        }
    }

    private func saveFilteredFrame(_ pixelBuffer: CVPixelBuffer) {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return }
        let image = UIImage(cgImage: cg)

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { _, _ in
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.08)) { captureFlash = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        withAnimation(.easeIn(duration: 0.18)) { captureFlash = false }
                    }
                }
            }
        }
    }
}

// MARK: - Slider row

private struct KuwaharaSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline.weight(.medium))
                Spacer()
                Text(String(format: format, value))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 36, alignment: .trailing)
            }
            Slider(value: $value, in: range, step: step)
                .tint(.purple)
                .frame(height: 28)
        }
    }
}

// MARK: - Camera preview bridge

struct CameraPreview: UIViewRepresentable {
    let camera: CameraManager
    let kuwaharaEnabled: Bool
    let kernelRadius: Int
    let passes: Int
    let sharpness: Float
    let hardness: Float

    func makeUIView(context: Context) -> MetalPreviewView {
        let view = MetalPreviewView()
        camera.previewView = view
        return view
    }

    func updateUIView(_ uiView: MetalPreviewView, context: Context) {
        uiView.kuwaharaEnabled = kuwaharaEnabled
        uiView.kernelRadius    = kernelRadius
        uiView.passes          = passes
        uiView.sharpness       = sharpness
        uiView.hardness        = hardness
    }
}
