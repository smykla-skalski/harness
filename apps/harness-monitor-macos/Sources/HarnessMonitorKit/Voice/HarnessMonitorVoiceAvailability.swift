import Foundation
import Speech

public enum HarnessMonitorVoiceLocaleAvailability: Equatable, Sendable {
  case ready(requestedLocaleIdentifier: String, resolvedLocaleIdentifier: String)
  case assetsRequired(requestedLocaleIdentifier: String, resolvedLocaleIdentifier: String)
  case unsupported(requestedLocaleIdentifier: String)
  case speechUnavailable

  public var statusSummary: String {
    switch self {
    case .ready(_, let resolvedLocaleIdentifier):
      "Ready with on-device speech assets for \(resolvedLocaleIdentifier)."
    case .assetsRequired(_, let resolvedLocaleIdentifier):
      "Speech assets still need to be installed for \(resolvedLocaleIdentifier)."
    case .unsupported(let requestedLocaleIdentifier):
      "macOS speech recognition does not support \(requestedLocaleIdentifier)."
    case .speechUnavailable:
      "Speech recognition is unavailable on this Mac."
    }
  }

  public var recoverySummary: String {
    switch self {
    case .ready:
      "Recording can start immediately with the selected language."
    case .assetsRequired:
      "Open System Settings > Keyboard > Dictation and download the language assets for the selected locale or switch to a supported English locale."
    case .unsupported:
      "Use a supported BCP-47 locale identifier such as en_US, en_GB, or pl_PL."
    case .speechUnavailable:
      "Make sure Dictation and speech recognition are available on this Mac before recording."
    }
  }
}

public enum HarnessMonitorVoiceLocaleSupport {
  public static func availability(
    for localeIdentifier: String,
    currentLocale: Locale = .current
  ) async -> HarnessMonitorVoiceLocaleAvailability {
    guard SpeechTranscriber.isAvailable else {
      return .speechUnavailable
    }

    let requestedLocaleIdentifier = sanitizedLocaleIdentifier(
      localeIdentifier,
      currentLocale: currentLocale
    )

    for candidate in candidateLocales(
      for: localeIdentifier,
      currentLocale: currentLocale
    ) {
      guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: candidate)
      else {
        continue
      }

      let transcriber = SpeechTranscriber(
        locale: supportedLocale,
        preset: .timeIndexedProgressiveTranscription
      )
      let modules: [any SpeechModule] = [transcriber]

      switch await AssetInventory.status(forModules: modules) {
      case .installed:
        return .ready(
          requestedLocaleIdentifier: requestedLocaleIdentifier,
          resolvedLocaleIdentifier: supportedLocale.identifier
        )
      case .supported, .downloading, .unsupported:
        return .assetsRequired(
          requestedLocaleIdentifier: requestedLocaleIdentifier,
          resolvedLocaleIdentifier: supportedLocale.identifier
        )
      @unknown default:
        return .assetsRequired(
          requestedLocaleIdentifier: requestedLocaleIdentifier,
          resolvedLocaleIdentifier: supportedLocale.identifier
        )
      }
    }

    return .unsupported(requestedLocaleIdentifier: requestedLocaleIdentifier)
  }

  static func candidateLocales(
    for localeIdentifier: String,
    currentLocale: Locale = .current
  ) -> [Locale] {
    let requestedLocale = Locale(
      identifier: sanitizedLocaleIdentifier(localeIdentifier, currentLocale: currentLocale))
    var identifiers = [requestedLocale.identifier]
    if let languageIdentifier = requestedLocale.language.languageCode?.identifier {
      identifiers.append(languageIdentifier)
    }
    identifiers.append(currentLocale.identifier)
    identifiers.append(Locale.autoupdatingCurrent.identifier)
    identifiers.append("en_US")

    var seenIdentifiers: Set<String> = []
    return identifiers.compactMap { identifier in
      let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedIdentifier.isEmpty, seenIdentifiers.insert(trimmedIdentifier).inserted else {
        return nil
      }
      return Locale(identifier: trimmedIdentifier)
    }
  }

  static func sanitizedLocaleIdentifier(
    _ localeIdentifier: String,
    currentLocale: Locale = .current
  ) -> String {
    let trimmedIdentifier = localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedIdentifier.isEmpty ? currentLocale.identifier : trimmedIdentifier
  }
}
