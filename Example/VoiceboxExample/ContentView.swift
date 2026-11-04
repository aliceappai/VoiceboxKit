import SwiftUI
import VoiceboxKit

/// A harness for every scenario the SDK exposes, laid out like the Android
/// example app: version caption, section labels, full-width buttons, and a
/// status card that flashes the latest callback.
struct ContentView: View {

    @StateObject private var model = HarnessModel()
    @State private var isPresented = false
    @State private var uikit: UIKitVoiceboxPresenter?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 8) {
                    versionCaption
                    handleField
                    swiftUIAPISection
                    separator
                    uikitAPISection
                    separator
                    scenarioSection
                    separator
                    globalsSection
                    separator
                    sessionSection
                    statusSection
                    eventLogSection
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .navigationTitle("VoiceboxKit")
        }
        .navigationViewStyle(.stack)
        .voicebox(
            isPresented: $isPresented,
            handle: model.handle,
            params: model.params,
            theme: model.themeChoice.theme,
            presentationMode: model.mode.mode,
            showCloseButton: model.showCloseButton,
            showDragIndicator: model.showDragIndicator,
            hidePageChrome: model.hidePageChrome,
            entranceAnimation: model.entranceAnimation,
            onRecordingComplete: { model.record("Recording complete ✓") },
            onMessageSubmitted: { model.record("Message submitted ✓") },
            onDismiss: { model.record("Dismissed") },
            onAnonymousSessionId: { model.captureSessionId($0) }
        )
        .onAppear {
            if uikit == nil { uikit = UIKitVoiceboxPresenter(model: model) }
        }
    }

    // MARK: Header

    private var versionCaption: some View {
        Text("iOS SDK \(VoiceboxKit.version)")
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
    }

    private var handleField: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("Handle")
            TextField("handle", text: $model.handle)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Text("vbx.to/@\(model.handle) — recordings land in this voicebox.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var separator: some View {
        Divider().padding(.vertical, 8)
    }

    // MARK: SwiftUI API

    private var swiftUIAPISection: some View {
        VStack(spacing: 8) {
            SectionLabel("SwiftUI API")
            ForEach(ModeChoice.allCases) { choice in
                Button(choice.title) { present(choice) }
                    .buttonStyle(FilledButtonStyle())
            }
            Text("Fit Content and the two custom sizes need iOS 16 — on iOS 15 the SDK falls back to a full-height sheet.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: UIKit API

    private var uikitAPISection: some View {
        VStack(spacing: 8) {
            SectionLabel("UIKit API")
            Button("Present via VoiceboxView") {
                uikit?.present(handle: model.handle, scenario: model)
            }
            .buttonStyle(OutlinedButtonStyle())

            Button("Unknown handle → onFailure") {
                uikit?.present(handle: "handle-that-does-not-exist", scenario: model)
            }
            .buttonStyle(OutlinedButtonStyle())

            Text("Load failures only reach VoiceboxDelegate — the SwiftUI modifier has no onFailure, so this is the only path that can report one.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Scenario

    private var scenarioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Scenario")

            Picker("Theme", selection: $model.themeChoice) {
                ForEach(ThemeChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            ToggleRow("Send user params",
                      note: "email, userID, prompt, screen",
                      isOn: $model.sendUserParams)
            ToggleRow("Close button", isOn: $model.showCloseButton)
            ToggleRow("Drag indicator", note: "Sheet modes only", isOn: $model.showDragIndicator)
            ToggleRow("Hide page chrome",
                      note: "Strips the recorder page's own footer and background",
                      isOn: $model.hidePageChrome)
            ToggleRow("Card entrance animation",
                      note: "Floating Card only",
                      isOn: $model.animateCardEntrance)
        }
    }

    // MARK: Globals

    private var globalsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("SDK globals")

            Picker("Host", selection: $model.baseURLChoice) {
                ForEach(BaseURLChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            ToggleRow("Debug logging", note: "[VoiceboxKit] lines in the console", isOn: $model.debugLogging)
            ToggleRow("Auto-grant mic to WebView",
                      note: "Off means WebKit prompts again inside the recorder",
                      isOn: $model.autoGrantMicPermission)
            ToggleRow("Auto-collect app context",
                      note: "App version, OS, device model, locale, sdkVersion",
                      isOn: $model.autoCollectAppContext)
            ToggleRow("Keep screen awake",
                      note: "Stops auto-lock killing a long take",
                      isOn: $model.keepsScreenAwake)

            Button("Preload this scenario") { model.preloadCurrentScenario() }
                .buttonStyle(OutlinedButtonStyle())
            Text("The warm WebView is keyed on the full URL, so preload only pays off when the handle and params match what you present.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Session

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Session")

            Text(model.anonymousSessionId.map { "Anonymous id: \($0)" } ?? "No anonymous id yet — record something.")
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("Session URL from your backend", text: $model.sessionURLString)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            Button("Establish session") { model.establishSession() }
                .buttonStyle(OutlinedButtonStyle())
                .disabled(model.sessionURLString.isEmpty)

            Button("Clear session") { model.clearSession() }
                .buttonStyle(OutlinedButtonStyle())
        }
    }

    // MARK: Status and log

    private var statusSection: some View {
        VStack(spacing: 8) {
            if !model.status.isEmpty {
                StatusCard(message: model.status, isFailure: model.events.first?.isFailure ?? false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.status)
        .padding(.top, 8)
    }

    private var eventLogSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel("Event log")
                Spacer()
                Button("Clear") { model.clearEvents() }
                    .font(.caption)
            }

            if model.events.isEmpty {
                Text("Callbacks show up here as they fire.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                ForEach(model.events) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(event.timestamp)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text(event.message)
                            .font(.caption)
                            .foregroundColor(event.isFailure ? Color(uiColor: .systemRed) : .primary)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: Presenting

    /// Sets the mode, then flips the binding on the next runloop pass.
    ///
    /// `VoiceboxModifier` switches on `presentationMode`, so each mode is a
    /// different branch of its view tree. Changing the mode and presenting in
    /// one update replaces that branch mid-presentation and the sheet can be
    /// dropped; one pass apart, the identity settles first.
    private func present(_ choice: ModeChoice) {
        model.mode = choice
        DispatchQueue.main.async { isPresented = true }
    }
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View { ContentView() }
}
#endif
