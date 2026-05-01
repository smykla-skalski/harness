import AppKit
import Testing
@testable import HarnessMonitorRegistry

@Suite("AccessibilityRegistry")
struct AccessibilityRegistryTests {
  @Test("registers and retrieves elements by identifier")
  func registerAndRetrieve() async {
    let registry = AccessibilityRegistry()
    let element = RegistryElement(
      identifier: "sidebar.search",
      kind: .textField,
      frame: RegistryRect(x: 10, y: 20, width: 200, height: 28)
    )
    await registry.registerElement(element)
    let fetched = await registry.element(identifier: "sidebar.search")
    #expect(fetched == element)
  }

  @Test("filters elements by window and kind")
  func filtersElements() async {
    let registry = AccessibilityRegistry()
    await registry.registerElement(
      RegistryElement(
        identifier: "btn1",
        kind: .button,
        frame: RegistryRect(x: 0, y: 0, width: 1, height: 1),
        windowID: 100
      )
    )
    await registry.registerElement(
      RegistryElement(
        identifier: "btn2",
        kind: .button,
        frame: RegistryRect(x: 0, y: 0, width: 1, height: 1),
        windowID: 200
      )
    )
    await registry.registerElement(
      RegistryElement(
        identifier: "tf1",
        kind: .textField,
        frame: RegistryRect(x: 0, y: 0, width: 1, height: 1),
        windowID: 100
      )
    )
    let window100Buttons = await registry.allElements(windowID: 100, kind: .button)
    #expect(window100Buttons.map(\.identifier) == ["btn1"])

    let allWindow100 = await registry.allElements(windowID: 100)
    #expect(allWindow100.map(\.identifier) == ["btn1", "tf1"])

    let allButtons = await registry.allElements(kind: .button)
    #expect(allButtons.map(\.identifier) == ["btn1", "btn2"])
  }

  @Test("unregister removes the element")
  func unregister() async {
    let registry = AccessibilityRegistry()
    let element = RegistryElement(
      identifier: "dead",
      kind: .button,
      frame: RegistryRect(x: 0, y: 0, width: 0, height: 0)
    )
    await registry.registerElement(element)
    await registry.unregisterElement(identifier: "dead")
    let fetched = await registry.element(identifier: "dead")
    #expect(fetched == nil)
  }

  @Test("replacing window elements clears stale entries for that window only")
  func replaceWindowElementsClearsStaleEntries() async {
    let registry = AccessibilityRegistry()
    await registry.registerElement(
      RegistryElement(
        identifier: "main.keep",
        kind: .button,
        frame: RegistryRect(x: 0, y: 0, width: 1, height: 1),
        windowID: 100
      )
    )
    await registry.registerElement(
      RegistryElement(
        identifier: "prefs.keep",
        kind: .button,
        frame: RegistryRect(x: 0, y: 0, width: 1, height: 1),
        windowID: 200
      )
    )

    await registry.replaceWindowElements(
      windowID: 100,
      elements: [
        RegistryElement(
          identifier: "main.next",
          kind: .textField,
          frame: RegistryRect(x: 10, y: 20, width: 100, height: 24)
        )
      ]
    )

    let mainElements = await registry.allElements(windowID: 100)
    #expect(mainElements.map(\.identifier) == ["main.next"])
    #expect(mainElements.first?.windowID == 100)

    let prefsElements = await registry.allElements(windowID: 200)
    #expect(prefsElements.map(\.identifier) == ["prefs.keep"])
  }

  @Test("tracked snapshots preserve manual element ownership for matching identifiers")
  func trackedSnapshotsPreserveManualElementOwnership() async {
    let registry = AccessibilityRegistry()
    let manual = RegistryElement(
      identifier: "session.task.manual",
      label: "Manual task card",
      kind: .row,
      frame: RegistryRect(x: 10, y: 20, width: 100, height: 32),
      windowID: 100
    )
    await registry.registerElement(manual)

    await registry.replaceTrackedWindowElements(
      windowID: 100,
      elements: [
        RegistryElement(
          identifier: "session.task.manual",
          label: "Snapshot task card",
          kind: .row,
          frame: RegistryRect(x: 20, y: 30, width: 110, height: 40)
        ),
        RegistryElement(
          identifier: "session.task.snapshot",
          label: "Snapshot-only task card",
          kind: .row,
          frame: RegistryRect(x: 40, y: 60, width: 120, height: 44)
        ),
      ],
      ownerID: UUID()
    )

    let elements = await registry.allElements(windowID: 100)
    #expect(elements.map(\.identifier) == ["session.task.manual", "session.task.snapshot"])
    #expect(await registry.element(identifier: manual.identifier) == manual)
  }

  @Test("stale tracked-element teardown cannot clobber a replacement owner")
  func staleTrackedElementTeardownCannotClobberReplacementOwner() async {
    let registry = AccessibilityRegistry()
    let originalOwner = UUID()
    let replacementOwner = UUID()
    let original = RegistryElement(
      identifier: "session.task.manual",
      label: "Original task card",
      kind: .row,
      frame: RegistryRect(x: 10, y: 20, width: 100, height: 32),
      windowID: 100
    )
    let replacement = RegistryElement(
      identifier: original.identifier,
      label: "Replacement task card",
      kind: .row,
      frame: RegistryRect(x: 30, y: 40, width: 120, height: 36),
      windowID: 100
    )

    await registry.claimTrackedElement(identifier: original.identifier, ownerID: originalOwner)
    await registry.registerTrackedElement(original, ownerID: originalOwner)

    await registry.claimTrackedElement(identifier: replacement.identifier, ownerID: replacementOwner)
    await registry.registerTrackedElement(replacement, ownerID: replacementOwner)
    await registry.unregisterTrackedElement(identifier: original.identifier, ownerID: originalOwner)
    await registry.registerTrackedElement(original, ownerID: originalOwner)

    let fetched = await registry.element(identifier: replacement.identifier)
    #expect(fetched == replacement)
  }

  @Test("tracked snapshots skip identifiers claimed by manual tracking before publish")
  func trackedSnapshotsSkipClaimedManualIdentifiers() async {
    let registry = AccessibilityRegistry()
    let manualOwner = UUID()
    await registry.claimTrackedElement(identifier: "session.task.manual", ownerID: manualOwner)

    await registry.replaceTrackedWindowElements(
      windowID: 100,
      elements: [
        RegistryElement(
          identifier: "session.task.manual",
          label: "Snapshot task card",
          kind: .row,
          frame: RegistryRect(x: 20, y: 30, width: 110, height: 40)
        ),
        RegistryElement(
          identifier: "session.task.snapshot",
          label: "Snapshot-only task card",
          kind: .row,
          frame: RegistryRect(x: 40, y: 60, width: 120, height: 44)
        ),
      ],
      ownerID: UUID()
    )

    let elements = await registry.allElements(windowID: 100)
    #expect(elements.map(\.identifier) == ["session.task.snapshot"])
  }

  @Test("client snapshots merge into authoritative queries without clobbering local state")
  func clientSnapshotsMergeIntoAuthoritativeQueries() async {
    let registry = AccessibilityRegistry()
    let local = RegistryElement(
      identifier: "session.task.local",
      label: "Local task",
      kind: .row,
      frame: RegistryRect(x: 10, y: 20, width: 100, height: 32),
      windowID: 100
    )
    await registry.registerElement(local)
    await registry.upsertClientSnapshot(
      RegistryClientSnapshot(
        clientID: UUID(),
        appVersion: "1.2.3",
        bundleIdentifier: "io.test.client",
        snapshot: RegistrySnapshot(
          elements: [
            RegistryElement(
              identifier: "session.task.remote",
              label: "Remote task",
              kind: .row,
              frame: RegistryRect(x: 20, y: 30, width: 120, height: 36),
              windowID: 200
            ),
            RegistryElement(
              identifier: "session.task.local",
              label: "Shadowed remote task",
              kind: .row,
              frame: RegistryRect(x: 30, y: 40, width: 130, height: 40),
              windowID: 200
            ),
          ],
          windows: [
            RegistryWindow(
              id: 200,
              title: "Remote window",
              frame: RegistryRect(x: 0, y: 0, width: 320, height: 240)
            )
          ]
        )
      )
    )

    let elements = await registry.allElements()
    #expect(elements.map(\.identifier) == ["session.task.local", "session.task.remote"])
    #expect(await registry.element(identifier: local.identifier) == local)
    #expect(await registry.allWindows().map(\.id) == [200])
  }

  @Test("stale clear generations cannot remove a newer remote snapshot")
  func staleClearGenerationsCannotRemoveNewerRemoteSnapshot() async {
    let clientID = UUID()
    let registry = AccessibilityRegistry()
    let firstSnapshot = RegistryClientSnapshot(
      clientID: clientID,
      generation: 1,
      appVersion: "1.2.3",
      bundleIdentifier: "io.test.client",
      snapshot: RegistrySnapshot(
        elements: [
          RegistryElement(
            identifier: "session.task.remote",
            label: "First remote task",
            kind: .row,
            frame: RegistryRect(x: 20, y: 30, width: 120, height: 36),
            windowID: 200
          )
        ],
        windows: []
      )
    )
    let secondSnapshot = RegistryClientSnapshot(
      clientID: clientID,
      generation: 2,
      appVersion: "1.2.3",
      bundleIdentifier: "io.test.client",
      snapshot: RegistrySnapshot(
        elements: [
          RegistryElement(
            identifier: "session.task.remote",
            label: "Second remote task",
            kind: .row,
            frame: RegistryRect(x: 30, y: 40, width: 130, height: 40),
            windowID: 200
          )
        ],
        windows: []
      )
    )

    _ = await registry.upsertClientSnapshot(firstSnapshot)
    _ = await registry.upsertClientSnapshot(secondSnapshot)
    let ack = await registry.removeClientSnapshot(
      RegistryClientClearRequest(clientID: clientID, generation: 1)
    )

    #expect(ack.applied == true)
    #expect(await registry.element(identifier: "session.task.remote")?.label == "Second remote task")
  }

  @Test("expired client snapshots age out of authoritative queries")
  func expiredClientSnapshotsAgeOutOfAuthoritativeQueries() async throws {
    let registry = AccessibilityRegistry(
      remoteSnapshotLeaseDuration: .milliseconds(50),
      remoteHeartbeatInterval: .milliseconds(25)
    )
    _ = await registry.upsertClientSnapshot(
      RegistryClientSnapshot(
        clientID: UUID(),
        generation: 1,
        appVersion: "1.2.3",
        bundleIdentifier: "io.test.client",
        snapshot: RegistrySnapshot(
          elements: [
            RegistryElement(
              identifier: "session.task.remote.expiring",
              label: "Expiring remote task",
              kind: .row,
              frame: RegistryRect(x: 20, y: 30, width: 120, height: 36),
              windowID: 200
            )
          ],
          windows: []
        )
      )
    )

    #expect(await registry.element(identifier: "session.task.remote.expiring") != nil)
    #expect(await registry.storedClientSnapshotCount() == 1)
    try await Task.sleep(for: .milliseconds(80))
    #expect(await registry.element(identifier: "session.task.remote.expiring") == nil)
    #expect(await registry.storedClientSnapshotCount() == 0)
  }

  @MainActor
  @Test("stale window updates are ignored after tracking stops")
  func staleWindowUpdatesAreIgnoredAfterTrackingStops() async {
    let registry = AccessibilityRegistry()
    let controller = WindowRegistrySyncController(registry: registry)
    let entry = RegistryWindow(
      id: 101,
      title: "Tracked",
      frame: RegistryRect(x: 40, y: 50, width: 320, height: 240)
    )
    let generation = controller.beginTracking(windowID: entry.id)

    controller.sync(entry, generation: generation)
    controller.stopTracking()
    controller.sync(entry, generation: generation)

    await controller.waitForIdle()

    let windows = await registry.allWindows()
    #expect(windows.isEmpty)
  }

  @MainActor
  @Test("stale tracker teardown does not unregister a replacement tracker for the same window")
  func staleTrackerTeardownDoesNotUnregisterReplacementWindowTracker() async {
    let registry = AccessibilityRegistry()
    let staleController = WindowRegistrySyncController(registry: registry)
    let replacementController = WindowRegistrySyncController(registry: registry)
    let entry = RegistryWindow(
      id: 101,
      title: "Tracked",
      frame: RegistryRect(x: 40, y: 50, width: 320, height: 240)
    )

    let staleGeneration = staleController.beginTracking(windowID: entry.id)
    staleController.sync(entry, generation: staleGeneration)

    let replacementGeneration = replacementController.beginTracking(windowID: entry.id)
    replacementController.sync(entry, generation: replacementGeneration)
    staleController.stopTracking()

    await staleController.waitForIdle()
    await replacementController.waitForIdle()

    let windows = await registry.allWindows()
    #expect(windows.map(\.id) == [entry.id])
  }

  @MainActor
  @Test("same controller window switch preserves unregister before next register")
  func sameControllerWindowSwitchPreservesUnregisterBeforeReplacement() async {
    let registry = AccessibilityRegistry()
    let controller = WindowRegistrySyncController(registry: registry)
    let first = RegistryWindow(
      id: 101,
      title: "First",
      frame: RegistryRect(x: 10, y: 20, width: 300, height: 200)
    )
    let second = RegistryWindow(
      id: 202,
      title: "Second",
      frame: RegistryRect(x: 30, y: 40, width: 320, height: 220)
    )

    let firstGeneration = controller.beginTracking(windowID: first.id)
    controller.sync(first, generation: firstGeneration)
    controller.stopTracking()

    let secondGeneration = controller.beginTracking(windowID: second.id)
    controller.sync(second, generation: secondGeneration)

    await controller.waitForIdle()

    let windows = await registry.allWindows()
    #expect(windows.map(\.id) == [second.id])
  }

  @MainActor
  @Test("window sync coalesces rapid updates to the latest tracked state")
  func windowSyncCoalescesRapidUpdatesToLatestState() async {
    let registry = AccessibilityRegistry()
    let controller = WindowRegistrySyncController(registry: registry)
    let initial = RegistryWindow(
      id: 101,
      title: "Initial",
      frame: RegistryRect(x: 10, y: 20, width: 300, height: 200)
    )
    let latest = RegistryWindow(
      id: 101,
      title: "Latest",
      frame: RegistryRect(x: 30, y: 40, width: 360, height: 260)
    )

    let generation = controller.beginTracking(windowID: initial.id)
    controller.sync(initial, generation: generation)
    controller.sync(
      RegistryWindow(
        id: initial.id,
        title: "Intermediate",
        frame: RegistryRect(x: 20, y: 30, width: 320, height: 220)
      ),
      generation: generation
    )
    controller.sync(latest, generation: generation)

    await controller.waitForIdle()

    let windows = await registry.allWindows()
    #expect(windows == [latest])
  }

  @MainActor
  @Test("window element sync harvests and replaces tracked controls")
  func windowElementSyncHarvestsTrackedControls() async {
    let registry = AccessibilityRegistry()
    let controller = WindowElementRegistrySyncController(registry: registry)
    let window = NSWindow(
      contentRect: NSRect(x: 120, y: 180, width: 420, height: 320),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
    let button = NSButton(title: "Start", target: nil, action: nil)
    button.frame = NSRect(x: 40, y: 40, width: 120, height: 32)
    button.setAccessibilityIdentifier("session.controls.start")
    let field = NSTextField(string: "")
    field.placeholderString = "Search"
    field.frame = NSRect(x: 40, y: 96, width: 180, height: 24)
    field.setAccessibilityIdentifier("sidebar.search")
    root.addSubview(button)
    root.addSubview(field)
    window.contentView = root
    window.layoutIfNeeded()
    root.layoutSubtreeIfNeeded()

    let generation = controller.beginTracking(windowID: window.windowNumber)
    controller.sync(window: window, generation: generation)
    await controller.waitForIdle()

    let initialElements = await registry.allElements(windowID: window.windowNumber)
    #expect(initialElements.map(\.identifier) == ["session.controls.start", "sidebar.search"])
    #expect(initialElements.first(where: { $0.identifier == "session.controls.start" })?.kind == .button)
    #expect(initialElements.first(where: { $0.identifier == "sidebar.search" })?.kind == .textField)

    field.removeFromSuperview()
    controller.sync(window: window, generation: generation)
    await controller.waitForIdle()

    let refreshedElements = await registry.allElements(windowID: window.windowNumber)
    #expect(refreshedElements.map(\.identifier) == ["session.controls.start"])

    controller.stopTracking()
    await controller.waitForIdle()
    let clearedElements = await registry.allElements(windowID: window.windowNumber)
    #expect(clearedElements.isEmpty)
  }

  @MainActor
  @Test("window element sync harvests accessibility-only navigation-order children")
  func windowElementSyncHarvestsAccessibilityOnlyChildren() async {
    let registry = AccessibilityRegistry()
    let controller = WindowElementRegistrySyncController(registry: registry)
    let window = NSWindow(
      contentRect: NSRect(x: 120, y: 180, width: 420, height: 320),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    let root = NavigationOrderOnlyHostView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
    window.contentView = root
    window.layoutIfNeeded()
    root.layoutSubtreeIfNeeded()

    let generation = controller.beginTracking(windowID: window.windowNumber)
    controller.sync(window: window, generation: generation)
    await controller.waitForIdle()

    let identifiers = await registry.allElements(windowID: window.windowNumber).map(\.identifier)
    #expect(identifiers == ["navigation.child"])
  }

  @MainActor
  @Test("stale tracker teardown does not clear replacement harvested elements for the same window")
  func staleTrackerTeardownDoesNotClearReplacementWindowElements() async {
    let registry = AccessibilityRegistry()
    let staleController = WindowElementRegistrySyncController(registry: registry)
    let replacementController = WindowElementRegistrySyncController(registry: registry)
    let window = NSWindow(
      contentRect: NSRect(x: 120, y: 180, width: 420, height: 320),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
    let button = NSButton(title: "Start", target: nil, action: nil)
    button.frame = NSRect(x: 40, y: 40, width: 120, height: 32)
    button.setAccessibilityIdentifier("session.controls.start")
    root.addSubview(button)
    window.contentView = root
    window.layoutIfNeeded()
    root.layoutSubtreeIfNeeded()

    let staleGeneration = staleController.beginTracking(windowID: window.windowNumber)
    staleController.sync(window: window, generation: staleGeneration)

    let replacementGeneration = replacementController.beginTracking(windowID: window.windowNumber)
    replacementController.sync(window: window, generation: replacementGeneration)
    staleController.stopTracking()

    await staleController.waitForIdle()
    await replacementController.waitForIdle()

    let elements = await registry.allElements(windowID: window.windowNumber)
    #expect(elements.map(\.identifier) == ["session.controls.start"])
  }

  @MainActor
  @Test("same controller window switch preserves clear before replacement harvest")
  func sameControllerWindowSwitchPreservesClearBeforeReplacementHarvest() async {
    let registry = AccessibilityRegistry()
    let controller = WindowElementRegistrySyncController(registry: registry)

    let firstWindow = NSWindow(
      contentRect: NSRect(x: 120, y: 180, width: 420, height: 320),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    let firstRoot = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
    let firstButton = NSButton(title: "Start", target: nil, action: nil)
    firstButton.frame = NSRect(x: 40, y: 40, width: 120, height: 32)
    firstButton.setAccessibilityIdentifier("session.first.button")
    firstRoot.addSubview(firstButton)
    firstWindow.contentView = firstRoot
    firstWindow.layoutIfNeeded()
    firstRoot.layoutSubtreeIfNeeded()

    let secondWindow = NSWindow(
      contentRect: NSRect(x: 160, y: 220, width: 420, height: 320),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    let secondRoot = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
    let secondButton = NSButton(title: "Open", target: nil, action: nil)
    secondButton.frame = NSRect(x: 60, y: 60, width: 120, height: 32)
    secondButton.setAccessibilityIdentifier("session.second.button")
    secondRoot.addSubview(secondButton)
    secondWindow.contentView = secondRoot
    secondWindow.layoutIfNeeded()
    secondRoot.layoutSubtreeIfNeeded()

    let firstGeneration = controller.beginTracking(windowID: firstWindow.windowNumber)
    controller.sync(window: firstWindow, generation: firstGeneration)
    controller.stopTracking()

    let secondGeneration = controller.beginTracking(windowID: secondWindow.windowNumber)
    controller.sync(window: secondWindow, generation: secondGeneration)

    await controller.waitForIdle()

    let firstElements = await registry.allElements(windowID: firstWindow.windowNumber)
    #expect(firstElements.isEmpty)

    let secondElements = await registry.allElements(windowID: secondWindow.windowNumber)
    #expect(secondElements.map(\.identifier) == ["session.second.button"])
  }
}

@MainActor
private final class NavigationOrderOnlyHostView: NSView {
  private let navigationChild: AccessibilityNavigationChildView

  override init(frame frameRect: NSRect) {
    navigationChild = AccessibilityNavigationChildView(
      frame: NSRect(x: 24, y: 24, width: 120, height: 32),
      identifier: "navigation.child",
      label: "Navigation child"
    )
    super.init(frame: frameRect)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func accessibilityChildren() -> [Any]? {
    nil
  }

  override func accessibilityChildrenInNavigationOrder() -> [any NSAccessibilityElementProtocol]? {
    [navigationChild]
  }
}

@MainActor
private final class AccessibilityNavigationChildView: NSView {
  private let publishedFrame: NSRect
  private let publishedIdentifier: String
  private let publishedLabel: String

  init(frame: NSRect, identifier: String, label: String) {
    publishedFrame = frame
    publishedIdentifier = identifier
    publishedLabel = label
    super.init(frame: frame)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func accessibilityFrame() -> NSRect {
    publishedFrame
  }

  override func accessibilityIdentifier() -> String {
    publishedIdentifier
  }

  override func accessibilityLabel() -> String? {
    publishedLabel
  }

  override func accessibilityRole() -> NSAccessibility.Role? {
    .button
  }

  override func isAccessibilityEnabled() -> Bool {
    true
  }
}
