import Foundation
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class SettingsSupervisorBackgroundViewModelTests: XCTestCase {
  private var calendar: Calendar { Self.utcCalendar }

  func test_initLoadsPersistedValues() {
    let userDefaults = makeUserDefaults()
    userDefaults.set(false, forKey: SupervisorSettingsDefaults.runInBackgroundKey)
    userDefaults.set(true, forKey: SupervisorSettingsDefaults.quietHoursEnabledKey)
    userDefaults.set(21 * 60, forKey: SupervisorSettingsDefaults.quietHoursStartMinutesKey)
    userDefaults.set(6 * 60, forKey: SupervisorSettingsDefaults.quietHoursEndMinutesKey)

    let viewModel = SettingsSupervisorBackgroundViewModel(
      userDefaults: userDefaults,
      calendar: calendar,
      nowProvider: { Self.date(hour: 23, minute: 15) }
    )

    XCTAssertFalse(viewModel.runInBackground)
    XCTAssertTrue(viewModel.quietHoursEnabled)
    XCTAssertTrue(viewModel.isQuietHoursActive)
    XCTAssertEqual(
      viewModel.quietHoursWindow,
      SupervisorQuietHoursWindow(startMinutes: 21 * 60, endMinutes: 6 * 60)
    )
  }

  func test_enableRunInBackgroundPersistsAndCallsRuntime() {
    let userDefaults = makeUserDefaults()
    let runtime = BackgroundRuntimeSpy()
    let viewModel = SettingsSupervisorBackgroundViewModel(
      userDefaults: userDefaults,
      calendar: calendar,
      onRunInBackgroundChange: { enabled in runtime.runInBackgroundChanges.append(enabled) }
    )

    viewModel.setRunInBackground(true)

    XCTAssertEqual(
      userDefaults.object(forKey: SupervisorSettingsDefaults.runInBackgroundKey) as? Bool,
      true
    )
    XCTAssertEqual(runtime.runInBackgroundChanges, [true])
  }

  func test_settingQuietHoursPersistsWindowAndNotifiesRuntime() {
    let userDefaults = makeUserDefaults()
    let runtime = BackgroundRuntimeSpy()
    let now = Self.date(hour: 23, minute: 30)
    let updatedStart = Self.date(hour: 21, minute: 30)
    let updatedEnd = Self.date(hour: 6, minute: 45)
    let viewModel = SettingsSupervisorBackgroundViewModel(
      userDefaults: userDefaults,
      calendar: calendar,
      nowProvider: { now },
      onQuietHoursChange: { window, observedNow in
        runtime.windows.append(window)
        runtime.observedTimes.append(observedNow)
      }
    )

    viewModel.setQuietHoursEnabled(true)
    viewModel.setQuietHoursStart(updatedStart)
    viewModel.setQuietHoursEnd(updatedEnd)

    XCTAssertEqual(
      userDefaults.object(forKey: SupervisorSettingsDefaults.quietHoursEnabledKey) as? Bool,
      true
    )
    XCTAssertEqual(
      userDefaults.integer(forKey: SupervisorSettingsDefaults.quietHoursStartMinutesKey),
      21 * 60 + 30
    )
    XCTAssertEqual(
      userDefaults.integer(forKey: SupervisorSettingsDefaults.quietHoursEndMinutesKey),
      6 * 60 + 45
    )
    XCTAssertEqual(
      runtime.windows.last,
      SupervisorQuietHoursWindow(startMinutes: 21 * 60 + 30, endMinutes: 6 * 60 + 45)
    )
    XCTAssertEqual(runtime.observedTimes.last, now)
  }

  func test_overnightQuietHoursWindowContainsLateNightAndEarlyMorning() {
    let window = SupervisorQuietHoursWindow(startMinutes: 22 * 60, endMinutes: 7 * 60)

    XCTAssertTrue(window.contains(Self.date(hour: 23, minute: 45), calendar: calendar))
    XCTAssertTrue(window.contains(Self.date(hour: 6, minute: 30), calendar: calendar))
    XCTAssertFalse(window.contains(Self.date(hour: 12, minute: 0), calendar: calendar))
  }

  private func makeUserDefaults() -> UserDefaults {
    let suiteName = "SettingsSupervisorBackgroundViewModelTests.\(UUID().uuidString)"
    let userDefaults = UserDefaults(suiteName: suiteName)!
    userDefaults.removePersistentDomain(forName: suiteName)
    addTeardownBlock {
      userDefaults.removePersistentDomain(forName: suiteName)
    }
    return userDefaults
  }

  private static func date(hour: Int, minute: Int) -> Date {
    let calendar = utcCalendar
    let components = DateComponents(
      calendar: calendar,
      year: 2026,
      month: 4,
      day: 23,
      hour: hour,
      minute: minute
    )
    return calendar.date(from: components)!
  }

  private static var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }
}

@MainActor
private final class BackgroundRuntimeSpy {
  var runInBackgroundChanges: [Bool] = []
  var windows: [SupervisorQuietHoursWindow?] = []
  var observedTimes: [Date] = []
}
