import SwiftUI
import VoiceboxKit

/// The demo screen, laid out to match the Android example app: a version
/// caption, one section per API, a full-width button per presentation mode,
/// and a status card that flashes the latest callback and clears itself.
struct ContentView: View {

    /// The presentation modes offered, in the same order as Android's example.
    private enum Mode: String, CaseIterable, Identifiable {
        case bottomSheet, sheet, fullScreen, fitContent, customHeight, customFraction

        var id: String { rawValue }

        var title: String {
            switch self {
            case .bottomSheet:    return "Bottom Sheet"
            case .sheet:          return "Sheet (Full Height)"
            case .fullScreen:     return "Full Screen"
            case .fitContent:     return "Fit Content"
            case .customHeight:   return "Custom Height (500 pt)"
            case .customFraction: return "Custom Fraction (70%)"
            }
        }

        var mode: VoiceboxPresentationMode {
            switch self {
            case .bottomSheet:    return .bottomSheet
            case .sheet:          return .sheet
            case .fullScreen:     return .fullScreen
            case .fitContent:     return .fitContent
            case .customHeight:   return .custom(height: 500)
            case .customFraction: return .customFraction(0.7)
            }
        }
    }

    @State private var isPresented = false
    @State private var mode: VoiceboxPresentationMode = .bottomSheet

    @State private var status = ""
    @State private var statusIsFailure = false
    /// Identifies the current status message, so an older message's timer can't
    /// clear a newer one.
    @State private var statusToken = 0

    @State private var uikit: UIKitVoiceboxPresenter?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 8) {
                    Text("iOS SDK \(VoiceboxKit.version)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)

                    Spacer().frame(height: 8)

                    SectionLabel("SwiftUI API")

                    ForEach(Mode.allCases) { choice in
                        Button(choice.title) { present(choice) }
                            .buttonStyle(FilledButtonStyle())
                    }

                    Divider().padding(.vertical, 8)

                    SectionLabel("UIKit API")

                    Button("Bottom Sheet (UIKit API)") {
                        uikit?.present(handle: Demo.handle)
                    }
                    .buttonStyle(OutlinedButtonStyle())

                    if !status.isEmpty {
                        StatusCard(message: status, isFailure: statusIsFailure)
                            .padding(.top, 16)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .animation(.easeInOut(duration: 0.2), value: status)
            }
            .navigationTitle("VoiceboxKit")
        }
        .navigationViewStyle(.stack)
        .voicebox(
            isPresented: $isPresented,
            handle: Demo.handle,
            presentationMode: mode,
            onRecordingComplete: { report("Recording complete ✓") },
            onMessageSubmitted: { report("Message submitted ✓") },
            onDismiss: { report("Voicebox dismissed") }
        )
        .onAppear {
            if uikit == nil {
                uikit = UIKitVoiceboxPresenter { message, isFailure in
                    report(message, isFailure: isFailure)
                }
            }
        }
    }

    // MARK: - Presenting

    /// Sets the mode, then flips the binding on the next runloop pass.
    ///
    /// `VoiceboxModifier` switches on `presentationMode`, so each mode is a
    /// different branch of its view tree. Changing the mode and presenting in
    /// one update replaces that branch mid-presentation and the sheet can be
    /// dropped; one pass apart, the identity settles first.
    private func present(_ choice: Mode) {
        mode = choice.mode
        DispatchQueue.main.async { isPresented = true }
    }

    /// Shows a message and clears it after three seconds, as Android does.
    private func report(_ message: String, isFailure: Bool = false) {
        status = message
        statusIsFailure = isFailure
        statusToken += 1
        let token = statusToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if statusToken == token { status = "" }
        }
    }
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View { ContentView() }
}
#endif
