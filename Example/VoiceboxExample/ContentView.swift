import SwiftUI
import VoiceboxKit

/// Example showing all four presentation modes with dismiss callback.
struct ContentView: View {
    @State private var showVoicebox = false
    @State private var showFullScreen = false
    @State private var selectedMode: VoiceboxPresentationMode = .bottomSheet
    @State private var statusMessage = ""

    // Simulated logged-in user
    let userEmail = "jane@example.com"
    let userID = "usr_abc123"

    private var params: [String: String] {
        [
            "email": userEmail,
            "userID": userID,
            "prompt": "How are you liking Alice?",
        ]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()

                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.blue)

                Text("VoiceboxKit Example")
                    .font(.title2.bold())

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .transition(.opacity)
                }

                Spacer()

                VStack(spacing: 12) {
                    modeButton("Bottom Sheet", icon: "rectangle.bottomhalf.inset.filled") {
                        selectedMode = .bottomSheet
                        showVoicebox = true
                    }

                    modeButton("Sheet", icon: "rectangle.inset.filled") {
                        selectedMode = .sheet
                        showVoicebox = true
                    }

                    modeButton("Full Screen", icon: "arrow.up.left.and.arrow.down.right") {
                        showFullScreen = true
                    }

                    modeButton("Fit Content", icon: "arrow.up.and.down.text.horizontal") {
                        selectedMode = .fitContent
                        showVoicebox = true
                    }
                }
                .padding(.horizontal, 24)

                Spacer()
            }
            .navigationTitle("Example")
            .voicebox(
                isPresented: $showVoicebox,
                handle: "pavan-test",
                params: params,
                presentationMode: selectedMode,
                autoGrantMicPermission: true,
                onRecordingComplete: {
                    showStatus("Recording complete!")
                },
                onMessageSubmitted: {
                    showStatus("Message submitted!")
                },
                onDismiss: {
                    showStatus("Voicebox dismissed")
                }
            )
            .voicebox(
                isPresented: $showFullScreen,
                handle: "pavan-test",
                params: params,
                presentationMode: .fullScreen,
                autoGrantMicPermission: true,
                onRecordingComplete: {
                    showStatus("Recording complete!")
                },
                onMessageSubmitted: {
                    showStatus("Message submitted!")
                },
                onDismiss: {
                    showStatus("Voicebox dismissed")
                }
            )
        }
    }

    private func showStatus(_ message: String) {
        withAnimation { statusMessage = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { statusMessage = "" }
        }
    }

    private func modeButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

#Preview {
    ContentView()
}
