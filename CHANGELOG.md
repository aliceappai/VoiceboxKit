# Changelog

All notable changes to VoiceboxKit will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
