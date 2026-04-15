# Voicebox Reserved Keyword Params

These are the reserved keyword parameters that the Voicebox recorder understands. Pass them via the `params` dictionary when creating a `VoiceboxView` or using the `.voicebox()` SwiftUI modifier. All values are URL-encoded and appended as query string to `https://vbx.to/@{handle}`.

> **Auto-collection:** Params marked 🤖 are collected automatically by VoiceboxKit. You don't need to set them — but any explicit value you pass will override the auto-collected one.

---

## Identity Params

### `email`
Email address of the user submitting the recording. Used to associate feedback with a known user account.
> Dashboard column: **Email**

### `userID`
Unique identifier for the user in the host app's system (e.g., `usr_abc123`). Used to link recordings to user profiles.
> Dashboard column: **User ID**

### `name`
Display name of the user. Shown alongside the recording on the dashboard.
> Dashboard column: **Name**

### `phone`
Phone number of the user. Optional contact info stored with the recording.
> Dashboard column: **Phone**

---

## Context Params

### `prompt`
The question or prompt shown to the user before they record. Overrides the server-configured prompt for this session.

**Example:** `"How are you liking Alice?"`
> Dashboard column: **Prompt**

### `ll`
Latitude and longitude as a comma-separated string. Captures the user's location at the time of recording.

**Example:** `"47.6062,-122.3321"`
> Dashboard column: **Location**

### 🤖 `locale`
Locale identifier. Helps with transcription language selection. Auto-collected from `Locale.current.identifier`.

**Example:** `"en_US"`, `"fr_FR"`
> Dashboard column: **Locale**

### `tags`
Comma-separated tags to categorize the recording.

**Example:** `"feedback,v2,onboarding"`
> Dashboard column: **Tags**

---

## App Context Params

### 🤖 `bundleID`
Bundle identifier of the host app. Auto-collected from `Bundle.main.bundleIdentifier`.

**Example:** `"com.acme.myapp"`
> Dashboard column: **Bundle ID**

### 🤖 `appName`
User-visible name of the host app. Auto-collected from `CFBundleDisplayName` (falls back to `CFBundleName`).

**Example:** `"My App"`
> Dashboard column: **App**

### 🤖 `appVersion`
Marketing version of the host app. Useful for filtering feedback by release. Auto-collected from `CFBundleShortVersionString`.

**Example:** `"2.1.0"`
> Dashboard column: **App Version**

### 🤖 `buildNumber`
Build number of the host app. Auto-collected from `CFBundleVersion`.

**Example:** `"147"`
> Dashboard column: **Build**

### `screen`
Name or identifier of the screen where the recording was initiated. Set this per-instance to help triage which part of the app generated the feedback.

**Example:** `"settings"`, `"checkout"`
> Dashboard column: **Screen**

### `sessionID`
Session identifier from the host app. Used to correlate recordings with analytics sessions.
> Dashboard column: **Session ID**

---

## Device Context Params (Auto-collected)

These are attached automatically and cannot normally be set manually. Useful for triaging feedback across device types and OS versions.

### 🤖 `platform`
Always `"ios"` when coming from VoiceboxKit.
> Dashboard column: **Platform**

### 🤖 `osVersion`
iOS version string. Auto-collected from `UIDevice.current.systemVersion`.

**Example:** `"17.2"`
> Dashboard column: **OS Version**

### 🤖 `deviceModel`
Hardware model identifier. Auto-collected from `utsname.machine`. More useful than `UIDevice.current.model` because it identifies the specific hardware generation.

**Example:** `"iPhone16,2"` (iPhone 15 Pro Max)
> Dashboard column: **Device**

### 🤖 `sdkVersion`
Version of VoiceboxKit that captured the recording. Useful for correlating feedback with SDK-level bugs or behavior.

**Example:** `"1.0.0"`
> Dashboard column: **SDK Version**

---

## Custom Params

Any additional key-value pairs not listed above are stored as custom metadata on the recording and appear in the **Custom Fields** section of the Voicebox dashboard.

```swift
params: [
    "email":     "jane@example.com",
    "userID":    "usr_abc123",
    "prompt":    "How are you liking Alice?",
    "ll":        "47.6062,-122.3321",
    "plan":      "pro",           // custom field
    "teamSize":  "12"             // custom field
]
```

---

## Disabling auto-collection

To opt out of all auto-collected params (e.g., for strict-privacy apps):

```swift
VoiceboxKit.autoCollectAppContext = false
```

When disabled, only UTM params are attached automatically — you're responsible for passing any other context via `params:`.

---

## UTM Params (Auto-appended)

VoiceboxKit always appends the following parameters, regardless of `autoCollectAppContext`. Do **not** set these manually:

- **`utm_source`** = `voiceboxkit` — Identifies the SDK as the source
- **`utm_medium`** = `ios_sdk` — Identifies the iOS platform
