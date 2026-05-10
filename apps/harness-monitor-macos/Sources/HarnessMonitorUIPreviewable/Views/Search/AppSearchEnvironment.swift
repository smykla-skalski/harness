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
