import os

public enum HarnessMonitorLogger {
  public static let api = Logger(subsystem: "io.harnessmonitor", category: "api")
  public static let websocket = Logger(subsystem: "io.harnessmonitor", category: "websocket")
  public static let store = Logger(subsystem: "io.harnessmonitor", category: "store")
  public static let lifecycle = Logger(subsystem: "io.harnessmonitor", category: "lifecycle")
  public static let sleep = Logger(subsystem: "io.harnessmonitor", category: "sleep")
  public static let thumbnail = Logger(subsystem: "io.harnessmonitor", category: "thumbnail")
}
