import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor duration formatter")
struct HarnessMonitorDurationFormatterTests {
  @Test("Zero seconds renders as 0s")
  func zeroSeconds() {
    #expect(harnessMonitorDuration(0) == "0s")
  }

  @Test("Sub-minute seconds use the s suffix")
  func subMinuteSeconds() {
    #expect(harnessMonitorDuration(30) == "30s")
  }

  @Test("Exactly sixty seconds rolls up to 1m")
  func exactlySixtySeconds() {
    #expect(harnessMonitorDuration(60) == "1m")
  }

  @Test("Ninety seconds round down to whole minutes")
  func ninetySecondsRoundDown() {
    #expect(harnessMonitorDuration(90) == "1m")
  }

  @Test("One second short of an hour stays in minutes")
  func justUnderOneHour() {
    #expect(harnessMonitorDuration(3_599) == "59m")
  }

  @Test("Exactly one hour renders as 1h")
  func exactlyOneHour() {
    #expect(harnessMonitorDuration(3_600) == "1h")
  }

  @Test("Hours with a minute remainder combine the two")
  func hoursWithMinuteRemainder() {
    #expect(harnessMonitorDuration(5_400) == "1h 30m")
  }

  @Test("One second short of a day stays in hours plus minutes")
  func justUnderOneDay() {
    #expect(harnessMonitorDuration(86_399) == "23h 59m")
  }

  @Test("Exactly one day renders as 1d")
  func exactlyOneDay() {
    #expect(harnessMonitorDuration(86_400) == "1d")
  }

  @Test("Days with an hour remainder drop minutes")
  func daysWithHourRemainder() {
    #expect(harnessMonitorDuration(90_000) == "1d 1h")
  }

  @Test("Multiple whole days render without trailing zero hours")
  func twoFullDays() {
    #expect(harnessMonitorDuration(172_800) == "2d")
  }
}
