import AppKit
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Session window flow contracts")
struct SessionWindowFlowTests {
  @Test("Session window token encodes the session identity")
  func sessionWindowTokenEncodingRoundTrips() throws {
    let token = SessionWindowToken(sessionID: "sess-alpha")
    let data = try JSONEncoder().encode(token)
    let decoded = try JSONDecoder().decode(SessionWindowToken.self, from: data)

    #expect(decoded == token)
    #expect(decoded.sessionID == "sess-alpha")
  }

  @Test("Session windows use dedicated scene identifiers")
  func sessionWindowsUseDedicatedSceneIdentifiers() {
    #expect(HarnessMonitorWindowID.dashboard == "open-recent")
    #expect(HarnessMonitorWindowID.sessionScene == "session")
    #expect(HarnessMonitorWindowID.sessionWindow("sess-alpha") == "session-sess-alpha")
  }

  @Test("Current schema includes session window restoration state")
  func currentSchemaIncludesSessionWindowRestorationState() {
    #expect(HarnessMonitorCurrentSchema.versionString == HarnessMonitorSchemaV23.versionString)
    #expect(
      HarnessMonitorCurrentSchema.models.contains {
        String(describing: $0) == "CachedSessionWindowState"
      }
    )
    #expect(
      HarnessMonitorCurrentSchema.models.contains {
        String(describing: $0) == "CachedSessionTranscriptEntry"
      }
    )
    #expect(
      HarnessMonitorCurrentSchema.models.contains {
        String(describing: $0) == "NotificationHistoryRecord"
      }
    )
  }

  @Test("Session window tabbing preference defaults to system")
  func sessionWindowTabbingPreferenceDefaultsToSystem() {
    #expect(SessionWindowTabbingPreference.defaultValue == .system)
    #expect(SessionWindowTabbingPreference.resolved(rawValue: nil) == .system)
    #expect(SessionWindowTabbingPreference.resolved(rawValue: "system") == .system)
    #expect(SessionWindowTabbingPreference.resolved(rawValue: "always") == .always)
    #expect(SessionWindowTabbingPreference.resolved(rawValue: "never") == .never)
    #expect(SessionWindowTabbingPreference.resolved(rawValue: "unknown") == .system)
    #expect(
      SessionWindowTabbingPreference.storageKey == "harness.monitor.session-window.tabbing"
    )
  }

  @Test("Session shortcut overlay preference defaults to enabled")
  func sessionShortcutOverlayPreferenceDefaultsToEnabled() {
    #expect(SessionWindowKeyboardShortcutOverlaySettings.defaultValue)
    #expect(
      SessionWindowKeyboardShortcutOverlaySettings.storageKey
        == "harness.monitor.session-window.shortcut-overlays-enabled"
    )
  }

  @MainActor
  @Test("Session shortcut overlay hides when the session window resigns key")
  func sessionShortcutOverlayHidesWhenSessionWindowResignsKey() {
    let applicationIsActive = true
    var globalModifiers: EventModifiers = [.command]
    var lastReportedModifiers: EventModifiers = []
    let coordinator = SessionWindowModifierKeysMonitor.Coordinator(
      update: { lastReportedModifiers = $0 },
      applicationIsActive: { applicationIsActive },
      currentModifiers: { globalModifiers },
      notificationCenter: NotificationCenter(),
      installFlagsChangedMonitor: { _ in nil },
      removeFlagsChangedMonitor: { _ in },
      scheduleUpdate: { $0() }
    )
    let window = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )

    defer { coordinator.detach() }

    coordinator.attach(to: window)
    coordinator.windowDidBecomeKey()
    #expect(lastReportedModifiers == [.command])

    coordinator.windowDidResignKey()
    #expect(lastReportedModifiers.isEmpty)

    globalModifiers = [.command, .option]
    coordinator.handleFlagsChanged(globalModifiers)
    #expect(lastReportedModifiers.isEmpty)

    coordinator.windowDidBecomeKey()
    #expect(lastReportedModifiers == [.command, .option])
  }

  @MainActor
  @Test("Session shortcut overlay stays hidden while the app is inactive")
  func sessionShortcutOverlayStaysHiddenWhileAppIsInactive() {
    var applicationIsActive = true
    var globalModifiers: EventModifiers = [.command]
    var lastReportedModifiers: EventModifiers = []
    let coordinator = SessionWindowModifierKeysMonitor.Coordinator(
      update: { lastReportedModifiers = $0 },
      applicationIsActive: { applicationIsActive },
      currentModifiers: { globalModifiers },
      notificationCenter: NotificationCenter(),
      installFlagsChangedMonitor: { _ in nil },
      removeFlagsChangedMonitor: { _ in },
      scheduleUpdate: { $0() }
    )
    let window = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )

    defer { coordinator.detach() }

    coordinator.attach(to: window)
    coordinator.windowDidBecomeKey()
    #expect(lastReportedModifiers == [.command])

    applicationIsActive = false
    coordinator.applicationDidResignActive()
    #expect(lastReportedModifiers.isEmpty)

    globalModifiers = [.command, .shift]
    coordinator.handleFlagsChanged(globalModifiers)
    #expect(lastReportedModifiers.isEmpty)

    applicationIsActive = true
    coordinator.applicationDidBecomeActive()
    #expect(lastReportedModifiers == [.command, .shift])
  }

  @MainActor
  @Test("Session shortcut overlay defers and coalesces representable updates")
  func sessionShortcutOverlayDefersAndCoalescesRepresentableUpdates() {
    let applicationIsActive = true
    var globalModifiers: EventModifiers = [.command]
    var lastReportedModifiers: EventModifiers = []
    var scheduledUpdates: [@MainActor () -> Void] = []
    let coordinator = SessionWindowModifierKeysMonitor.Coordinator(
      update: { lastReportedModifiers = $0 },
      applicationIsActive: { applicationIsActive },
      currentModifiers: { globalModifiers },
      notificationCenter: NotificationCenter(),
      installFlagsChangedMonitor: { _ in nil },
      removeFlagsChangedMonitor: { _ in },
      scheduleUpdate: { scheduledUpdates.append($0) }
    )
    let window = NSWindow(
      contentRect: .init(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )

    defer { coordinator.detach() }

    coordinator.attach(to: window)
    coordinator.windowDidBecomeKey()
    globalModifiers = [.command, .option]
    coordinator.handleFlagsChanged(globalModifiers)

    #expect(lastReportedModifiers.isEmpty)
    #expect(scheduledUpdates.count == 1)

    let flushPendingUpdate = scheduledUpdates.removeFirst()
    flushPendingUpdate()

    #expect(lastReportedModifiers == [.command, .option])

    coordinator.attach(to: window)
    coordinator.handleFlagsChanged(globalModifiers)
    #expect(scheduledUpdates.isEmpty)
  }

  @Test("Session tab opening honors app and system tabbing preferences")
  func sessionTabOpeningHonorsAppAndSystemPreferences() {
    #expect(
      !SessionWindowTabbingSupport.shouldPreferTabbedOpen(
        preference: .never,
        userPreference: .always,
        targetIsFullScreen: true
      )
    )
    #expect(
      SessionWindowTabbingSupport.shouldPreferTabbedOpen(
        preference: .always,
        userPreference: .manual,
        targetIsFullScreen: false
      )
    )
    #expect(
      !SessionWindowTabbingSupport.shouldPreferTabbedOpen(
        preference: .system,
        userPreference: .manual,
        targetIsFullScreen: true
      )
    )
    #expect(
      SessionWindowTabbingSupport.shouldPreferTabbedOpen(
        preference: .system,
        userPreference: .always,
        targetIsFullScreen: false
      )
    )
    #expect(
      !SessionWindowTabbingSupport.shouldPreferTabbedOpen(
        preference: .system,
        userPreference: .inFullScreen,
        targetIsFullScreen: false
      )
    )
    #expect(
      SessionWindowTabbingSupport.shouldPreferTabbedOpen(
        preference: .system,
        userPreference: .inFullScreen,
        targetIsFullScreen: true
      )
    )
  }
}
