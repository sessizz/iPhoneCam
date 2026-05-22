import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var model = CameraViewModel()

    var body: some View {
        ZStack {
            CameraPreview(session: model.capture.session, rotationAngle: model.capture.videoRotationAngle)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                statusPanel
                Spacer()
                bottomPanel
            }
            .padding()
        }
        .task {
            model.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            model.updateOrientation()
        }
        .onDisappear {
            model.stop()
        }
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("iPhoneCam")
                .font(.headline)
            Text(model.networkStatus)
            Text(model.capture.statusText)
            if let warning = model.capture.warningText {
                Text(warning)
                    .foregroundStyle(.yellow)
            }
        }
        .font(.subheadline)
        .padding(12)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
    }

    private var bottomPanel: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.capture.activeFormatText)
                Text(model.senderStats)
            }
            Spacer()
        }
        .font(.footnote.monospacedDigit())
        .padding(12)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
    }
}

@MainActor
final class CameraViewModel: ObservableObject {
    @Published var networkStatus = "Looking for Mac receiver..."
    @Published var senderStats = "0 frames sent"

    let capture = CameraCaptureController()

    private let browser = BonjourBrowser()
    private let sender = NetworkVideoSender()
    private var started = false

    func start() {
        guard !started else {
            return
        }
        started = true

        sender.onStatusChanged = { [weak self] status in
            Task { @MainActor in
                self?.networkStatus = status
            }
        }
        sender.onStatsChanged = { [weak self] stats in
            Task { @MainActor in
                self?.senderStats = stats
            }
        }
        browser.onStatusChanged = { [weak self] status in
            Task { @MainActor in
                self?.networkStatus = status
            }
        }
        browser.onEndpointFound = { [weak self] endpoint in
            self?.sender.connect(to: endpoint)
        }
        capture.onFormat = { [weak self] format in
            self?.sender.updateFormat(format)
        }
        capture.onEncodedSample = { [weak self] sample in
            self?.sender.send(sample)
        }

        browser.start()
        capture.start()
        updateOrientation()
    }

    func stop() {
        browser.stop()
        sender.stop()
        capture.stop()
        started = false
    }

    func updateOrientation() {
        capture.updateVideoRotation(for: UIDevice.current.orientation)
    }
}
