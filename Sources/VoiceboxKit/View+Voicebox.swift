import SwiftUI

// MARK: - SwiftUI View Modifier

/// A SwiftUI view modifier that presents a Voicebox recording experience.
struct VoiceboxModifier: ViewModifier {
    @Binding var isPresented: Bool
    let handle: String
    var params: [String: String]
    var theme: VoiceboxTheme
    var presentationMode: VoiceboxPresentationMode
    var showCloseButton: Bool
    var autoGrantMicPermission: Bool?
    var onRecordingComplete: (() -> Void)?
    var onMessageSubmitted: (() -> Void)?
    var onDismiss: (() -> Void)?

    /// Tracks the background colour detected from the web page.
    /// Seeded from the per-handle cache so re-opens use the correct colour immediately.
    @State private var sheetBackground: Color = Color(uiColor: .systemBackground)

    /// The colour to use for `presentationBackground` (controls the home-indicator strip).
    /// - If the caller supplied an explicit `theme.backgroundColor`, that colour wins.
    /// - Otherwise we use whatever JS detected from the web page.
    private var effectivePresentationBackground: Color {
        if let explicit = theme.backgroundColor {
            return Color(uiColor: explicit)
        }
        return sheetBackground
    }

    private func makeRepresentable() -> VoiceboxRepresentable {
        // Capture the Binding — it has reference semantics, so the closure
        // always writes to the live @State storage even after the struct is copied.
        let bgBinding = $sheetBackground
        let needsDetection = theme.backgroundColor == nil
        return VoiceboxRepresentable(
            handle: handle,
            params: params,
            theme: theme,
            presentationMode: presentationMode,
            showCloseButton: showCloseButton,
            autoGrantMicPermission: autoGrantMicPermission,
            onRecordingComplete: onRecordingComplete,
            onMessageSubmitted: onMessageSubmitted,
            onDismiss: onDismiss,
            onBackgroundColorDetected: needsDetection ? { color in
                // Already dispatched to main in userContentController; update inline
                // so the presentationBackground and skeleton stop in the same pass.
                bgBinding.wrappedValue = Color(uiColor: color)
            } : nil
        )
    }

    func body(content: Content) -> some View {
        Group {
            switch presentationMode {
            case .fullScreen:
                content.fullScreenCover(isPresented: $isPresented) {
                    makeRepresentable()
                        .ignoresSafeArea(edges: .bottom)
                }
            case .bottomSheet:
                content.sheet(isPresented: $isPresented) {
                    applyDetents(makeRepresentable(), style: .mediumAndLarge)
                }
            case .sheet, .fitContent:
                content.sheet(isPresented: $isPresented) {
                    applyDetents(makeRepresentable(), style: .large)
                }
            case .custom(let height):
                content.sheet(isPresented: $isPresented) {
                    applyDetents(makeRepresentable(), style: .fixedHeight(height))
                }
            case .customFraction(let fraction):
                content.sheet(isPresented: $isPresented) {
                    applyDetents(makeRepresentable(), style: .fraction(fraction))
                }
            }
        }
        // When the sheet dismisses, reset the background so the next open always
        // starts white — matching the skeleton's white background.
        // The colour is re-detected and applied fresh once the page reloads.
        .onChange(of: isPresented) { presented in
            if !presented, theme.backgroundColor == nil {
                sheetBackground = Color(uiColor: .systemBackground)
            }
        }
    }

    private enum DetentStyle {
        case mediumAndLarge
        case large
        case fixedHeight(CGFloat)
        case fraction(CGFloat)
    }

    @ViewBuilder
    private func applyDetents(_ view: VoiceboxRepresentable, style: DetentStyle) -> some View {
        if #available(iOS 16.4, *) {
            view
                .ignoresSafeArea(.container, edges: .bottom)
                .presentationDetents(detentSet(for: style))
                .presentationCornerRadius(theme.resolvedCornerRadius)
                .presentationDragIndicator(.visible)
                .presentationBackground(effectivePresentationBackground)
        } else if #available(iOS 16.0, *) {
            view
                .ignoresSafeArea(.container, edges: .bottom)
                .presentationDetents(detentSet(for: style))
                .presentationDragIndicator(.visible)
                .background(effectivePresentationBackground)
        } else {
            view
                .ignoresSafeArea(.container, edges: .bottom)
                .background(effectivePresentationBackground)
        }
    }

    @available(iOS 16.0, *)
    private func detentSet(for style: DetentStyle) -> Set<PresentationDetent> {
        switch style {
        case .mediumAndLarge:
            return [.medium, .large]
        case .large:
            return [.large]
        case .fixedHeight(let height):
            return [.height(height)]
        case .fraction(let fraction):
            let clamped = max(0.1, min(1.0, fraction))
            return [.fraction(clamped)]
        }
    }
}

// MARK: - UIViewControllerRepresentable

struct VoiceboxRepresentable: UIViewControllerRepresentable {
    let handle: String
    var params: [String: String]
    var theme: VoiceboxTheme
    var presentationMode: VoiceboxPresentationMode
    var showCloseButton: Bool
    var autoGrantMicPermission: Bool?
    var onRecordingComplete: (() -> Void)?
    var onMessageSubmitted: (() -> Void)?
    var onDismiss: (() -> Void)?
    /// Forwarded from `VoiceboxModifier` — updates `presentationBackground` reactively.
    var onBackgroundColorDetected: ((UIColor) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onRecordingComplete: onRecordingComplete,
            onMessageSubmitted: onMessageSubmitted,
            onDismiss: onDismiss
        )
    }

    func makeUIViewController(context: Context) -> VoiceboxViewController {
        let voiceboxView = VoiceboxView(
            handle: handle,
            params: params,
            theme: theme
        )
        voiceboxView.presentationMode = presentationMode
        voiceboxView.showCloseButton = showCloseButton
        voiceboxView.autoGrantMicPermission = autoGrantMicPermission
        voiceboxView.delegate = context.coordinator
        let vc = VoiceboxViewController(voiceboxView: voiceboxView)
        vc.onBackgroundColorDetected = onBackgroundColorDetected
        return vc
    }

    func updateUIViewController(_ uiViewController: VoiceboxViewController, context: Context) {
        // Keep the callback in sync in case the SwiftUI tree re-renders.
        uiViewController.onBackgroundColorDetected = onBackgroundColorDetected
    }

    // MARK: - Coordinator (Delegate Bridge)

    /// Bridges `VoiceboxDelegate` callbacks to SwiftUI closures.
    final class Coordinator: NSObject, VoiceboxDelegate {
        var onRecordingComplete: (() -> Void)?
        var onMessageSubmitted: (() -> Void)?
        var onDismiss: (() -> Void)?

        init(
            onRecordingComplete: (() -> Void)?,
            onMessageSubmitted: (() -> Void)?,
            onDismiss: (() -> Void)?
        ) {
            self.onRecordingComplete = onRecordingComplete
            self.onMessageSubmitted = onMessageSubmitted
            self.onDismiss = onDismiss
        }

        func voiceboxDidFinishRecording(_ voiceboxView: VoiceboxView) {
            onRecordingComplete?()
        }

        func voiceboxDidSubmitMessage(_ voiceboxView: VoiceboxView) {
            onMessageSubmitted?()
        }

        func voiceboxDidDismiss(_ voiceboxView: VoiceboxView) {
            onDismiss?()
        }
    }
}

// MARK: - View Extension

public extension View {

    /// Presents a Voicebox recording experience.
    ///
    /// ```swift
    /// Button("Feedback") { showVoicebox = true }
    ///     .voicebox(
    ///         isPresented: $showVoicebox,
    ///         handle: "alice-feedback",
    ///         onRecordingComplete: { print("Recording done!") },
    ///         onMessageSubmitted: { print("Message saved!") },
    ///         onDismiss: { print("Dismissed") }
    ///     )
    /// ```
    ///
    /// - Parameters:
    ///   - isPresented: Binding that controls visibility.
    ///   - handle: The Voicebox handle. **Required.**
    ///   - params: Key-value pairs appended to the Voicebox URL.
    ///   - theme: Visual theme. Uses defaults if omitted.
    ///   - presentationMode: How to present the Voicebox. Default is `.bottomSheet`.
    ///   - showCloseButton: Whether to show the close button. Default is `true`.
    ///   - autoGrantMicPermission: Per-instance mic permission override. `nil` uses global default.
    ///   - onRecordingComplete: Called when the user finishes recording.
    ///   - onMessageSubmitted: Called when the recording is submitted/saved.
    ///   - onDismiss: Called when the Voicebox view is dismissed.
    func voicebox(
        isPresented: Binding<Bool>,
        handle: String,
        params: [String: String] = [:],
        theme: VoiceboxTheme = VoiceboxTheme(),
        presentationMode: VoiceboxPresentationMode = .bottomSheet,
        showCloseButton: Bool = true,
        autoGrantMicPermission: Bool? = nil,
        onRecordingComplete: (() -> Void)? = nil,
        onMessageSubmitted: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) -> some View {
        modifier(
            VoiceboxModifier(
                isPresented: isPresented,
                handle: handle,
                params: params,
                theme: theme,
                presentationMode: presentationMode,
                showCloseButton: showCloseButton,
                autoGrantMicPermission: autoGrantMicPermission,
                onRecordingComplete: onRecordingComplete,
                onMessageSubmitted: onMessageSubmitted,
                onDismiss: onDismiss
            )
        )
    }
}
