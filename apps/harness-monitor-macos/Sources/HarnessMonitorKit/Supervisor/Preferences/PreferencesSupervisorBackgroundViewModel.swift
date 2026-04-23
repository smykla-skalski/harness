import Foundation
import Observation

public struct SupervisorQuietHoursWindow: Equatable, Sendable {
  public let startMinutes: Int
  public let endMinutes: Int

  public init(startMinutes: Int, endMinutes: Int) {
    self.startMinutes = Self.normalized(minutes: startMinutes)
    self.endMinutes = Self.normalized(minutes: endMinutes)
  }

  public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
    let minute = Self.minuteOfDay(for: date, calendar: calendar)
    if startMinutes == endMinutes {
      return true
    }
    if startMinutes < endMinutes {
      return minute >= startMinutes && minute < endMinutes
    }
    return minute >= startMinutes || minute < endMinutes
  }

  public func startDate(reference: Date, calendar: Calendar = .current) -> Date {
    Self.date(for: startMinutes, reference: reference, calendar: calendar)
  }

  public func endDate(reference: Date, calendar: Calendar = .current) -> Date {
    Self.date(for: endMinutes, reference: reference, calendar: calendar)
  }

  private static func normalized(minutes: Int) -> Int {
    let minutesPerDay = 24 * 60
    let normalized = minutes % minutesPerDay
    return normalized >= 0 ? normalized : normalized + minutesPerDay
  }

  private static func minuteOfDay(for date: Date, calendar: Calendar) -> Int {
    let components = calendar.dateComponents([.hour, .minute], from: date)
    return (components.hour ?? 0) * 60 + (components.minute ?? 0)
  }

  private static func date(for minutes: Int, reference: Date, calendar: Calendar) -> Date {
    let startOfDay = calendar.startOfDay(for: reference)
    return calendar.date(byAdding: .minute, value: normalized(minutes: minutes), to: startOfDay)
      ?? startOfDay
  }
}

@MainActor
@Observable
public final class PreferencesSupervisorBackgroundViewModel {
  public typealias RunInBackgroundHandler =
    @MainActor (Bool) -> Void
  public typealias QuietHoursHandler =
    @MainActor (SupervisorQuietHoursWindow?, Date) -> Void

  public var runInBackground: Bool
  public var quietHoursEnabled: Bool
  public var quietHoursStart: Date
  public var quietHoursEnd: Date

  @ObservationIgnored private let userDefaults: UserDefaults
  @ObservationIgnored private let calendar: Calendar
  @ObservationIgnored private let nowProvider: () -> Date
  @ObservationIgnored private let onRunInBackgroundChange: RunInBackgroundHandler
  @ObservationIgnored private let onQuietHoursChange: QuietHoursHandler

  public init(
    userDefaults: UserDefaults = .standard,
    calendar: Calendar = .current,
    nowProvider: @escaping () -> Date = { Date() },
    onRunInBackgroundChange: @escaping RunInBackgroundHandler = { _ in },
    onQuietHoursChange: @escaping QuietHoursHandler = { _, _ in }
  ) {
    self.userDefaults = userDefaults
    self.calendar = calendar
    self.nowProvider = nowProvider
    self.onRunInBackgroundChange = onRunInBackgroundChange
    self.onQuietHoursChange = onQuietHoursChange

    func storedMinutes(forKey key: String, defaultValue: Int) -> Int {
      guard userDefaults.object(forKey: key) != nil else {
        return defaultValue
      }
      return userDefaults.integer(forKey: key)
    }

    let now = nowProvider()
    let quietHoursStartMinutes = storedMinutes(
      forKey: SupervisorPreferencesDefaults.quietHoursStartMinutesKey,
      defaultValue: SupervisorPreferencesDefaults.quietHoursStartMinutesDefault
    )
    let quietHoursEndMinutes = storedMinutes(
      forKey: SupervisorPreferencesDefaults.quietHoursEndMinutesKey,
      defaultValue: SupervisorPreferencesDefaults.quietHoursEndMinutesDefault
    )
    let runInBackgroundObject = userDefaults.object(
      forKey: SupervisorPreferencesDefaults.runInBackgroundKey
    )
    runInBackground =
      (runInBackgroundObject as? Bool) ?? SupervisorPreferencesDefaults.runInBackgroundDefault
    let quietHoursObject = userDefaults.object(
      forKey: SupervisorPreferencesDefaults.quietHoursEnabledKey
    )
    quietHoursEnabled =
      (quietHoursObject as? Bool) ?? SupervisorPreferencesDefaults.quietHoursEnabledDefault
    quietHoursStart = SupervisorQuietHoursWindow(
      startMinutes: quietHoursStartMinutes,
      endMinutes: SupervisorPreferencesDefaults.quietHoursEndMinutesDefault
    ).startDate(reference: now, calendar: calendar)
    quietHoursEnd = SupervisorQuietHoursWindow(
      startMinutes: SupervisorPreferencesDefaults.quietHoursStartMinutesDefault,
      endMinutes: quietHoursEndMinutes
    ).endDate(reference: now, calendar: calendar)
  }

  public var quietHoursWindow: SupervisorQuietHoursWindow? {
    guard quietHoursEnabled else {
      return nil
    }
    return SupervisorQuietHoursWindow(
      startMinutes: minuteOfDay(for: quietHoursStart),
      endMinutes: minuteOfDay(for: quietHoursEnd)
    )
  }

  public var isQuietHoursActive: Bool {
    guard let quietHoursWindow else {
      return false
    }
    return quietHoursWindow.contains(nowProvider(), calendar: calendar)
  }

  public func setRunInBackground(_ enabled: Bool) {
    guard runInBackground != enabled else {
      return
    }
    runInBackground = enabled
    userDefaults.set(enabled, forKey: SupervisorPreferencesDefaults.runInBackgroundKey)
    onRunInBackgroundChange(enabled)
  }

  public func setQuietHoursEnabled(_ enabled: Bool) {
    guard quietHoursEnabled != enabled else {
      return
    }
    quietHoursEnabled = enabled
    userDefaults.set(enabled, forKey: SupervisorPreferencesDefaults.quietHoursEnabledKey)
    notifyQuietHoursChanged()
  }

  public func setQuietHoursStart(_ date: Date) {
    guard quietHoursStart != date else {
      return
    }
    quietHoursStart = date
    userDefaults.set(
      minuteOfDay(for: date),
      forKey: SupervisorPreferencesDefaults.quietHoursStartMinutesKey
    )
    notifyQuietHoursChanged()
  }

  public func setQuietHoursEnd(_ date: Date) {
    guard quietHoursEnd != date else {
      return
    }
    quietHoursEnd = date
    userDefaults.set(
      minuteOfDay(for: date),
      forKey: SupervisorPreferencesDefaults.quietHoursEndMinutesKey
    )
    notifyQuietHoursChanged()
  }

  private func notifyQuietHoursChanged() {
    onQuietHoursChange(quietHoursWindow, nowProvider())
  }

  private func minuteOfDay(for date: Date) -> Int {
    let components = calendar.dateComponents([.hour, .minute], from: date)
    return (components.hour ?? 0) * 60 + (components.minute ?? 0)
  }
}
