# Changelog

All notable changes to VoiceboxKit will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.2]

### Added

- Pre-built "hot spare" WebView so an open we could not predict (a Directory card or map
  pin, where the handle is unknown until the tap) skips WKWebView construction and
  WebContent process launch. Measured 0.6–3.2 s of every such open before any network
  request; now 13–16 ms on device. Created only after real SDK use, released on memory
  warning and on backgrounding.
- Tapping a voicebox whose warm-up is still in flight now joins that load instead of
  abandoning it and starting a competing one for the same URL. Measured 5.1 s -> 1.3 s.

### Changed

- The recorder is revealed once its DOM is parsed and styled, rather than when the window
  `load` event fires. The straggling requests (visualizer, ActionCable, analytics, error
  reporting) change nothing on screen — on one measured device open this showed content
  1,452 ms earlier.
- Floating-card entrance retimed to match standard iOS modal transitions: background reveal
  1.2 s -> 0.35 s, card lift-in 850 ms/180 ms delay -> 300 ms/60 ms. The entrance plays
  after content is ready, so on a preload hit (~14 ms) the animation *was* the entire
  perceived open. Reduce Motion still skips both.
- The preloaded-WebView pool is capped at 4 with least-recently-warmed eviction. It was
  unbounded, and each entry retains a whole WebContent process.

### Fixed

- The recorder no longer renders the public Voicebox directory inside its own sheet. vbx-web
  answers an unknown or unavailable `/@handle` with a 303 to the directory root, preserving
  the query string, which was indistinguishable from a normal load. Both the live and the
  warm path now verify the document is still this handle's recorder; the live path cancels
  and reports `voiceboxDidFail`, and the warm path fails so it can never be handed out as a
  cache hit (which opened straight onto the browse page with no load and no error).

## [1.1.1]

### Fixed

- Floating card: the recorder now avoids the keyboard by shrinking the WebView so
  the card re-centres above it, instead of scrolling the page up and revealing the
  chrome behind the card.
- Floating card: the voicebox's background (colour or image) is now painted on a
  native layer behind the WebView, so it always fills the screen — including behind
  the keyboard. Previously the background sat on a `position: fixed` web layer that
  WKWebView mis-positions during a keyboard resize, letting the underlying app show
  through.
- Floating card: the close button is positioned via a real nav-bar item so it lines
  up with the host app's own nav buttons on any screen (and the iOS 26 shared glass
  background behind it is suppressed).
- Floating card: removed WKWebView's default keyboard accessory bar (the prev/next/
  Done toolbar) on the recorder's contact form.

## [1.1.0]

### Added

- `.floatingCard(dimOpacity:)` presentation mode — presents the recorder as a
  glass-free floating card centered over a caller-controlled dim, with **no**
  `UISheetPresentationController` (and therefore no iOS 26 system glass/blur).
  The voicebox's own background — colour or full-screen image — renders behind
  the card. Dismiss is a top-right close button when `showCloseButton` is `true`,
  otherwise a tap outside the card.
- `VoiceboxEntranceAnimation` — configurable floating-card entrance (background
  reveal + card lift-in, combinable via `OptionSet`; respects Reduce Motion).
- Recorder close button for the floating card: a solid circular chip (theme-driven
  via `closeButtonBackgroundColor` / `closeButtonIconColor` / `closeButtonSize`)
  with a soft drop shadow so it stays legible over any background — a plain light
  card or a full-screen image. When shown it becomes the single dismiss affordance
  and the tap-outside bridge is dropped.
- `hidePageChrome` renders the voicebox's configured background (image or colour)
  while hiding only the recorder page's footer.

### Changed

- Unified the live and preloaded WebView configuration so a warmed WebView is
  wired identically to a fresh one — more robust, faster loading.
- Added a card-shaped loading skeleton for the floating card (the full-width sheet
  shimmer read as broken over a transparent, centered card).
- `.fitContent` now hugs the recorder card and re-fits live as its content changes.

## [1.0.6]

### Added

- `VoiceboxKit.keepsScreenAwake` (default `false`) keeps the screen awake while a
  Voicebox is presented, restoring normal auto-lock when it closes. A recording can
  run for two minutes but iOS auto-lock is commonly 30s–1min, so a long take could
  be cut off by the device locking — and the recording does not survive it, because
  capture stops as soon as the app leaves the foreground. Hosts that record should
  set this to `true` at launch.

  Opt-in rather than on by default: `isIdleTimerDisabled` is process-global state
  the host owns, so upgrading the SDK must not change device behaviour on its own
  (same shape as `autoGrantMicPermission`). Overridable per instance via
  `VoiceboxView.keepsScreenAwake`.

  Note this prevents *auto-lock* only — a manual lock, app switch, or incoming call
  still interrupt a recording. It also tracks the Voicebox being presented rather
  than actively recording, since the SDK is not told when recording starts.

## [1.0.5]

### Fixed

- Documented that host apps must declare `NSLocationWhenInUseUsageDescription`
  for the recorder's opt-in "Share precise location" toggle
  (`navigator.geolocation` in WKWebView). Without that key, WebKit never shows
  the system location prompt and the toggle stalls on "Locating…".

## [1.0.4]

### Fixed

- `preload(handle:)` had no way to match the URL the recording sheet would
  actually request — the sheet always adds `params`, auto-collected app
  context, and UTM tags to build its URL, so a preloaded page built from a
  bare `handle` never matched, and every sheet open silently fell back to a
  full network load with the loading skeleton shown, regardless of preload.
  `preload(handle:params:)` now takes the same `params` the sheet will use,
  so the URLs can actually match.
- A preloaded WebView is now only reused once its background load is
  confirmed to have finished successfully. Previously, a preload that failed
  silently before a navigation delegate was attached could be mistaken for a
  successful load once consumed, showing a blank sheet with no offline/retry
  UI.
- `.fitContent` sheets now open at roughly the size measured on the last
  successful load for that handle, instead of always starting full-screen
  and shrinking down after the page finishes loading.

## [1.0.3]

### Fixed

- Coloured strip below the page in `.bottomSheet`, `.sheet`, `.fitContent`,
  `.custom`, and `.customFraction` modes. The SwiftUI sheet's
  `presentationBackground` was painting the home-indicator strip below where
  the WebView ended, so the page's body / background-image stopped short and
  the underlying CSS fallback colour leaked through. The WebView now extends
  into the bottom safe area via `.ignoresSafeArea(.container, edges: .bottom)`,
  so the page's body covers the strip.
- Same strip issue at the bottom of `.fullScreen` mode — `fullScreenCover`
  now also applies `.ignoresSafeArea(edges: .bottom)`.
- Wrong colour detected on iOS (e.g. blue strip when the web page showed
  grey). iOS WKWebView returns a non-transparent value for
  `getComputedStyle(documentElement).backgroundColor` even when only `<body>`
  is styled. The detection JS now reads `<body>` first and falls back to
  `<html>` only if body is transparent — `<body>` is what the customize
  helper actually styles, so it is the source of truth.

## [1.0.2]

### Changed

- `VoiceboxKit.baseURL` is now a public mutable property (was internal `let`),
  so host apps can point the SDK at a non-production environment such as
  staging. Defaults to `https://vbx.to`. Set once at app launch before any
  `preload(handle:)` or `.voicebox(...)` call.
- Navigation allowlist now accepts the configured `baseURL` host (and its
  subdomains) in addition to the existing `vbx.to` and `voicebox.ai`
  production domains. Fixes staging builds where loads to non-production
  hosts were silently cancelled (`NSURLErrorCancelled`, `-999`), causing a
  white screen on first sheet open.

## [1.0.0]

### Added

**Core**
- `VoiceboxView` with handle-based initialization and URL param support
- URL format: `https://vbx.to/@{handle}` with auto-encoded params and UTM tags
- `VoiceboxViewController` for embedding in custom containers
- Unified `present(from:)` method for UIKit
- SwiftUI `.voicebox()` view modifier

**Presentation Modes**
- Six presentation modes via `VoiceboxPresentationMode`:
  - `.bottomSheet` — medium + large detents (default)
  - `.sheet` — large detent only
  - `.fullScreen` — full-screen modal
  - `.fitContent` — auto-sized to web content (iOS 16+)
  - `.custom(height:)` — fixed height in points (iOS 16+)
  - `.customFraction(_)` — fraction of screen height, clamped `[0.1, 1.0]` (iOS 16+)
- iOS 15 fallback to `.sheet` for all custom-height modes
- `VoiceboxPresentationMode` conforms to `Equatable`

**Auto-collected App Context**
- Automatic collection of non-PII app/device identity for feedback triage
- Collected: `bundleID`, `appName`, `appVersion`, `buildNumber`, `platform`, `osVersion`, `deviceModel`, `locale`, `sdkVersion`
- `deviceModel` uses hardware identifier (e.g., `iPhone16,2`) via `utsname`
- Global opt-out flag: `VoiceboxKit.autoCollectAppContext` (default `true`)
- App-provided `params` always override auto-collected values

**Lifecycle**
- `VoiceboxDelegate` protocol with optional callbacks: `voiceboxDidFinishRecording`, `voiceboxDidSubmitMessage`, `voiceboxDidDismiss`, `voiceboxDidFail`
- SwiftUI closures: `onRecordingComplete`, `onMessageSubmitted`, `onDismiss`
- JS-based button click detection for Save (`#record-btn-send`) and Send (`editSubmitButton`) actions

**Theming**
- `VoiceboxTheme` with all properties optional (`nil` = use SDK default)
- Close button customization: `closeButtonIconColor`, `closeButtonBackgroundColor`, `closeButtonSize`, `closeButtonSymbolName`
- Sheet customization: `cornerRadius`, `backgroundColor`
- Built-in presets: `.plain`, `.darkCircle`, `.lightCircle`
- Accessibility label on close button (`"Close"`)

**Performance & Caching**
- `VoiceboxKit.preload(handle:)` for cache warming on app launch
- ETag/Last-Modified cache validation with background refresh
- Preloaded WKWebView reuse for instant display on button tap
- Auto-warming of replacement WebView after consumption

**Microphone Permission**
- Configurable mic permission: `VoiceboxKit.autoGrantMicPermission` (global) and per-instance override
- `WKUIDelegate` auto-grant for WebView mic permission when native permission is granted
- Prevents double-prompt when host app already has mic access

**Networking**
- Navigation policy blocking all external links (allows `vbx.to` and `voicebox.ai` domains)
- Custom User-Agent: `VoiceboxKit/{version} iOS/{version}`
- Reachability-based offline detection (`SCNetworkReachability`)

**Loading & Error States**
- Shimmer skeleton loading view during WebView load
- Native offline fallback UI with retry button
- Disabled text selection and long-press context menus in WebView

**Distribution**
- Swift Package Manager support (iOS 15+, zero dependencies)

**Documentation**
- `README.md` — Quick start, presentation modes, theming, preloading, mic permission
- `PARAMS.md` — Full param reference with auto-collected markers
- `CHANGELOG.md` — This file
