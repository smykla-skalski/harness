import SwiftUI

/// Scene-focused entry point for the Supervisor audit timeline. Menu commands
/// (View > Audit Timeline / Cmd-Shift-A) read this focused value to dispatch
/// the open action without holding a direct reference to the host scene's
/// settings-navigation state.
@MainActor
public final class SupervisorAuditTimelineFocusDispatcher {
  public var handler: ((SupervisorAuditTimelineQuery) -> Void)?

  public init() {}

  public func invoke(query: SupervisorAuditTimelineQuery = SupervisorAuditTimelineQuery()) {
    handler?(query)
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
