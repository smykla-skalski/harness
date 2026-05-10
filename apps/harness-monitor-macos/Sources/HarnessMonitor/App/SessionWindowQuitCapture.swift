import AppKit
import HarnessMonitorKit
import HarnessMonitorUIPreviewable

/// Builds a `SessionWindowQuitSnapshot` from the live AppKit state:
/// walks the registered session windows, groups them by `NSWindow.tabGroup`
/// identity, assigns ordinals + positions, and marks the foreground tab.
/// The result feeds into `HarnessMonitorStore.flushSessionWindowsOpenAtQuit`
/// so launch-time can re-merge the same tabs.
@MainActor
enum SessionWindowQuitCapture {
  static func captureSnapshot() -> HarnessMonitorStore.SessionWindowQuitSnapshot {
    let bindings = SessionWindowAppKitRegistry.shared.currentBindings()
    guard !bindings.isEmpty else {
      return HarnessMonitorStore.SessionWindowQuitSnapshot()
    }

    var sessionIDs: Set<String> = []
    // Group bindings by the address of their NSWindowTabGroup, treating a
    // nil tabGroup or single-window group as standalone.
    var groupedBindings: [ObjectIdentifier: [(window: NSWindow, sessionID: String)]] = [:]
    var standaloneBindings: [(window: NSWindow, sessionID: String)] = []

    for binding in bindings {
      sessionIDs.insert(binding.sessionID)
      if let tabGroup = binding.window.tabGroup, tabGroup.windows.count > 1 {
        groupedBindings[ObjectIdentifier(tabGroup), default: []].append(binding)
      } else {
        standaloneBindings.append(binding)
      }
    }

    let groupings = makeGroupings(from: groupedBindings)
    return HarnessMonitorStore.SessionWindowQuitSnapshot(
      sessionIDs: sessionIDs,
      groupings: groupings
    )
  }

  private static func makeGroupings(
    from grouped: [ObjectIdentifier: [(window: NSWindow, sessionID: String)]]
  ) -> [HarnessMonitorStore.SessionTabGroupSnapshot] {
    // Sort group keys for deterministic ordinal assignment.
    let sortedKeys = grouped.keys.sorted { lhs, rhs in
      let lhsFirst = grouped[lhs]?.first?.sessionID ?? ""
      let rhsFirst = grouped[rhs]?.first?.sessionID ?? ""
      return lhsFirst < rhsFirst
    }

    var snapshots: [HarnessMonitorStore.SessionTabGroupSnapshot] = []
    for (ordinal, key) in sortedKeys.enumerated() {
      guard let entries = grouped[key], let firstWindow = entries.first?.window,
        let tabGroup = firstWindow.tabGroup
      else {
        continue
      }
      // Order session IDs by tab order in the tab group, not by registry
      // iteration order. `tabGroup.windows` is the live left-to-right
      // ordering AppKit shows the user.
      let windowSessionIDs = tabGroup.windows.compactMap { window -> String? in
        entries.first(where: { $0.window === window })?.sessionID
      }
      let foregroundSessionID = entries.first(where: { entry in
        entry.window === tabGroup.selectedWindow
      })?.sessionID
      snapshots.append(
        HarnessMonitorStore.SessionTabGroupSnapshot(
          ordinal: ordinal,
          sessionIDs: windowSessionIDs,
          foregroundSessionID: foregroundSessionID
        )
      )
    }
    return snapshots
  }
}
