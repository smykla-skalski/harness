enum AgentTuiSheetSelection: Hashable {
  case create
  case session(String)

  var sessionID: String? {
    guard case .session(let sessionID) = self else {
      return nil
    }
    return sessionID
  }
}
