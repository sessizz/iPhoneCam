import SwiftUI

struct ContentView: View {
    @StateObject private var model = ReceiverViewModel()

    var body: some View {
        ZStack(alignment: .topLeading) {
            SampleBufferDisplayView(renderer: model.renderer)
                .ignoresSafeArea()
                .background(Color.black)

            VStack(alignment: .leading, spacing: 8) {
                Text("iPhoneCam Receiver")
                    .font(.headline)
                Text(model.statusText)
                Text(model.formatText)
                Text(model.statsText)
                if model.waitingForKeyFrame {
                    Text("Waiting for keyframe")
                        .foregroundStyle(.yellow)
                }
            }
            .font(.system(.subheadline, design: .rounded))
            .monospacedDigit()
            .padding(14)
            .foregroundStyle(.white)
            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
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
