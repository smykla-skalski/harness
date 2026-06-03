import AppKit
import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Harness Monitor trackpad history")
struct HarnessMonitorTrackpadHistoryTests {
  @Test("Trackpad history defaults to disabled")
  func defaultsToDisabled() {
    let suiteName = "HarnessMonitorTrackpadHistoryTests.defaults"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      Issue.record("Failed to create UserDefaults suite")
      return
    }
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(!HarnessMonitorTrackpadNavigationDefaults.read(userDefaults: defaults))
  }

  @Test("Trackpad history reads the stored enabled override")
  func readsStoredEnabledOverride() {
    let suiteName = "HarnessMonitorTrackpadHistoryTests.override"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      Issue.record("Failed to create UserDefaults suite")
      return
    }
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(true, forKey: HarnessMonitorTrackpadNavigationDefaults.enabledKey)

    #expect(HarnessMonitorTrackpadNavigationDefaults.read(userDefaults: defaults))
  }

  @Test("Positive gesture amount resolves to back when back navigation is available")
  func resolvesBackDirection() {
    #expect(
      HarnessTrackpadHistoryDirection.resolve(
        gestureAmount: 0.4,
        canGoBack: true,
        canGoForward: true
      ) == .back
    )
  }

  @Test("Negative gesture amount resolves to forward when forward navigation is available")
  func resolvesForwardDirection() {
    #expect(
      HarnessTrackpadHistoryDirection.resolve(
        gestureAmount: -0.4,
        canGoBack: true,
        canGoForward: true
      ) == .forward
    )
  }

  @Test("Gesture amounts below the threshold do not commit navigation")
  func belowThresholdDoesNotCommit() {
    #expect(
      HarnessTrackpadHistoryDirection.resolve(
        gestureAmount: 0.2,
        canGoBack: true,
        canGoForward: true
      ) == nil
    )
    #expect(
      HarnessTrackpadHistoryDirection.resolve(
        gestureAmount: -0.2,
        canGoBack: true,
        canGoForward: true
      ) == nil
    )
  }

  @MainActor
  @Test("Opt-out registry suppresses the swipe only inside a registered region")
  func optOutRegistrySuppressesInsideRegion() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    window.contentView = content
    let region = NSView(frame: NSRect(x: 100, y: 80, width: 120, height: 90))
    content.addSubview(region)

    let registry = HarnessTrackpadSwipeOptOutRegistry()
    registry.register(region)

    // A point inside the canvas region is suppressed (the canvas pans there).
    #expect(registry.suppressesSwipe(at: NSPoint(x: 150, y: 120), in: window))
    // Points outside the region still navigate.
    #expect(!registry.suppressesSwipe(at: NSPoint(x: 40, y: 40), in: window))
    #expect(!registry.suppressesSwipe(at: NSPoint(x: 320, y: 200), in: window))

    // A deregistered region (hidden route) stops suppressing.
    registry.unregister(region)
    #expect(!registry.suppressesSwipe(at: NSPoint(x: 150, y: 120), in: window))
  }

  @MainActor
  @Test("Horizontal scroll views suppress the swipe under the pointer")
  func horizontalScrollViewsSuppressSwipeUnderPointer() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 320))
    window.contentView = content

    let scrollView = NSScrollView(frame: NSRect(x: 80, y: 90, width: 220, height: 110))
    scrollView.hasHorizontalScroller = true
    scrollView.hasVerticalScroller = false
    let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 110))
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 110))
    textView.string = String(repeating: "payload-json ", count: 30)
    documentView.addSubview(textView)
    scrollView.documentView = documentView
    content.addSubview(scrollView)

    let registry = HarnessTrackpadSwipeOptOutRegistry()

    #expect(registry.suppressesSwipe(at: NSPoint(x: 150, y: 120), in: window))
    #expect(!registry.suppressesSwipe(at: NSPoint(x: 20, y: 40), in: window))
  }

  @MainActor
  @Test("Horizontal scroll suppression yields once the nested scroller hits an edge")
  func horizontalScrollSuppressionYieldsAtEdges() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 320))
    window.contentView = content

    let scrollView = NSScrollView(frame: NSRect(x: 80, y: 90, width: 220, height: 110))
    scrollView.hasHorizontalScroller = true
    scrollView.hasVerticalScroller = false
    let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 110))
    documentView.addSubview(NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 110)))
    scrollView.documentView = documentView
    content.addSubview(scrollView)

    let point = NSPoint(x: 150, y: 120)
    let registry = HarnessTrackpadSwipeOptOutRegistry()

    scrollView.contentView.scroll(to: NSPoint(x: 120, y: 0))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    #expect(registry.suppressesSwipe(at: point, deltaX: -12, in: window))
    #expect(registry.suppressesSwipe(at: point, deltaX: 12, in: window))

    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    #expect(registry.suppressesSwipe(at: point, deltaX: -12, in: window))
    #expect(!registry.suppressesSwipe(at: point, deltaX: 12, in: window))

    scrollView.contentView.scroll(to: NSPoint(x: 300, y: 0))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    #expect(registry.suppressesSwipe(at: point, deltaX: 12, in: window))
    #expect(!registry.suppressesSwipe(at: point, deltaX: -12, in: window))
  }
}
