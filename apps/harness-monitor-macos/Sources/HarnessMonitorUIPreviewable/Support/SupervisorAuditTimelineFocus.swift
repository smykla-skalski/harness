import SwiftUI

/// Scene-focused entry point for the Supervisor audit timeline. Menu commands
/// (View > Audit Timeline / Cmd-Shift-A) read this focused value to dispatch
/// the open action without holding a direct reference to the host scene's
/// settings-navigation state.
///
/// Two consumers register through this dispatcher:
///
/// * The scene installs a `navigationHandler` that opens the Settings window
///   and routes to the Audit pane. It runs on every invoke.
/// * The Audit pane installs a `filterHandler` while it is mounted so the
///   query payload (rule/decision ids) can pre-apply to its filter state.
///   Because the pane is not yet on screen the first time a cross-link
///   fires, the dispatcher also records the most recent query as
///   `pendingQuery` and replays it the moment a `filterHandler` registers.
@MainActor
public final class SupervisorAuditTimelineFocusDispatcher {
  public var navigationHandler: ((SupervisorAuditTimelineQuery) -> Void)?
  public private(set) var pendingQuery: SupervisorAuditTimelineQuery?

  private var filterHandler: ((SupervisorAuditTimelineQuery) -> Void)?

  public init() {}

  public func invoke(query: SupervisorAuditTimelineQuery = SupervisorAuditTimelineQuery()) {
    navigationHandler?(query)
    if let filterHandler {
      filterHandler(query)
    } else {
      pendingQuery = query
    }
  }

  /// Register the consumer that maps `SupervisorAuditTimelineQuery` onto a
  /// filter state. Replays the most recent pending query (if any) so a
  /// cross-link that fired before the pane was mounted still pre-applies.
  public func registerFilterHandler(
    _ handler: @escaping (SupervisorAuditTimelineQuery) -> Void
  ) {
    filterHandler = handler
    if let pendingQuery {
      handler(pendingQuery)
      self.pendingQuery = nil
    }
  }

  public func clearFilterHandler() {
    filterHandler = nil
  }
}

public struct SupervisorAuditTimelineFocus: Equatable {
  public let dispatcher: SupervisorAuditTimelineFocusDispatcher

  public init(dispatcher: SupervisorAuditTimelineFocusDispatcher) {
    self.dispatcher = dispatcher
  }

  @MainActor
  public func invoke(query: SupervisorAuditTimelineQuery = SupervisorAuditTimelineQuery()) {
    dispatcher.invoke(query: query)
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.dispatcher === rhs.dispatcher
  }
}

extension FocusedValues {
  @Entry public var supervisorAuditTimelineFocus: SupervisorAuditTimelineFocus?
}

extension EnvironmentValues {
  /// Shared dispatcher used by the Audit pane to register its filter handler.
  /// The dispatcher lives at app scope so the dashboard scene (which sets the
  /// navigation handler) and the Settings scene (where the pane mounts and
  /// installs the filter handler) reach the same instance.
  @Entry public var supervisorAuditTimelineDispatcher: SupervisorAuditTimelineFocusDispatcher?
}
