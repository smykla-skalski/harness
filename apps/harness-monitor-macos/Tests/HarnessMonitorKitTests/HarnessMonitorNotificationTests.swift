import Foundation
import Testing
import UserNotifications

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor native notifications")
struct HarnessMonitorNotificationTests {
  @Test("Factory builds native rich notification content")
  func factoryBuildsRichContent() async throws {
    let environment = try temporaryEnvironment()
    let writer = HarnessMonitorNotificationAssetWriter(environment: environment)
    var draft = HarnessMonitorNotificationPreset.richImage.draft
    draft.includesBadge = true
    draft.badgeNumber = 3
    draft.hidesAttachmentThumbnail = true
    draft.thumbnailClipping = .center
    draft.relevanceScore = 1.4

    let content = try await HarnessMonitorNotificationRequestFactory.makeContent(
      from: draft,
      assetWriter: writer
    )

    #expect(content.title == "Timeline snapshot ready")
    #expect(content.subtitle == "Rich notification")
    #expect(content.categoryIdentifier == HarnessMonitorNotificationCategoryID.fullControls)
    #expect(content.threadIdentifier == "timeline-snapshots")
    #expect(content.targetContentIdentifier == "timeline")
    #expect(content.filterCriteria == "image")
    #expect(content.summaryArgument == "Harness Monitor")
    #expect(content.summaryArgumentCount == 1)
    #expect(content.badge == 3)
    #expect(content.relevanceScore == 1)
    #expect(content.interruptionLevel == .active)
    #expect(content.attachments.count == 1)
    #expect(content.attachments.first?.type == "public.png")
    #expect(content.sound != nil)
    #expect(content.userInfo["source"] as? String == "preferences")
  }

  @Test("Factory registers status, text input, and full control categories")
  func factoryRegistersActionCategories() {
    let categories = HarnessMonitorNotificationRequestFactory.categories()
    let identifiers = Set(categories.map(\.identifier))

    #expect(identifiers.contains(HarnessMonitorNotificationCategoryID.statusActions))
    #expect(identifiers.contains(HarnessMonitorNotificationCategoryID.textInput))
    #expect(identifiers.contains(HarnessMonitorNotificationCategoryID.fullControls))

    let fullControls = categories.first {
      $0.identifier == HarnessMonitorNotificationCategoryID.fullControls
    }
    #expect(
      fullControls?.actions.contains {
        $0.identifier == HarnessMonitorNotificationActionID.open
      } == true
    )
    #expect(
      fullControls?.actions.contains { $0.identifier == HarnessMonitorNotificationActionID.delete }
        == true
    )
    #expect(
      fullControls?.actions.contains { $0.identifier == HarnessMonitorNotificationActionID.reply }
        == true
    )
    #expect(fullControls?.options.contains(.customDismissAction) == true)
    #expect(fullControls?.options.contains(.hiddenPreviewsShowTitle) == true)
    #expect(fullControls?.options.contains(.hiddenPreviewsShowSubtitle) == true)
  }

  @Test("Factory builds immediate, interval, and calendar triggers")
  func factoryBuildsTriggerModes() throws {
    var draft = HarnessMonitorNotificationDraft()

    draft.triggerMode = .immediate
    #expect(try HarnessMonitorNotificationRequestFactory.makeTrigger(from: draft) == nil)

    draft.triggerMode = .timeInterval
    draft.delaySeconds = 12
    let intervalTrigger = try #require(
      HarnessMonitorNotificationRequestFactory.makeTrigger(from: draft)
        as? UNTimeIntervalNotificationTrigger
    )
    #expect(intervalTrigger.timeInterval == 12)

    draft.triggerMode = .calendar
    draft.calendarDate = Date().addingTimeInterval(90)
    let calendarTrigger = try #require(
      HarnessMonitorNotificationRequestFactory.makeTrigger(from: draft)
        as? UNCalendarNotificationTrigger
    )
    #expect(calendarTrigger.nextTriggerDate() != nil)
  }

  @Test("Notification controls do not expose restricted alert modes")
  func notificationControlsDoNotExposeRestrictedAlertModes() {
    #expect(HarnessMonitorNotificationAuthorizationProfile.allCases.map(\.rawValue) == [
      "standard",
      "provisional",
    ])
    #expect(HarnessMonitorNotificationSoundMode.allCases.map(\.rawValue) == [
      "none",
      "systemDefault",
    ])
    #expect(HarnessMonitorNotificationInterruptionMode.allCases.map(\.rawValue) == [
      "passive",
      "active",
      "timeSensitive",
    ])
    #expect(HarnessMonitorNotificationPreset.allCases.map(\.rawValue) == [
      "basic",
      "sessionFinished",
      "actionRequest",
      "richImage",
    ])
  }

  private func temporaryEnvironment() throws -> HarnessMonitorEnvironment {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("harness-notification-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return HarnessMonitorEnvironment(
      values: ["XDG_DATA_HOME": root.path],
      homeDirectory: root
    )
  }
}
