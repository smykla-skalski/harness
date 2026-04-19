import OpenTelemetryApi

extension HarnessMonitorTelemetry {
  func setSessionBaggage(sessionID: String, projectID: String?) {
    bootstrap()
    let builder = OpenTelemetry.instance.baggageManager.baggageBuilder()
    if let sessionKey = EntryKey(name: "session.id"),
      let sessionValue = EntryValue(string: sessionID)
    {
      builder.put(key: sessionKey, value: sessionValue, metadata: nil)
    }
    if let projectID,
      let projectKey = EntryKey(name: "project.id"),
      let projectValue = EntryValue(string: projectID)
    {
      builder.put(key: projectKey, value: projectValue, metadata: nil)
    }
    stateLock.withLock { state.currentBaggage = builder.build() }
  }

  func clearSessionBaggage() {
    bootstrap()
    stateLock.withLock { state.currentBaggage = nil }
  }
}
