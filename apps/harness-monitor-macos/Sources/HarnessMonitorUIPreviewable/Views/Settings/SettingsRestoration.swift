import Foundation
import SwiftUI

public enum SettingsRestorationDefaults {
  public static let selectedSectionKey = "harness.settings.selectedSection"
  private static let scrollOffsetKeyPrefix = "harness.settings.scrollOffset."

  public static func initialSelectedSection(
    fallback: SettingsSection,
    ignoresStoredValue: Bool,
    userDefaults: UserDefaults = .standard
  ) -> SettingsSection {
    guard !ignoresStoredValue else {
      return fallback
    }
    guard let rawValue = userDefaults.string(forKey: selectedSectionKey) else {
      return fallback
    }
    return SettingsSection(rawValue: rawValue) ?? fallback
  }

  public static func storeSelectedSection(
    _ section: SettingsSection,
    userDefaults: UserDefaults = .standard
  ) {
    userDefaults.set(section.rawValue, forKey: selectedSectionKey)
  }

  static func scrollOffset(
    for section: SettingsSection,
    userDefaults: UserDefaults = .standard
  ) -> CGFloat {
    normalizedScrollOffset(
      CGFloat(userDefaults.double(forKey: scrollOffsetKey(for: section)))
    )
  }

  static func storeScrollOffset(
    _ offset: CGFloat,
    for section: SettingsSection,
    userDefaults: UserDefaults = .standard
  ) {
    userDefaults.set(
      Double(normalizedScrollOffset(offset)),
      forKey: scrollOffsetKey(for: section)
    )
  }

  static func normalizedScrollOffset(_ offset: CGFloat) -> CGFloat {
    guard offset.isFinite, offset > 0 else {
      return 0
    }
    return offset
  }

  private static func scrollOffsetKey(for section: SettingsSection) -> String {
    scrollOffsetKeyPrefix + section.rawValue
  }
}

private struct SettingsScrollRestorationSectionKey: EnvironmentKey {
  static let defaultValue: SettingsSection? = nil
}

private struct SettingsScrollRestorationSuspendedKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var settingsScrollRestorationSection: SettingsSection? {
    get { self[SettingsScrollRestorationSectionKey.self] }
    set { self[SettingsScrollRestorationSectionKey.self] = newValue }
  }

  var settingsScrollRestorationSuspended: Bool {
    get { self[SettingsScrollRestorationSuspendedKey.self] }
    set { self[SettingsScrollRestorationSuspendedKey.self] = newValue }
  }
}

struct SettingsScrollRestorationModifier: ViewModifier {
  private static let persistenceStep: CGFloat = 24
  private static let restoreTolerance: CGFloat = 1

  @Environment(\.settingsScrollRestorationSection)
  private var section
  @Environment(\.settingsScrollRestorationSuspended)
  private var isRestorationSuspended
  @State private var lastObservedOffset: CGFloat = 0
  @State private var lastPersistedOffset: CGFloat?
  @State private var pendingRestore: PendingRestore?
  @State private var restoreGeneration: UInt64 = 0
  @State private var restoredSection: SettingsSection?
  @State private var scrollPosition = ScrollPosition()

  func body(content: Content) -> some View {
    Group {
      if let section {
        content
          .scrollPosition($scrollPosition)
          .onScrollGeometryChange(
            for: SettingsScrollState.self,
            of: Self.scrollState
          ) { _, newState in
            guard !waitForPendingRestore(newState, for: section) else {
              return
            }
            lastObservedOffset = newState.offsetY
            guard restoredSection == section else {
              return
            }
            persistObservedOffset(newState.offsetY, for: section, force: false)
          }
          .onChange(of: section, initial: true) { _, newSection in
            restoreScrollPosition(for: newSection)
          }
          .onChange(of: isRestorationSuspended, initial: true) { _, isSuspended in
            guard isSuspended else { return }
            cancelRestore(for: section)
          }
          .onDisappear {
            guard pendingRestore?.section != section else {
              return
            }
            persistObservedOffset(lastObservedOffset, for: section, force: true)
          }
      } else {
        content
      }
    }
  }

  private static func scrollState(_ geometry: ScrollGeometry) -> SettingsScrollState {
    let maxOffset = max(0, geometry.contentSize.height - geometry.visibleRect.height)
    return SettingsScrollState(
      offsetY: min(max(0, geometry.contentOffset.y), maxOffset),
      maxOffsetY: maxOffset
    )
  }

  private func restoreScrollPosition(for section: SettingsSection) {
    guard !isRestorationSuspended else {
      cancelRestore(for: section)
      return
    }

    restoreGeneration &+= 1
    let generation = restoreGeneration
    let offset = SettingsRestorationDefaults.scrollOffset(for: section)
    lastObservedOffset = offset
    lastPersistedOffset = offset
    if offset > 0 {
      pendingRestore = PendingRestore(section: section, offset: offset, generation: generation)
    } else {
      pendingRestore = nil
    }
    restoredSection = offset > 0 ? nil : section
    scrollPosition = ScrollPosition(point: CGPoint(x: 0, y: offset))

    Task { @MainActor in
      await Task.yield()
      guard restoreGeneration == generation else {
        return
      }
      scrollPosition = ScrollPosition(point: CGPoint(x: 0, y: offset))
    }
  }

  private func cancelRestore(for section: SettingsSection) {
    restoreGeneration &+= 1
    pendingRestore = nil
    restoredSection = section
    lastPersistedOffset = SettingsRestorationDefaults.scrollOffset(for: section)
  }

  private func waitForPendingRestore(
    _ state: SettingsScrollState,
    for section: SettingsSection
  ) -> Bool {
    guard let pendingRestore, pendingRestore.section == section else {
      return false
    }
    guard pendingRestore.generation == restoreGeneration else {
      self.pendingRestore = nil
      return false
    }

    let targetOffset = pendingRestore.offset
    guard targetOffset > 0 else {
      finishRestore(for: section, observedOffset: state.offsetY)
      return false
    }
    guard state.maxOffsetY + Self.restoreTolerance >= targetOffset else {
      scrollPosition = ScrollPosition(point: CGPoint(x: 0, y: targetOffset))
      return true
    }
    guard abs(state.offsetY - targetOffset) <= Self.restoreTolerance else {
      scrollPosition = ScrollPosition(point: CGPoint(x: 0, y: targetOffset))
      return true
    }

    finishRestore(for: section, observedOffset: state.offsetY)
    return false
  }

  private func finishRestore(
    for section: SettingsSection,
    observedOffset: CGFloat
  ) {
    pendingRestore = nil
    restoredSection = section
    lastObservedOffset = observedOffset
  }

  private func persistObservedOffset(
    _ offset: CGFloat,
    for section: SettingsSection,
    force: Bool
  ) {
    let normalizedOffset = SettingsRestorationDefaults.normalizedScrollOffset(offset)
    let shouldPersist =
      force
      || lastPersistedOffset.map { abs($0 - normalizedOffset) >= Self.persistenceStep } ?? true
    guard shouldPersist else {
      return
    }
    SettingsRestorationDefaults.storeScrollOffset(normalizedOffset, for: section)
    lastPersistedOffset = normalizedOffset
  }

  private struct PendingRestore: Equatable {
    var section: SettingsSection
    var offset: CGFloat
    var generation: UInt64
  }

  private struct SettingsScrollState: Equatable {
    var offsetY: CGFloat
    var maxOffsetY: CGFloat
  }
}
