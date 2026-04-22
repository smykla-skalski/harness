import os

public enum HarnessMonitorLogger {
  public static let defaultDaemonLogLevel = "trace"
  public static let defaultDaemonFilter = "harness=trace"
  public static let defaultAppLogLevel = OSLogType.debug

  public static let api = Logger(subsystem: "io.harnessmonitor", category: "api")
  public static let websocket = Logger(subsystem: "io.harnessmonitor", category: "websocket")
  public static let store = Logger(subsystem: "io.harnessmonitor", category: "store")
  public static let lifecycle = Logger(subsystem: "io.harnessmonitor", category: "lifecycle")
  public static let sleep = Logger(subsystem: "io.harnessmonitor", category: "sleep")
  public static let thumbnail = Logger(subsystem: "io.harnessmonitor", category: "thumbnail")
  public static let supervisor = Logger(subsystem: "io.harnessmonitor", category: "supervisor")
}
