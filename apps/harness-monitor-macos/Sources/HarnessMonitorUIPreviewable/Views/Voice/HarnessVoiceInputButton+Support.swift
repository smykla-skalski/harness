import HarnessMonitorKit
import SwiftUI

struct VoicePopoverConfigurationSummary: View {
  let preferences: HarnessMonitorVoicePreferences

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Defaults")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)

      VoicePopoverConfigurationRow(
        title: "Language",
        value: HarnessMonitorVoicePreferences.localeDisplayLabel(
          for: preferences.effectiveLocaleIdentifier
        )
      )
      VoicePopoverConfigurationRow(
        title: "Processing",
        value: preferences.requestedSinksSummary
      )
      VoicePopoverConfigurationRow(
        title: "Insert",
        value: preferences.transcriptInsertionMode.title
      )

      if preferences.remoteProcessorSinkEnabled {
        VoicePopoverConfigurationRow(
          title: "Remote",
          value: preferences.remoteProcessorSummary
        )
      }

      Text("Change defaults in Preferences > Voice.")
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(HarnessMonitorTheme.spacingSM)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
  }
}

struct VoicePopoverConfigurationRow: View {
  let title: String
  let value: String

  var body: some View {
    LabeledContent(title) {
      Text(value)
        .multilineTextAlignment(.trailing)
        .fixedSize(horizontal: false, vertical: true)
    }
    .scaledFont(.subheadline)
  }
}

struct VoiceCaptureFailurePresentation: Equatable {
  let title: String
  let message: String
  let recoverySuggestion: String

  init(
    title: String,
    message: String,
    recoverySuggestion: String
  ) {
    self.title = title
    self.message = message
    self.recoverySuggestion = recoverySuggestion
  }

  init(error: Error) {
    let message = error.localizedDescription
    if let voiceError = error as? NativeVoiceCaptureError {
      self = Self(error: voiceError, message: message)
      return
    }
    self.init(
      title: "Voice Capture Failed",
      message: message,
      recoverySuggestion:
        "Check microphone access and installed dictation languages in System Settings, then try again."
    )
  }

  private init(error: NativeVoiceCaptureError, message: String) {
    switch error {
    case .microphonePermissionDenied:
      self.init(
        title: "Microphone Access Needed",
        message: message,
        recoverySuggestion:
          "Open System Settings > Privacy & Security > Microphone, allow Harness Monitor, "
          + "then try recording again."
      )
    case .speechAssetsUnavailable(let locale):
      self.init(
        title: "Speech Assets Needed",
        message: message,
        recoverySuggestion:
          "Open Preferences > Voice to confirm the selected locale, then open System Settings > "
          + "Keyboard > Dictation and download that language or switch to a supported English locale "
          + "such as English (US). macOS does not have an on-device speech asset ready for \(locale)."
      )
    case .unsupportedLocale(let locale):
      self.init(
        title: "Speech Language Unsupported",
        message: message,
        recoverySuggestion:
          "Open Preferences > Voice and choose a Speech-supported locale such as English (US), "
          + "then try recording again. Harness Monitor asked for \(locale)."
      )
    case .speechUnavailable:
      self.init(
        title: "Speech Unavailable",
        message: message,
        recoverySuggestion:
          "Make sure speech recognition and dictation are available on this Mac, install the "
          + "required language assets in System Settings, then try recording again."
      )
    case .noInputFormat, .couldNotCopyAudioBuffer, .couldNotConvertAudioBuffer:
      self.init(
        title: "Microphone Audio Unavailable",
        message: message,
        recoverySuggestion:
          "Check the selected microphone in System Settings > Sound > Input, then try recording again."
      )
    }
  }
}

enum VoiceCapturePopoverMetrics {
  static let width: CGFloat = 420
  static let minimumHeight: CGFloat = 320
}

struct VoiceCaptureFailureOverlay: View {
  let presentation: VoiceCaptureFailurePresentation
  let retry: () -> Void
  let close: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      Label(presentation.title, systemImage: "exclamationmark.triangle.fill")
        .scaledFont(.headline)
        .foregroundStyle(.primary)

      Text(presentation.message)
        .scaledFont(.body)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.message)
        .accessibilityIdentifier(HarnessMonitorAccessibility.voiceInputFailureMessage)

      Divider()

      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        Text("How to fix it")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Text(presentation.recoverySuggestion)
          .scaledFont(.body)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(presentation.recoverySuggestion)
          .accessibilityIdentifier(HarnessMonitorAccessibility.voiceInputFailureInstructions)
      }

      Spacer(minLength: HarnessMonitorTheme.itemSpacing)

      HStack {
        Spacer()
        Button("Close", action: close)
          .accessibilityIdentifier(HarnessMonitorAccessibility.voiceInputFailureCloseButton)
        Button("Try Again", action: retry)
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier(HarnessMonitorAccessibility.voiceInputFailureRetryButton)
      }
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .harnessPanelGlass()
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(.quaternary)
        .accessibilityHidden(true)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.voiceInputFailureOverlay)
  }
}
