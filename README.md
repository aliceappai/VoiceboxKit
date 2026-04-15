# VoiceboxKit

Drop-in Voicebox recording experience for iOS apps. Wraps a WKWebView with zero browser chrome, aggressive caching, and flexible presentation modes.

## Requirements

- iOS 15.0+
- Swift 5.7+
- Xcode 14+

## Installation

### Swift Package Manager

Add VoiceboxKit to your project via **File > Add Package Dependencies** in Xcode:

```
https://github.com/aliceappai/VoiceboxKit.git
```

Or add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/aliceappai/VoiceboxKit.git", from: "1.0.0")
]
```

## Quick Start

### SwiftUI

```swift
import SwiftUI
import VoiceboxKit

struct FeedbackButton: View {
    @State private var showVoicebox = false

    var body: some View {
        Button("Ideas & Feedback") {
            showVoicebox = true
        }
        .voicebox(
            isPresented: $showVoicebox,
            handle: "alice-feedback"
        )
    }
}
```

### SwiftUI — tap gesture on any view

`.voicebox()` is a view modifier driven by a `Bool` binding — anything that flips the binding presents the sheet, not just `Button`.

```swift
struct FeedbackCard: View {
    @State private var showVoicebox = false

    var body: some View {
        HStack {
            Image(systemName: "quote.bubble.fill")
            Text("Share Feedback")
            Spacer()
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .contentShape(Rectangle())  // make whole card tappable
        .onTapGesture { showVoicebox = true }
        .voicebox(isPresented: $showVoicebox, handle: "alice-feedback")
    }
}
```

### UIKit

```swift
import VoiceboxKit

let vb = VoiceboxView(handle: "alice-feedback")
vb.presentAsSheet(from: self)
```

## Auto-Collected App Context

VoiceboxKit automatically attaches app identity and device context to every recording, so you can immediately see *which app, which version, which OS* a piece of feedback came from — without writing any code.

**Collected automatically** (non-PII, no permissions required):

| Param | Source |
|---|---|
| `bundleID` | `Bundle.main.bundleIdentifier` |
| `appName` | `CFBundleDisplayName` → `CFBundleName` |
| `appVersion` | `CFBundleShortVersionString` |
| `buildNumber` | `CFBundleVersion` |
| `platform` | `"ios"` |
| `osVersion` | `UIDevice.current.systemVersion` |
| `deviceModel` | Hardware identifier (e.g., `iPhone16,2`) |
| `locale` | `Locale.current.identifier` |
| `sdkVersion` | VoiceboxKit SDK version |

Auto-collection is **on by default**. Opt out with:

```swift
VoiceboxKit.autoCollectAppContext = false
```

App-provided params always override auto-collected values (explicit wins over implicit).

## Passing Custom Params

On top of auto-collected context, pass any additional key-value pairs you want:

```swift
.voicebox(
    isPresented: $showVoicebox,
    handle: "alice-feedback",
    params: [
        "email":  currentUser.email,
        "userID": currentUser.id,
        "screen": "settings",
        "ll":     "\(location.latitude),\(location.longitude)",
        "prompt": "How are you liking Alice?",

        // Any custom keys you want
        "plan":             "pro",
        "experimentGroup":  "variant_b",
        "featureFlag_newUI": "true"
    ]
)
```

All values must be `String`. They're URL-encoded and appended to `https://vbx.to/@{handle}`. See [PARAMS.md](PARAMS.md) for the full list of recognized keyword params.

## Presentation Modes

```swift
// Bottom sheet with medium + large detents (default)
.voicebox(isPresented: $show, handle: "feedback", presentationMode: .bottomSheet)

// Standard sheet at large height only
.voicebox(isPresented: $show, handle: "feedback", presentationMode: .sheet)

// Full-screen modal
.voicebox(isPresented: $show, handle: "feedback", presentationMode: .fullScreen)

// Auto-sized sheet matching web content height (iOS 16+)
.voicebox(isPresented: $show, handle: "feedback", presentationMode: .fitContent)

// Fixed custom height in points (iOS 16+)
.voicebox(isPresented: $show, handle: "feedback", presentationMode: .custom(height: 520))

// Fraction of screen height (iOS 16+)
.voicebox(isPresented: $show, handle: "feedback", presentationMode: .customFraction(0.6))
```

All custom-height modes fall back to `.sheet` on iOS 15. `.customFraction` values are clamped to `[0.1, 1.0]`.

UIKit equivalent:

```swift
let vb = VoiceboxView(handle: "alice-feedback")
vb.presentationMode = .custom(height: 520)
vb.present(from: viewController)
```

## Lifecycle Callbacks

### SwiftUI

```swift
.voicebox(
    isPresented: $show,
    handle: "alice-feedback",
    onRecordingComplete: { print("Recording saved") },
    onMessageSubmitted: { print("Message sent") },
    onDismiss: { print("Dismissed") }
)
```

### UIKit (Delegate)

```swift
let vb = VoiceboxView(handle: "alice-feedback")
vb.delegate = self
vb.present(from: self)

// VoiceboxDelegate
func voiceboxDidFinishRecording(_ voiceboxView: VoiceboxView) { }
func voiceboxDidSubmitMessage(_ voiceboxView: VoiceboxView) { }
func voiceboxDidDismiss(_ voiceboxView: VoiceboxView) { }
func voiceboxDidFail(_ voiceboxView: VoiceboxView, error: Error) { }
```

All delegate methods are optional.

## Preloading

For instant load times, call `preload` during app launch:

```swift
VoiceboxKit.preload(handle: "alice-feedback")
```

This fetches and caches the full page and warms a WKWebView for reuse. The SDK validates the cache on each launch using ETag/Last-Modified headers and refreshes stale content in the background.

## Microphone Permission

Add the following to your app's `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Record voice feedback</string>
```

For apps that already have native mic access, auto-grant the WebView mic permission to avoid a double prompt:

```swift
// Global (all instances)
VoiceboxKit.autoGrantMicPermission = true

// Per-instance override
.voicebox(isPresented: $show, handle: "feedback", autoGrantMicPermission: true)
```

## Theming

All `VoiceboxTheme` properties are optional — set only what you want to override. `nil` means "use SDK default".

```swift
// Only override the close button — everything else uses SDK defaults
let theme = VoiceboxTheme(
    closeButtonIconColor: .white,
    closeButtonBackgroundColor: .systemBlue,
    closeButtonSize: 36
)

.voicebox(isPresented: $show, handle: "feedback", theme: theme)
```

| Property | Default | Purpose |
|---|---|---|
| `cornerRadius` | `16` | Sheet corner radius |
| `backgroundColor` | `.systemBackground` | WebView + sheet background |
| `closeButtonIconColor` | `.label` | Color of the `×` icon |
| `closeButtonBackgroundColor` | `nil` (transparent) | Circle chip behind the `×` |
| `closeButtonSize` | `32` | Close button diameter in points |
| `closeButtonSymbolName` | `"xmark"` | SF Symbol name for the close icon |

### Theme presets

```swift
// Default — transparent icon-only close button
VoiceboxView(handle: "feedback", theme: .plain)

// Dark filled circle with white ×
VoiceboxView(handle: "feedback", theme: .darkCircle)

// Light gray circle with dark ×
VoiceboxView(handle: "feedback", theme: .lightCircle)
```

## Offline Support

If the network is unavailable and no cached content exists, VoiceboxKit displays a native offline fallback UI with a retry button. Cached content is always served first when available.

## License

VoiceboxKit is available under the MIT license. See [LICENSE](LICENSE) for details.
