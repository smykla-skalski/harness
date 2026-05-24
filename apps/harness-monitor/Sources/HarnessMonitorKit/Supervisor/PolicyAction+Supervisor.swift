extension PolicyAction {
  var isAutomaticSideEffect: Bool {
    switch self {
    case .nudgeAgent, .assignTask, .dropTask, .notifyOnly:
      true
    case .queueDecision, .logEvent, .suggestConfigChange:
      false
    }
  }
}
