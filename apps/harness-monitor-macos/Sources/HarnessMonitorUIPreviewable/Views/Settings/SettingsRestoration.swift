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

extension EnvironmentValues {
  var settingsScrollRestorationSection: SettingsSection? {
    get { self[SettingsScrollRestorationSectionKey.self] }
    set { self[SettingsScrollRestorationSectionKey.self] = newValue }
  }
}

struct SettingsScrollRestorationModifier: ViewModifier {
  private static let persistenceStep: CGFloat = 24

  @Environment(\.settingsScrollRestorationSection)
  private var section
  @State private var lastObservedOffset: CGFloat = 0
  @State private var lastPersistedOffset: CGFloat?
  @State private var restoreGeneration: UInt64 = 0
  @State private var restoredSection: SettingsSection?
  @State private var scrollPosition = ScrollPosition()

  func body(content: Content) -> some View {
    Group {
      if let section {
        content
          .scrollPosition($scrollPosition)
          .onScrollGeometryChange(
            for: CGFloat.self,
            of: Self.offsetY
          ) { _, newOffset in
            lastObservedOffset = newOffset
            guard restoredSection == section else {
              return
            }
            persistObservedOffset(newOffset, for: section, force: false)
          }
          .onChange(of: section, initial: true) { _, newSection in
            restoreScrollPosition(for: newSection)
          }
          .onDisappear {
            persistObservedOffset(lastObservedOffset, for: section, force: true)
          }
      } else {
        content
      }
    }
  }

  private static func offsetY(_ geometry: ScrollGeometry) -> CGFloat {
    let maxOffset = max(0, geometry.contentSize.height - geometry.visibleRect.height)
    return min(max(0, geometry.contentOffset.y), maxOffset)
  }

  private func restoreScrollPosition(for section: SettingsSection) {
    restoreGeneration &+= 1
    let generation = restoreGeneration
    let offset = SettingsRestorationDefaults.scrollOffset(for: section)
    lastObservedOffset = offset
    lastPersistedOffset = offset
    restoredSection = nil
    scrollPosition = ScrollPosition(point: CGPoint(x: 0, y: offset))

    Task { @MainActor in
      await Task.yield()
      guard restoreGeneration == generation else {
        return
      }
      scrollPosition = ScrollPosition(point: CGPoint(x: 0, y: offset))
      restoredSection = section
    }
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
}
