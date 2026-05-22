import Network
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var model = CameraViewModel()

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 430
            ZStack {
                CameraPreview(session: model.capture.session, rotationAngle: model.capture.videoRotationAngle)
                    .ignoresSafeArea()

                HStack(alignment: .top, spacing: 16) {
                    zoomSidePanel(compact: compact)

                    VStack(alignment: .leading, spacing: 12) {
                        statusPanel
                        Spacer()
                        bottomPanel
                    }
                    .frame(maxWidth: compact ? 560 : 680, alignment: .leading)

                    Spacer(minLength: 0)
                }
                .padding(compact ? 10 : 16)
            }
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
            HStack(spacing: 10) {
                Text("iPhoneCam")
                    .font(.headline)
                Button {
                    model.reconnect()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.headline)
                        .frame(width: 34, height: 30)
                }
                .buttonStyle(GlassIconButtonStyle())
                .accessibilityLabel("Reconnect")
            }
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
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                streamInfo
                Spacer()
                zoomPresetButtons
                rampDurationControl
            }

            VStack(alignment: .leading, spacing: 8) {
                streamInfo
                HStack(spacing: 12) {
                    zoomPresetButtons
                    rampDurationControl
                }
            }
        }
        .font(.footnote.monospacedDigit())
        .padding(12)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
    }

    private var streamInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.capture.activeFormatText)
            Text(model.capture.cameraModeText)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(model.senderStats)
        }
        .frame(maxWidth: 280, alignment: .leading)
    }

    private var zoomPresetButtons: some View {
        HStack(spacing: 6) {
            ForEach(model.zoomPresets, id: \.self) { factor in
                Button {
                    model.zoom(to: factor)
                } label: {
                    Text(model.zoomLabel(for: factor))
                        .frame(width: 44, height: 30)
                }
                .buttonStyle(ZoomPresetButtonStyle())
                .disabled(!model.isZoomPresetAvailable(factor))
                .opacity(model.isZoomPresetAvailable(factor) ? 1 : 0.35)
            }
        }
    }

    private var rampDurationControl: some View {
        HStack(spacing: 8) {
            Image(systemName: "timer")
                .frame(width: 18)
            Slider(value: $model.presetRampDuration, in: 0.3...3.0, step: 0.1)
                .frame(width: 112)
            Text(String(format: "%.1fs", model.presetRampDuration))
                .frame(width: 40, alignment: .trailing)
        }
        .frame(width: 190)
    }

    private func zoomSidePanel(compact: Bool) -> some View {
        VStack(spacing: 10) {
            Text(String(format: "%.1fx", model.capture.zoomFactor))
                .font(.title3.monospacedDigit().weight(.semibold))
                .frame(width: 74)

            ZoomJogControl(
                zoomFactor: model.capture.zoomFactor,
                minZoomFactor: model.capture.minZoomFactor,
                maxZoomFactor: model.capture.maxZoomFactor,
                switchOverZoomFactors: model.capture.switchOverZoomFactors,
                onChanged: model.updateZoomJog,
                onEnded: model.stopZoomJog
            )
            .frame(width: 74, height: compact ? 158 : 224)
        }
        .padding(10)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
    }
}

@MainActor
final class CameraViewModel: ObservableObject {
    @Published var networkStatus = "Looking for Mac receiver..."
    @Published var senderStats = "0 frames sent"
    @Published var presetRampDuration = 1.2

    let capture = CameraCaptureController()
    let zoomPresets: [CGFloat] = [0.5, 1, 2, 4, 8]

    private let browser = BonjourBrowser()
    private let sender = NetworkVideoSender()
    private var started = false
    private var lastEndpoint: NWEndpoint?
    private var idleTimerWasDisabled = false
    private var idleTimerManaged = false

    func start() {
        guard !started else {
            return
        }
        started = true
        disableIdleTimer()

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
            self?.lastEndpoint = endpoint
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
        restoreIdleTimer()
    }

    func updateOrientation() {
        capture.updateVideoRotation(
            for: UIDevice.current.orientation,
            interfaceOrientation: currentInterfaceOrientation()
        )
    }

    func zoom(to factor: CGFloat) {
        capture.rampZoom(to: factor, duration: presetRampDuration)
    }

    func updateZoomJog(_ intensity: Double) {
        capture.updateContinuousZoom(intensity: intensity)
    }

    func stopZoomJog() {
        capture.stopContinuousZoom()
    }

    func reconnect() {
        networkStatus = "Restarting connection..."
        senderStats = "0 frames sent"
        lastEndpoint = nil
        stop()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            self?.start()
        }
    }

    func isZoomPresetAvailable(_ factor: CGFloat) -> Bool {
        factor >= capture.minZoomFactor - 0.01 && factor <= capture.maxZoomFactor + 0.01
    }

    func zoomLabel(for factor: CGFloat) -> String {
        factor < 1 ? String(format: "%.1fx", factor) : "\(Int(factor))x"
    }

    private func currentInterfaceOrientation() -> UIInterfaceOrientation? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .interfaceOrientation
    }

    private func disableIdleTimer() {
        guard !idleTimerManaged else {
            return
        }
        idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        idleTimerManaged = true
    }

    private func restoreIdleTimer() {
        guard idleTimerManaged else {
            return
        }
        UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
        idleTimerManaged = false
    }
}

private struct ZoomJogControl: View {
    let zoomFactor: CGFloat
    let minZoomFactor: CGFloat
    let maxZoomFactor: CGFloat
    let switchOverZoomFactors: [CGFloat]
    let onChanged: (Double) -> Void
    let onEnded: () -> Void

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let width = proxy.size.width
            let usableDistance = max(1, height / 2 - 28)
            let clampedOffset = min(max(dragOffset, -usableDistance), usableDistance)
            let centerY = height / 2

            ZStack {
                Capsule()
                    .fill(.white.opacity(0.14))
                    .frame(width: 24)

                Rectangle()
                    .fill(.white.opacity(0.32))
                    .frame(width: 34, height: 1)
                    .position(x: width / 2, y: centerY)

                ForEach(switchOverZoomFactors, id: \.self) { factor in
                    Circle()
                        .fill(.white.opacity(0.55))
                        .frame(width: 5, height: 5)
                        .position(x: width / 2, y: yPosition(for: factor, height: height))
                }

                Circle()
                    .stroke(.white.opacity(0.85), lineWidth: 2)
                    .frame(width: 30, height: 30)
                    .position(x: width / 2, y: yPosition(for: zoomFactor, height: height))

                Circle()
                    .fill(.white)
                    .frame(width: 38, height: 38)
                    .shadow(color: .black.opacity(0.28), radius: 8, x: 0, y: 4)
                    .position(x: width / 2, y: centerY + clampedOffset)

                VStack {
                    Image(systemName: "plus.magnifyingglass")
                    Spacer()
                    Image(systemName: "minus.magnifyingglass")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))
                .padding(.vertical, 7)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let offset = min(max(value.location.y - centerY, -usableDistance), usableDistance)
                        dragOffset = offset
                        onChanged(Double(-offset / usableDistance))
                    }
                    .onEnded { _ in
                        dragOffset = 0
                        onEnded()
                    }
            )
        }
    }

    private func yPosition(for factor: CGFloat, height: CGFloat) -> CGFloat {
        let minFactor = max(minZoomFactor, 0.01)
        let maxFactor = max(maxZoomFactor, minFactor + 0.01)
        let clamped = min(max(factor, minFactor), maxFactor)
        let minLog = log2(Double(minFactor))
        let maxLog = log2(Double(maxFactor))
        let progress = (log2(Double(clamped)) - minLog) / max(maxLog - minLog, 0.01)
        return height - CGFloat(progress) * height
    }
}

private struct GlassIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(.white.opacity(configuration.isPressed ? 0.28 : 0.14), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ZoomPresetButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white)
            .background(.white.opacity(configuration.isPressed ? 0.30 : 0.16), in: RoundedRectangle(cornerRadius: 8))
    }
}
