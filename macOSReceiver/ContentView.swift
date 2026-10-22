import SwiftUI

struct ContentView: View {
    @StateObject private var model = ReceiverViewModel()

    var body: some View {
        ZStack(alignment: .topLeading) {
            SampleBufferDisplayView(renderer: model.renderer)
                .ignoresSafeArea()
                .background(Color.black)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    Text("iPhoneCam Receiver")
                        .font(.system(size: 14, weight: .bold, design: .rounded))

                    // Transport Badge (USB vs Wi-Fi)
                    if model.isUSBActive {
                        HStack(spacing: 4) {
                            Image(systemName: "cable.connector")
                                .font(.system(size: 11, weight: .bold))
                            Text("USB")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.9), in: Capsule())
                        .foregroundStyle(Color.black)
                    } else if model.isConnected {
                        HStack(spacing: 4) {
                            Image(systemName: "wifi")
                                .font(.system(size: 11, weight: .bold))
                            Text("Wi-Fi")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(0.85), in: Capsule())
                        .foregroundStyle(Color.white)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 11, weight: .bold))
                            Text("Waiting...")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.white.opacity(0.7))
                    }

                    // Codec Badge
                    if model.isConnected {
                        Text(model.activeCodec)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.indigo.opacity(0.85), in: Capsule())
                            .foregroundStyle(Color.white)
                    }

                    Picker("Source", selection: Binding(
                        get: { model.selectedSource },
                        set: { model.selectSource($0) }
                    )) {
                        Text("Auto").tag(ReceiverSource.auto)
                        Text("USB Cable").tag(ReceiverSource.usb)
                        ForEach(model.phones, id: \.self) { phone in
                            Text("\(phone) (Wi-Fi)").tag(ReceiverSource.phone(phone))
                        }
                        // Keep a saved choice selectable before discovery finds it again.
                        switch model.selectedSource {
                        case .phone(let phone) where !model.phones.contains(phone):
                            Text("\(phone) (Wi-Fi)").tag(model.selectedSource)
                        case .address(let address):
                            Text(address).tag(model.selectedSource)
                        default:
                            EmptyView()
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .fixedSize()
                }

                HStack(spacing: 6) {
                    TextField("iPhone IP (shown in the app)", text: $model.manualAddress)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 210)
                        .onSubmit {
                            model.connectToManualAddress()
                        }
                    Button("Connect") {
                        model.connectToManualAddress()
                    }
                    .disabled(model.manualAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.statusText)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))

                    Text(model.formatText)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))

                    Text(model.statsText)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))

                    if model.waitingForKeyFrame {
                        HStack(spacing: 5) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Waiting for keyframe...")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.yellow)
                        }
                        .padding(.top, 2)
                    }
                }
            }
            .monospacedDigit()
            .padding(14)
            .foregroundStyle(.white)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(model.isUSBActive ? Color.green.opacity(0.5) : Color.white.opacity(0.15), lineWidth: 1.5)
            )
            .padding(16)
        }
        .frame(minWidth: 960, minHeight: 540)
        .task {
            model.start()
        }
        .onDisappear {
            model.stop()
        }
    }
}
