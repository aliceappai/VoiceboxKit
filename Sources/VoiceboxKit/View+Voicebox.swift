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
    /// Whether the sheet's drag grabber (the pill at the top edge) is shown.
    /// Set `false` for a "just the card" look with no native sheet chrome.
    var showDragIndicator: Bool
    /// Forwarded to `VoiceboxView.hidePageChrome` — hides the recorder page's
    /// own footer + background via CSS injection. See that property's docs.
    var hidePageChrome: Bool
    /// Forwarded to `VoiceboxView.entranceAnimation` — floating-card entrance.
    var entranceAnimation: VoiceboxEntranceAnimation
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
            hidePageChrome: hidePageChrome,
            entranceAnimation: entranceAnimation,
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
            case .floatingCard:
                // Presented via UIKit `.overFullScreen` + `.crossDissolve` (see
                // FloatingCardPresenter) rather than a sheet or fullScreenCover:
                // no UISheetPresentationController → no glass backdrop, AND the
                // transition is a fade (present + dismiss) instead of the tell-tale
                // sheet slide-up. The dim/card layout is painted by the web page.
                content.background(
                    FloatingCardPresenter(isPresented: $isPresented, build: makeFloatingCardController)
                )
            case .bottomSheet:
                content.sheet(isPresented: $isPresented) {
                    applyDetents(makeRepresentable(), style: .mediumAndLarge)
                }
            case .sheet:
                content.sheet(isPresented: $isPresented) {
                    applyDetents(makeRepresentable(), style: .large)
                }
            case .fitContent:
                content.sheet(isPresented: $isPresented) {
                    applyDetents(makeRepresentable(), style: initialFitContentStyle)
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

    /// Builds a fully-configured `VoiceboxViewController` for `.floatingCard`
    /// presentation, plus the bridging delegate that must be retained alongside
    /// it (`VoiceboxView.delegate` is `weak`). Returned to `FloatingCardPresenter`,
    /// which presents the controller over the current context with a crossfade.
    private func makeFloatingCardController() -> (VoiceboxViewController, AnyObject) {
        let coordinator = VoiceboxRepresentable.Coordinator(
            onRecordingComplete: onRecordingComplete,
            onMessageSubmitted: onMessageSubmitted,
            onDismiss: onDismiss
        )
        let vbView = VoiceboxView(handle: handle, params: params, theme: theme)
        vbView.presentationMode = presentationMode
        vbView.showCloseButton = showCloseButton
        vbView.hidePageChrome = hidePageChrome
        vbView.entranceAnimation = entranceAnimation
        vbView.autoGrantMicPermission = autoGrantMicPermission
        vbView.delegate = coordinator
        return (VoiceboxViewController(voiceboxView: vbView), coordinator)
    }

    private enum DetentStyle {
        case mediumAndLarge
        case large
        case fixedHeight(CGFloat)
        case fraction(CGFloat)
    }

    /// Best starting size for `.fitContent`: the height measured the last time
    /// this handle finished loading (see `VoiceboxCache.cachedContentHeight`),
    /// so a slow/uncached load doesn't have to flash full-screen before
    /// shrinking to fit. Falls back to `.large` the first time a handle is
    /// ever opened — there's nothing to go on yet. Either way, the real
    /// measurement after load corrects this once the page finishes.
    private var initialFitContentStyle: DetentStyle {
        if let cachedHeight = VoiceboxCache.shared.cachedContentHeight(for: handle) {
            return .fixedHeight(cachedHeight)
        }
        return .large
    }

    /// `true` when the caller explicitly wants a transparent sheet (e.g. `theme.backgroundColor = .clear`).
    /// `presentationBackground(_:)` substitutes its own system blur/vibrancy material whenever it's
    /// given a fully-transparent color — there's no flag to opt out of that. Falling back to a plain
    /// `.background()` (same as the pre-iOS-16.4 path below) instead avoids that substitution and
    /// paints genuine transparency, at the cost of `presentationBackground`'s home-indicator-strip
    /// coloring, which no longer matters once the caller has asked for "no chrome" anyway.
    private var wantsTrueTransparency: Bool {
        (theme.backgroundColor?.cgColor.alpha ?? 1) <= 0.001
    }

    @ViewBuilder
    private func applyDetents(_ view: VoiceboxRepresentable, style: DetentStyle) -> some View {
        if wantsTrueTransparency, #available(iOS 16.0, *) {
            view
                .ignoresSafeArea(.container, edges: .bottom)
                .presentationDetents(detentSet(for: style))
                .presentationDragIndicator(showDragIndicator ? .visible : .hidden)
                .background(effectivePresentationBackground)
        } else if #available(iOS 16.4, *) {
            view
                .ignoresSafeArea(.container, edges: .bottom)
                .presentationDetents(detentSet(for: style))
                .presentationCornerRadius(theme.resolvedCornerRadius)
                .presentationDragIndicator(showDragIndicator ? .visible : .hidden)
                .presentationBackground(effectivePresentationBackground)
        } else if #available(iOS 16.0, *) {
            view
                .ignoresSafeArea(.container, edges: .bottom)
                .presentationDetents(detentSet(for: style))
                .presentationDragIndicator(showDragIndicator ? .visible : .hidden)
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
    var hidePageChrome: Bool
    var entranceAnimation: VoiceboxEntranceAnimation
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
        voiceboxView.hidePageChrome = hidePageChrome
        voiceboxView.entranceAnimation = entranceAnimation
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

// MARK: - Floating Card Presenter

/// Drives a UIKit `.overFullScreen` + `.crossDissolve` presentation of the
/// Voicebox controller from a SwiftUI `isPresented` binding — used only by
/// `.floatingCard`. A sheet/`fullScreenCover` would either add the system glass
/// backdrop (sheet) or slide up from the bottom (cover); this fades in and out
/// with no glass, matching the "floating card" look.
///
/// It's placed in the content's `.background`, so its host controller sits in
/// the view hierarchy and can present modally over the whole window.
private struct FloatingCardPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    /// Builds the controller to present plus the delegate to retain (the
    /// controller's `VoiceboxView.delegate` is `weak`).
    let build: () -> (VoiceboxViewController, AnyObject)

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        let coordinator = context.coordinator
        if isPresented {
            // Present once — guard against re-presenting on every SwiftUI update.
            guard coordinator.presented == nil else { return }
            let (vc, delegate) = build()
            coordinator.presented = vc
            coordinator.retainedDelegate = delegate
            vc.modalPresentationStyle = .overFullScreen
            vc.modalTransitionStyle = .crossDissolve
            // Tap-outside dismiss (or any self-dismiss): sync the binding back.
            vc.onDidDismissSelf = { [weak coordinator] in
                coordinator?.presented = nil
                coordinator?.retainedDelegate = nil
                if isPresented { isPresented = false }
            }
            DispatchQueue.main.async {
                // Present from the top-most controller so we never try to
                // present while something else already is.
                var presenter: UIViewController = host
                while let next = presenter.presentedViewController { presenter = next }
                guard presenter.presentedViewController == nil else { return }
                presenter.present(vc, animated: true)
            }
        } else if let vc = coordinator.presented {
            // Binding-driven dismiss: tear down without re-entering the
            // self-dismiss path (we've already reflected the state).
            coordinator.presented = nil
            coordinator.retainedDelegate = nil
            vc.onDidDismissSelf = nil
            vc.dismiss(animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var presented: VoiceboxViewController?
        var retainedDelegate: AnyObject?
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
    ///   - showDragIndicator: Whether the sheet's drag grabber is shown. Default is `true`.
    ///   - hidePageChrome: Hides the recorder page's own footer + background via CSS
    ///     injection, for a "just the card" look. Default is `false`. See
    ///     `VoiceboxView.hidePageChrome` for caveats.
    ///   - entranceAnimation: Entrance animation(s) for `.floatingCard` mode.
    ///     Default `.all` (background reveal + card lift-in). Ignored by sheet modes.
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
        showDragIndicator: Bool = true,
        hidePageChrome: Bool = false,
        entranceAnimation: VoiceboxEntranceAnimation = .all,
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
                showDragIndicator: showDragIndicator,
                hidePageChrome: hidePageChrome,
                entranceAnimation: entranceAnimation,
                autoGrantMicPermission: autoGrantMicPermission,
                onRecordingComplete: onRecordingComplete,
                onMessageSubmitted: onMessageSubmitted,
                onDismiss: onDismiss
            )
        )
    }
}
