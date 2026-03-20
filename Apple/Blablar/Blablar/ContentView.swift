import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.mic")
                .imageScale(.large)
                .font(.system(size: 40))
                .accessibilityHidden(true)

            Text("Blablar")
                .font(.title)
                .fontWeight(.semibold)

            Text("Speech to text, ready for shared iOS and macOS development.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: 420)
    }
}

#Preview {
    ContentView()
}
