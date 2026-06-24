import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var streamer = SRTStreamer()

    @State private var host = ""
    @State private var port = "9000"
    @State private var isStreaming = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                CameraPreview(camera: camera)
                    .ignoresSafeArea(edges: .top)

                controlPanel
            }
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    private var controlPanel: some View {
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
                Label(isStreaming ? "Stop" : "Start Stream",
                      systemImage: isStreaming ? "stop.circle.fill" : "dot.radiowaves.left.and.right")
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

struct CameraPreview: UIViewRepresentable {
    let camera: CameraManager

    func makeUIView(context: Context) -> MetalPreviewView {
        let view = MetalPreviewView()
        camera.previewView = view
        return view
    }

    func updateUIView(_ uiView: MetalPreviewView, context: Context) {}
}
