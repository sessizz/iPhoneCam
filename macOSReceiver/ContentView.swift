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

                    // Device Picker Dropdown
                    Picker("Device", selection: $model.selectedDevice) {
                        ForEach(model.availableDevices, id: \.self) { dev in
                            Text(dev).tag(dev)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: model.selectedDevice) { _, newValue in
                        model.selectDevice(newValue)
                    }
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
