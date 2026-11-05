import SwiftUI

/// Small section heading — the iOS twin of the Android example's `SectionLabel`.
struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }
}

/// Full-width filled button, matching the Material filled buttons the Android
/// example uses for its presentation modes.
struct FilledButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.accentColor)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Full-width outlined button — Material's `OutlinedButton`.
struct OutlinedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundColor(.accentColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// The card that flashes the latest callback, as on Android. Clears itself
/// after three seconds.
struct StatusCard: View {
    let message: String
    let isFailure: Bool

    var body: some View {
        Text(message)
            .font(.subheadline)
            .foregroundColor(isFailure ? Color(uiColor: .systemRed) : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isFailure
                          ? Color(uiColor: .systemRed).opacity(0.12)
                          : Color.accentColor.opacity(0.12))
            )
    }
}
