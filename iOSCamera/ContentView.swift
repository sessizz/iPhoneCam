import Combine
import Network
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var model = CameraViewModel()
    @State private var isInfoExpanded = false
    @State private var isBLESettingsPresented = false

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 430
            ZStack {
                Color.black
                    .ignoresSafeArea()

                CameraPreview(renderer: model.previewRenderer)
                    .ignoresSafeArea()

                controlOverlay(size: proxy.size, compact: compact)
                    .ignoresSafeArea()
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

    private func controlOverlay(size: CGSize, compact: Bool) -> some View {
        ZStack {
            zoomSidePanel(compact: compact, availableHeight: size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, compact ? 10 : 16)
                .padding(.vertical, compact ? 10 : 16)

            infoPanel(compact: compact, availableHeight: size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, compact ? 10 : 18)
                .padding(.leading, compact ? 118 : 130)

            bleZoomPanel(compact: compact)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, compact ? 10 : 18)
                .padding(.trailing, compact ? 10 : 16)

            bottomZoomBar
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, compact ? 12 : 20)

            if isBLESettingsPresented {
                bleSettingsModal(compact: compact)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
    }

    private func infoPanel(compact: Bool, availableHeight: CGFloat) -> some View {
        let expandedWidth: CGFloat = compact ? 520 : 640
        let collapsedWidth: CGFloat = 280
        let expandedMaxHeight = max(compact ? 230 : 330, availableHeight - (compact ? 170 : 200))
        let detailsMaxHeight = max(compact ? 116 : 180, expandedMaxHeight - (compact ? 70 : 82))

        return VStack(alignment: .leading, spacing: isInfoExpanded ? 8 : 0) {
            HStack(alignment: .center, spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isInfoExpanded.toggle()
                    }
                } label: {
                    Text("iPhoneCam")
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                Button {
                    model.reconnect()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.headline)
                        .frame(width: 42, height: 38)
                }
                .buttonStyle(GlassIconButtonStyle())
                .accessibilityLabel("Reconnect")
            }

            if isInfoExpanded {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.networkStatus)
                        Text(model.remoteControlStatus)
                        Text(model.bleControlStatus)
                        Text(model.capture.statusText)
                        if let warning = model.capture.warningText {
                            Text(warning)
                                .foregroundStyle(.yellow)
                        }
                        Divider()
                            .overlay(.white.opacity(0.18))
                        Text(model.capture.activeFormatText)
                        Text(model.capture.stabilizationModeText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                        stabilizationPicker
                        Text(model.capture.cameraModeText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                        Text(model.capture.activeLensText)
                        Text(model.capture.lensSwitchingText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                        lensSwitchingPicker
                        Text(model.senderStats)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: detailsMaxHeight)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .font(.subheadline.monospacedDigit())
        .padding(isInfoExpanded ? 14 : 12)
        .frame(width: isInfoExpanded ? expandedWidth : collapsedWidth, alignment: .leading)
        .frame(maxWidth: isInfoExpanded ? expandedWidth : collapsedWidth)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
    }

    private var lensSwitchingPicker: some View {
        Picker("", selection: Binding(
            get: { model.lensSwitchingMode },
            set: { model.setLensSwitchingMode($0) }
        )) {
            ForEach(LensSwitchingMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var stabilizationPicker: some View {
        Picker("", selection: Binding(
            get: { model.stabilizationMode },
            set: { model.setStabilizationMode($0) }
        )) {
            ForEach(VideoStabilizationSetting.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private func bleZoomPanel(compact: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: model.bleJoystickConnected ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                .font(.title3.weight(.semibold))
                .frame(width: 42, height: 42)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(model.bleJoystickStatus)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(model.bleSpeedLabel)
                    .foregroundStyle(.white.opacity(0.72))
            }
            .font(.caption.monospacedDigit().weight(.semibold))
            .frame(width: compact ? 142 : 180, alignment: .leading)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isBLESettingsPresented = true
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.headline.weight(.semibold))
                    .frame(width: 44, height: 42)
            }
            .buttonStyle(GlassIconButtonStyle())
            .accessibilityLabel("BLE Zoom Settings")
        }
        .padding(10)
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
    }

    private func bleSettingsModal(compact: Bool) -> some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isBLESettingsPresented = false
                    }
                }

            VStack(alignment: .leading, spacing: compact ? 12 : 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("BLE joystick")
                            .font(.headline.weight(.semibold))
                        Text(model.bleJoystickStatus)
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isBLESettingsPresented = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.semibold))
                            .frame(width: 38, height: 36)
                    }
                    .buttonStyle(GlassIconButtonStyle())
                    .accessibilityLabel("Close BLE Zoom Settings")
                }

                VStack(spacing: compact ? 10 : 12) {
                    bleSettingSlider(
                        icon: "circle.dotted",
                        label: "Deadzone",
                        value: Binding(
                            get: { model.bleZoomSettings.deadzone },
                            set: { model.setBLEDeadzone($0) }
                        ),
                        range: 0.02...0.35,
                        step: 0.01
                    )
                    bleSettingSlider(
                        icon: "minus.magnifyingglass",
                        label: "Min",
                        value: Binding(
                            get: { model.bleZoomSettings.minimumSpeed },
                            set: { model.setBLEMinimumSpeed($0) }
                        ),
                        range: 0.02...0.50,
                        step: 0.01
                    )
                    bleSettingSlider(
                        icon: "plus.magnifyingglass",
                        label: "Max",
                        value: Binding(
                            get: { model.bleZoomSettings.maximumSpeed },
                            set: { model.setBLEMaximumSpeed($0) }
                        ),
                        range: 0.20...1.00,
                        step: 0.01
                    )
                    bleSettingSlider(
                        icon: "function",
                        label: "Curve",
                        value: Binding(
                            get: { model.bleZoomSettings.curveExponent },
                            set: { model.setBLECurveExponent($0) }
                        ),
                        range: 0.70...3.00,
                        step: 0.05
                    )
                }

                VStack(spacing: compact ? 8 : 10) {
                    bleSettingToggle(
                        icon: "arrow.left.arrow.right",
                        label: "Swap axes",
                        isOn: Binding(
                            get: { model.bleZoomSettings.swapAxes },
                            set: { model.setBLESwapAxes($0) }
                        )
                    )
                    bleSettingToggle(
                        icon: "arrow.up.arrow.down",
                        label: "Invert zoom",
                        isOn: Binding(
                            get: { model.bleZoomSettings.invertZoomAxis },
                            set: { model.setBLEInvertZoomAxis($0) }
                        )
                    )
                    bleSettingToggle(
                        icon: "arrow.turn.up.left",
                        label: "Invert snap",
                        isOn: Binding(
                            get: { model.bleZoomSettings.invertSnapAxis },
                            set: { model.setBLEInvertSnapAxis($0) }
                        )
                    )
                }

                HStack {
                    Button {
                        model.resetBLEZoomSettings()
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                            .frame(width: 116, height: 38)
                    }
                    .buttonStyle(GlassIconButtonStyle())
                    .accessibilityLabel("Reset BLE Zoom Settings")

                    Spacer()

                    Text(model.bleSpeedLabel)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
            .padding(compact ? 16 : 20)
            .frame(maxWidth: compact ? 560 : 620, alignment: .leading)
            .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            )
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
        }
    }

    private func bleSettingSlider(icon: String, label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .frame(width: 24)
            Text(label)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .frame(width: 82, alignment: .leading)
            Slider(value: value, in: range, step: step)
                .frame(maxWidth: .infinity)
            Text(String(format: label == "Curve" ? "%.2f" : "%.0f%%", label == "Curve" ? value.wrappedValue : value.wrappedValue * 100))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .frame(width: 52, alignment: .trailing)
        }
    }

    private func bleSettingToggle(icon: String, label: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .frame(width: 24)
            Text(label)
                .font(.subheadline.monospacedDigit().weight(.semibold))
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private var bottomZoomBar: some View {
        HStack(spacing: 12) {
            zoomPresetButtons
            rampDurationControl
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
    }

    private var zoomPresetButtons: some View {
        HStack(spacing: 8) {
            ForEach(model.zoomPresets, id: \.self) { factor in
                Button {
                    model.zoom(to: factor)
                } label: {
                    Text(model.zoomLabel(for: factor))
                        .frame(width: 66, height: 44)
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
                .font(.title3.weight(.semibold))
                .frame(width: 28)
            Slider(value: $model.presetRampDuration, in: 0.3...3.0, step: 0.1)
                .frame(width: 132)
            Text(String(format: "%.1fs", model.presetRampDuration))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .frame(width: 44, alignment: .trailing)
        }
        .frame(width: 220)
    }

    private func zoomSidePanel(compact: Bool, availableHeight: CGFloat) -> some View {
        let minimumHeight: CGFloat = compact ? 350 : 500
        let verticalClearance: CGFloat = compact ? 28 : 44
        let panelHeight = min(max(minimumHeight, availableHeight - verticalClearance), max(260, availableHeight - 12))

        return VStack(spacing: 10) {
            Text(String(format: "%.1fx", model.capture.zoomFactor))
                .font(.title3.monospacedDigit().weight(.semibold))
                .frame(width: 74)

            Text(model.activeLensBadgeText)
                .font(.caption2.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.65)
                .frame(width: 74, height: 34)

            ZoomJogControl(
                zoomFactor: model.capture.zoomFactor,
                minZoomFactor: model.capture.minZoomFactor,
                maxZoomFactor: model.capture.maxZoomFactor,
                switchOverZoomFactors: model.capture.switchOverZoomFactors,
                onChanged: model.updateZoomJog,
                onEnded: model.stopZoomJog
            )
            .frame(width: 74)
            .frame(maxHeight: .infinity)
        }
        .padding(.vertical, 14)
        .frame(width: 94, height: panelHeight)
        .background(.black.opacity(0.46), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
    }
}

@MainActor
final class CameraViewModel: ObservableObject {
    private enum SettingsKey {
        static let bleDeadzone = "bleZoom.deadzone"
        static let bleMinimumSpeed = "bleZoom.minimumSpeed"
        static let bleMaximumSpeed = "bleZoom.maximumSpeed"
        static let bleCurveExponent = "bleZoom.curveExponent"
        static let bleSwapAxes = "bleZoom.swapAxes"
        static let bleInvertZoomAxis = "bleZoom.invertZoomAxis"
        static let bleInvertSnapAxis = "bleZoom.invertSnapAxis"
        static let lensSwitchingMode = "camera.lensSwitchingMode"
        static let stabilizationMode = "camera.stabilizationMode"
        static let presetRampDuration = "camera.presetRampDuration"
    }

    @Published var networkStatus = "Looking for Mac receiver..."
    @Published var senderStats = "0 frames sent"
    @Published var remoteControlStatus = "OBS control: idle"
    @Published var bleJoystickStatus = "BLE joystick: idle"
    @Published var bleControlStatus = "BLE zoom: idle"
    @Published var bleJoystickConnected = false
    @Published var bleSpeedLabel = "Speed 0%"
    @Published var bleZoomSettings = BLEZoomSettings.defaults
    @Published var lensSwitchingMode: LensSwitchingMode = .locked
    @Published var stabilizationMode: VideoStabilizationSetting = .standard
    @Published var presetRampDuration = 1.2

    let capture = CameraCaptureController()
    let previewRenderer = CameraPreviewRenderer()
    let zoomPresets: [CGFloat] = [0.5, 1, 2, 4, 8]

    private let browser = BonjourBrowser()
    private let sender = NetworkVideoSender()
    private let bleJoystick = BLEJoystickController()
    private var started = false
    private var lastEndpoint: NWEndpoint?
    private var idleTimerWasDisabled = false
    private var idleTimerManaged = false
    private var cancellables = Set<AnyCancellable>()
    private var bleZoomWasActive = false
    private var bleSnapArmed = true
    private var currentBLEIntensity = 0.0
    private var lastResetSequence: UInt16?
    private var isRestoringSettings = true

    init() {
        restoreSettings()
        bleJoystick.$statusText
            .sink { [weak self] status in
                Task { @MainActor in
                    self?.bleJoystickStatus = status
                }
            }
            .store(in: &cancellables)
        bleJoystick.$isConnected
            .sink { [weak self] isConnected in
                Task { @MainActor in
                    self?.bleJoystickConnected = isConnected
                }
            }
            .store(in: &cancellables)
        capture.$zoomFactor
            .sink { [weak self] zoomFactor in
                Task { @MainActor in
                    self?.sendBLEDisplayState(zoomFactor: zoomFactor)
                }
            }
            .store(in: &cancellables)
        $presetRampDuration
            .dropFirst()
            .sink { [weak self] duration in
                guard self?.isRestoringSettings == false else {
                    return
                }
                UserDefaults.standard.set(duration, forKey: SettingsKey.presetRampDuration)
            }
            .store(in: &cancellables)
        isRestoringSettings = false
    }

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
        sender.onControlCommand = { [weak self] command in
            Task { @MainActor in
                self?.handleRemoteControl(command)
            }
        }
        bleJoystick.onReport = { [weak self] report in
            Task { @MainActor in
                self?.handleBLEJoystickReport(report)
            }
        }
        bleJoystick.onStopped = { [weak self] in
            Task { @MainActor in
                self?.stopBLEZoomInput()
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
        capture.onPreviewSample = { [weak self] sampleBuffer in
            self?.previewRenderer.display(sampleBuffer)
        }

        browser.start()
        capture.start()
        bleJoystick.start()
        updateOrientation()
    }

    func stop() {
        stopBLEZoomInput()
        bleJoystick.stop()
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
        let mapped = BLEZoomMapper.intensity(forAxis: intensity, settings: bleZoomSettings)
        capture.updateContinuousZoom(intensity: mapped)
    }

    func stopZoomJog() {
        capture.stopContinuousZoom()
    }

    func setLensSwitchingMode(_ mode: LensSwitchingMode) {
        lensSwitchingMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: SettingsKey.lensSwitchingMode)
        capture.setLensSwitchingMode(mode)
    }

    func setStabilizationMode(_ mode: VideoStabilizationSetting) {
        stabilizationMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: SettingsKey.stabilizationMode)
        capture.setStabilizationMode(mode)
    }

    func setBLEDeadzone(_ value: Double) {
        var settings = bleZoomSettings
        settings.deadzone = max(0.02, min(0.35, value))
        setBLEZoomSettings(settings)
    }

    func setBLEMinimumSpeed(_ value: Double) {
        let minimum = max(0.02, min(0.50, value))
        var settings = bleZoomSettings
        settings.minimumSpeed = minimum
        if settings.maximumSpeed < minimum {
            settings.maximumSpeed = minimum
        }
        setBLEZoomSettings(settings)
    }

    func setBLEMaximumSpeed(_ value: Double) {
        var settings = bleZoomSettings
        settings.maximumSpeed = max(settings.minimumSpeed, min(1.0, value))
        setBLEZoomSettings(settings)
    }

    func setBLECurveExponent(_ value: Double) {
        var settings = bleZoomSettings
        settings.curveExponent = max(0.70, min(3.00, value))
        setBLEZoomSettings(settings)
    }

    func setBLESwapAxes(_ value: Bool) {
        var settings = bleZoomSettings
        settings.swapAxes = value
        setBLEZoomSettings(settings)
    }

    func setBLEInvertZoomAxis(_ value: Bool) {
        var settings = bleZoomSettings
        settings.invertZoomAxis = value
        setBLEZoomSettings(settings)
    }

    func setBLEInvertSnapAxis(_ value: Bool) {
        var settings = bleZoomSettings
        settings.invertSnapAxis = value
        setBLEZoomSettings(settings)
    }

    func resetBLEZoomSettings() {
        setBLEZoomSettings(.defaults)
    }

    func reconnect() {
        networkStatus = "Restarting connection..."
        senderStats = "0 frames sent"
        remoteControlStatus = "OBS control: idle"
        bleControlStatus = "BLE zoom: idle"
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

    var activeLensBadgeText: String {
        capture.activeLensText.replacingOccurrences(of: "Lens: ", with: "")
    }

    private func restoreSettings() {
        let defaults = UserDefaults.standard
        var settings = BLEZoomSettings.defaults
        if defaults.object(forKey: SettingsKey.bleDeadzone) != nil {
            settings.deadzone = max(0.02, min(0.35, defaults.double(forKey: SettingsKey.bleDeadzone)))
        }
        if defaults.object(forKey: SettingsKey.bleMinimumSpeed) != nil {
            settings.minimumSpeed = max(0.02, min(0.50, defaults.double(forKey: SettingsKey.bleMinimumSpeed)))
        }
        if defaults.object(forKey: SettingsKey.bleMaximumSpeed) != nil {
            settings.maximumSpeed = max(settings.minimumSpeed, min(1.0, defaults.double(forKey: SettingsKey.bleMaximumSpeed)))
        }
        if defaults.object(forKey: SettingsKey.bleCurveExponent) != nil {
            settings.curveExponent = max(0.70, min(3.00, defaults.double(forKey: SettingsKey.bleCurveExponent)))
        }
        if defaults.object(forKey: SettingsKey.bleSwapAxes) != nil {
            settings.swapAxes = defaults.bool(forKey: SettingsKey.bleSwapAxes)
        }
        if defaults.object(forKey: SettingsKey.bleInvertZoomAxis) != nil {
            settings.invertZoomAxis = defaults.bool(forKey: SettingsKey.bleInvertZoomAxis)
        }
        if defaults.object(forKey: SettingsKey.bleInvertSnapAxis) != nil {
            settings.invertSnapAxis = defaults.bool(forKey: SettingsKey.bleInvertSnapAxis)
        }
        bleZoomSettings = settings

        if
            let rawLensMode = defaults.string(forKey: SettingsKey.lensSwitchingMode),
            let mode = LensSwitchingMode(rawValue: rawLensMode)
        {
            lensSwitchingMode = mode
            capture.setLensSwitchingMode(mode)
        }

        if
            let rawStabilizationMode = defaults.string(forKey: SettingsKey.stabilizationMode),
            let mode = VideoStabilizationSetting(rawValue: rawStabilizationMode)
        {
            stabilizationMode = mode
            capture.setStabilizationMode(mode)
        }

        if defaults.object(forKey: SettingsKey.presetRampDuration) != nil {
            presetRampDuration = max(0.3, min(3.0, defaults.double(forKey: SettingsKey.presetRampDuration)))
        }
    }

    private func setBLEZoomSettings(_ settings: BLEZoomSettings) {
        bleZoomSettings = settings
        saveBLEZoomSettings(settings)
    }

    private func saveBLEZoomSettings(_ settings: BLEZoomSettings) {
        let defaults = UserDefaults.standard
        defaults.set(settings.deadzone, forKey: SettingsKey.bleDeadzone)
        defaults.set(settings.minimumSpeed, forKey: SettingsKey.bleMinimumSpeed)
        defaults.set(settings.maximumSpeed, forKey: SettingsKey.bleMaximumSpeed)
        defaults.set(settings.curveExponent, forKey: SettingsKey.bleCurveExponent)
        defaults.set(settings.swapAxes, forKey: SettingsKey.bleSwapAxes)
        defaults.set(settings.invertZoomAxis, forKey: SettingsKey.bleInvertZoomAxis)
        defaults.set(settings.invertSnapAxis, forKey: SettingsKey.bleInvertSnapAxis)
    }

    private func handleBLEJoystickReport(_ report: BLEZoomJoystickReport) {
        if report.flags.contains(.resetZoom), lastResetSequence != report.sequence {
            lastResetSequence = report.sequence
            currentBLEIntensity = 0
            bleZoomWasActive = false
            bleControlStatus = "BLE zoom: reset"
            bleSpeedLabel = "Speed 0%"
            capture.rampZoom(to: 1, duration: presetRampDuration)
            sendBLEDisplayState(zoomFactor: capture.zoomFactor)
            return
        }

        let snapAxis = BLEZoomMapper.snapAxis(from: report, settings: bleZoomSettings)

        if abs(snapAxis) < 0.55 {
            bleSnapArmed = true
        }

        if
            bleSnapArmed,
            let snap = BLEZoomMapper.snapTarget(
                forAxis: snapAxis,
                currentZoomFactor: Double(capture.zoomFactor),
                minZoomFactor: Double(capture.minZoomFactor),
                maxZoomFactor: Double(capture.maxZoomFactor)
            )
        {
            bleSnapArmed = false
            currentBLEIntensity = 0
            bleSpeedLabel = "Speed 0%"
            if bleZoomWasActive {
                capture.stopContinuousZoom()
                bleZoomWasActive = false
            }
            let label = snap.direction == .down ? "down" : "up"
            bleControlStatus = String(format: "BLE zoom: snap %@ %.0fx", label, snap.targetZoomFactor)
            capture.rampZoom(to: CGFloat(snap.targetZoomFactor), duration: presetRampDuration)
            sendBLEDisplayState(zoomFactor: capture.zoomFactor)
            return
        }

        let mapping = BLEZoomMapper.map(report: report, settings: bleZoomSettings)
        currentBLEIntensity = mapping.intensity
        bleSpeedLabel = String(format: "Speed %+d%%", mapping.signedSpeedPercent)

        guard mapping.isActive else {
            stopBLEZoomInput()
            sendBLEDisplayState(zoomFactor: capture.zoomFactor)
            return
        }

        bleZoomWasActive = true
        let direction = mapping.intensity > 0 ? "in" : "out"
        bleControlStatus = String(format: "BLE zoom: %@ %d%%", direction, abs(mapping.signedSpeedPercent))
        capture.updateContinuousZoom(intensity: mapping.intensity)
        sendBLEDisplayState(zoomFactor: capture.zoomFactor)
    }

    private func stopBLEZoomInput() {
        currentBLEIntensity = 0
        bleSpeedLabel = "Speed 0%"
        if bleZoomWasActive {
            capture.stopContinuousZoom()
            bleZoomWasActive = false
        }
        bleControlStatus = "BLE zoom: idle"
        sendBLEDisplayState(zoomFactor: capture.zoomFactor)
    }

    private func sendBLEDisplayState(zoomFactor: CGFloat) {
        bleJoystick.updateDisplay(zoomFactor: Double(zoomFactor), intensity: currentBLEIntensity)
    }

    private func handleRemoteControl(_ command: CameraControlPayload) {
        switch command.action {
        case .zoomIn:
            let speed = command.speed ?? .medium
            remoteControlStatus = "OBS control: zoom in \(speed.rawValue)"
            capture.updateContinuousZoom(intensity: zoomIntensity(for: speed))
        case .zoomOut:
            let speed = command.speed ?? .medium
            remoteControlStatus = "OBS control: zoom out \(speed.rawValue)"
            capture.updateContinuousZoom(intensity: -zoomIntensity(for: speed))
        case .stopZoom:
            remoteControlStatus = "OBS control: stop"
            capture.stopContinuousZoom()
        case .resetZoom:
            remoteControlStatus = "OBS control: reset zoom"
            capture.rampZoom(to: 1, duration: presetRampDuration)
        }
    }

    private func zoomIntensity(for speed: CameraControlSpeed) -> Double {
        switch speed {
        case .slow:
            return 0.22
        case .medium:
            return 0.55
        case .fast:
            return 1.0
        }
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
            let usableDistance = max(1, height / 2 - 18)
            let clampedOffset = min(max(dragOffset, -usableDistance), usableDistance)
            let centerY = height / 2
            let zoomY = yPosition(for: zoomFactor, height: height)

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

                Capsule()
                    .fill(.white.opacity(0.88))
                    .frame(width: 34, height: 3)
                    .position(x: width / 2, y: zoomY)

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
