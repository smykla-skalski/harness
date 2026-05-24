extension HarnessMonitorStore {
  public var lastRefreshTimings: HarnessMonitorRefreshTimings? {
    get { connection.lastRefreshTimings }
    set { connection.lastRefreshTimings = newValue }
  }
}
