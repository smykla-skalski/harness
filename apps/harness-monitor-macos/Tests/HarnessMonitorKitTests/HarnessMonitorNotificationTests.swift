import AppKit
import CoreGraphics
import Foundation
import ImageIO
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
    #expect(try sampleImageHasAlpha(at: writer.sampleImageURL()) == false)
  }

  @Test("Asset writer rewrites stale alpha sample images")
  func assetWriterRewritesStaleAlphaSampleImages() throws {
    let environment = try temporaryEnvironment()
    let writer = HarnessMonitorNotificationAssetWriter(environment: environment)
    let url = try writer.sampleImageURL()
    try makeOpaqueAlphaPNGData().write(to: url, options: .atomic)

    #expect(try sampleImageHasAlpha(at: url))

    _ = try writer.sampleImageURL()

    #expect(try sampleImageHasAlpha(at: url) == false)
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

  private func sampleImageHasAlpha(at url: URL) throws -> Bool {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let properties = try #require(
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?)

    return properties[kCGImagePropertyHasAlpha] as? Bool == true
  }

  private func makeOpaqueAlphaPNGData() throws -> Data {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    let imageSize = 24
    let imageRect = CGRect(x: 0, y: 0, width: imageSize, height: imageSize)
    guard
      let context = CGContext(
        data: nil,
        width: imageSize,
        height: imageSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
      )
    else {
      throw HarnessMonitorNotificationError.assetGenerationFailed("test alpha PNG")
    }

    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(imageRect)

    guard
      let image = context.makeImage(),
      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else {
      throw HarnessMonitorNotificationError.assetGenerationFailed("test alpha PNG")
    }

    return data
  }
}
