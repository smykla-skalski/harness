import HarnessMonitorKit
import SwiftUI

/// Environment plumbing for the unified session-window search.
///
/// Per-route lists (timeline, agents, tasks, decisions) read the model via
/// `@Environment(\.appSearchModel)` so they can mirror the resolved query
/// into their existing filter pipelines without owning a separate query
/// string.
public struct AppSearchModelKey: EnvironmentKey {
  public static let defaultValue: AppSearchModel? = nil
}

extension EnvironmentValues {
  public var appSearchModel: AppSearchModel? {
    get { self[AppSearchModelKey.self] }
    set { self[AppSearchModelKey.self] = newValue }
  }
}

/// Whether the session window's `.searchable` field is currently
/// presented. Drives lazy re-indexing in
/// ``AppSearchIndexUpdater`` so the four corpora are not rebuilt on
/// every incoming timeline event when the search popover is closed.
public struct HarnessSearchActiveKey: EnvironmentKey {
  public static let defaultValue: Bool = false
}

extension EnvironmentValues {
  public var harnessSearchActive: Bool {
    get { self[HarnessSearchActiveKey.self] }
    set { self[HarnessSearchActiveKey.self] = newValue }
  }
}
