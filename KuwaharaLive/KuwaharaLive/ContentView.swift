import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var streamer = SRTStreamer()

    @State private var host = "192.168.1.20"
    @State private var port = "5000"
    @State private var isStreaming = false

    // Kuwahara filter controls
    @State private var kuwaharaEnabled = true
    @State private var kernelRadius: Double = 9    // 4–16 in half-res pixels (≈ 8–32 at full-res)
    @State private var passes: Int = 1             // 1–4
    @State private var sharpness: Double = 8.0     // q: 1–18
    @State private var hardness: Double = 8.0      // 1–25

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                CameraPreview(
                    camera: camera,
                    kuwaharaEnabled: kuwaharaEnabled,
                    kernelRadius: Int(kernelRadius),
                    passes: passes,
                    sharpness: Float(sharpness),
                    hardness: Float(hardness)
                )
                .ignoresSafeArea(edges: .top)
                .overlay(alignment: .bottom) {
                    if camera.availableSources.count > 1 {
                        lensPickerView.padding(.bottom, 16)
                    }
                }

                controlPanel
            }
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    // MARK: - Lens picker overlay

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

    // MARK: - Control panel

    private var controlPanel: some View {
        VStack(spacing: 0) {
            // ── Kuwahara toggle ──────────────────────────────────────────────
            Toggle(isOn: $kuwaharaEnabled) {
                Label("Kuwahara Filter", systemImage: "paintpalette")
                    .font(.subheadline.weight(.medium))
            }
            .tint(.purple)
            .padding(.horizontal)
            .padding(.top, 16)
            .padding(.bottom, kuwaharaEnabled ? 8 : 16)

            // ── Parameter sliders (only when filter is on) ───────────────────
            if kuwaharaEnabled {
                Divider().padding(.horizontal)

                VStack(spacing: 14) {
                    KuwaharaSlider(
                        label: "Radius",
                        value: $kernelRadius,
                        range: 4...16,
                        step: 1,
                        format: "%.0f",
                        tip: "Radius in half-res pixels (×2 = full-res equivalent)"
                    )

                    KuwaharaSlider(
                        label: "Passes",
                        value: Binding(get: { Double(passes) }, set: { passes = Int($0) }),
                        range: 1...4,
                        step: 1,
                        format: "%.0f",
                        tip: "More passes = stronger painterly effect"
                    )

                    KuwaharaSlider(
                        label: "Sharpness",
                        value: $sharpness,
                        range: 1...18,
                        step: 0.5,
                        format: "%.1f",
                        tip: "Higher = crisper stroke edges"
                    )

                    KuwaharaSlider(
                        label: "Hardness",
                        value: $hardness,
                        range: 1...25,
                        step: 1,
                        format: "%.0f",
                        tip: "Higher = more aggressive region separation"
                    )
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 4)

                Divider().padding(.horizontal)
            }

            // ── Stream controls ──────────────────────────────────────────────
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    TextField("OBS host / IP", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()

                    TextField("Port", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                        .frame(width: 80)
                }

                Button {
                    isStreaming ? stopStream() : startStream()
                } label: {
                    Label(
                        isStreaming ? "Stop" : "Start Stream",
                        systemImage: isStreaming ? "stop.circle.fill" : "dot.radiowaves.left.and.right"
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(isStreaming ? .red : .blue)
                .disabled(host.isEmpty)

                if let status = streamer.statusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(.ultraThinMaterial)
    }

    private func startStream() {
        guard let portNum = UInt16(port) else { return }
        isStreaming = true
        streamer.connect(host: host, port: portNum, camera: camera)
    }

    private func stopStream() {
        isStreaming = false
        streamer.disconnect()
    }
}

// MARK: - Reusable thumb-friendly slider row

private struct KuwaharaSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String
    let tip: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(String(format: format, value))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 36, alignment: .trailing)
            }
            Slider(value: $value, in: range, step: step)
                .tint(.purple)
                // Explicit frame height gives a larger thumb hit-target on small fingers
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
