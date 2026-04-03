import Foundation
import SwiftUI

public enum HarnessMonitorDateTimeZoneMode: String, CaseIterable, Identifiable {
  case local
  case utc
  case custom

  public var id: Self { self }

  public var label: String {
    switch self {
    case .local:
      "Local Time"
    case .utc:
      "UTC"
    case .custom:
      "Custom"
    }
  }
}

public struct HarnessMonitorDateTimeConfiguration: Equatable {
  public static let timeZoneModeKey = "harnessDateTimeTimeZoneMode"
  public static let customTimeZoneIdentifierKey = "harnessDateTimeCustomTimeZoneIdentifier"
  public static let uiTestTimeZoneModeOverrideKey = "HARNESS_MONITOR_TIME_ZONE_MODE_OVERRIDE"
  public static let uiTestCustomTimeZoneOverrideKey = "HARNESS_MONITOR_CUSTOM_TIME_ZONE_OVERRIDE"
  public static let defaultTimeZoneModeRawValue = HarnessMonitorDateTimeZoneMode.local.rawValue
  public static let previewTimestampValue = "2026-04-03T16:47:07Z"
  public static let knownTimeZoneIdentifiers = TimeZone.knownTimeZoneIdentifiers.sorted()

  public let timeZoneModeRawValue: String
  public let customTimeZoneIdentifier: String

  public init(timeZoneModeRawValue: String, customTimeZoneIdentifier: String) {
    self.timeZoneModeRawValue = timeZoneModeRawValue
    self.customTimeZoneIdentifier = customTimeZoneIdentifier
  }

  public static var defaultCustomTimeZoneIdentifier: String {
    TimeZone.autoupdatingCurrent.identifier
  }

  public static var `default`: Self {
    stored()
  }

  public static func stored(defaults: UserDefaults = .standard) -> Self {
    Self(
      timeZoneModeRawValue: defaults.string(forKey: timeZoneModeKey) ?? defaultTimeZoneModeRawValue,
      customTimeZoneIdentifier: defaults.string(forKey: customTimeZoneIdentifierKey)
        ?? defaultCustomTimeZoneIdentifier
    )
  }

  public var timeZoneMode: HarnessMonitorDateTimeZoneMode {
    HarnessMonitorDateTimeZoneMode(rawValue: timeZoneModeRawValue) ?? .local
  }

  public var showsCustomTimeZoneField: Bool {
    timeZoneMode == .custom
  }

  public var trimmedCustomTimeZoneIdentifier: String {
    customTimeZoneIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var isCustomTimeZoneValid: Bool {
    !trimmedCustomTimeZoneIdentifier.isEmpty
      && TimeZone(identifier: trimmedCustomTimeZoneIdentifier) != nil
  }

  public var effectiveTimeZone: TimeZone {
    switch timeZoneMode {
    case .local:
      .autoupdatingCurrent
    case .utc:
      TimeZone(secondsFromGMT: 0) ?? .autoupdatingCurrent
    case .custom:
      TimeZone(identifier: trimmedCustomTimeZoneIdentifier) ?? .autoupdatingCurrent
    }
  }

  public var effectiveTimeZoneDisplayName: String {
    switch timeZoneMode {
    case .local:
      return "Local (\(effectiveTimeZone.identifier))"
    case .utc:
      return "UTC"
    case .custom:
      if isCustomTimeZoneValid {
        return trimmedCustomTimeZoneIdentifier
      }
      return "Invalid custom zone, falling back to \(effectiveTimeZone.identifier)"
    }
  }

  public var preferencesStateValue: String {
    switch timeZoneMode {
    case .local:
      "local"
    case .utc:
      "utc"
    case .custom:
      isCustomTimeZoneValid ? trimmedCustomTimeZoneIdentifier : "invalid"
    }
  }
}

extension EnvironmentValues {
  @Entry public var harnessDateTimeConfiguration: HarnessMonitorDateTimeConfiguration = .default
}

@MainActor private let iso8601FractionalFormatter: ISO8601DateFormatter = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter
}()

@MainActor private let iso8601Formatter: ISO8601DateFormatter = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return formatter
}()

@MainActor
func formatTimestamp(_ value: String?) -> String {
  formatTimestamp(value, configuration: .stored())
}

@MainActor
func formatTimestamp(
  _ value: String?,
  configuration: HarnessMonitorDateTimeConfiguration
) -> String {
  guard let value, let date = parsedTimestampDate(from: value) else {
    return value ?? "n/a"
  }

  return formatTimestamp(date, configuration: configuration)
}

@MainActor
func formatTimestamp(_ date: Date) -> String {
  formatTimestamp(date, configuration: .stored())
}

@MainActor
func formatTimestamp(
  _ date: Date,
  configuration: HarnessMonitorDateTimeConfiguration
) -> String {
  let timeZone = configuration.effectiveTimeZone
  let calendar = Calendar.autoupdatingCurrent
  let now = Date.now
  let formatter = DateFormatter()
  formatter.locale = .autoupdatingCurrent
  formatter.calendar = calendar
  formatter.timeZone = timeZone
  formatter.dateFormat =
    if calendar.isDate(date, equalTo: now, toGranularity: .year) {
      "d MMM HH:mm:ss"
    } else {
      "d MMM yyyy HH:mm:ss"
    }

  return formatter.string(from: date)
}

@MainActor
private func parsedTimestampDate(from value: String) -> Date? {
  iso8601FractionalFormatter.date(from: value) ?? iso8601Formatter.date(from: value)
}
