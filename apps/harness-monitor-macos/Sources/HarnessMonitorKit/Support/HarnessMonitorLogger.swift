import os

enum HarnessMonitorLogger {
    static let api = Logger(subsystem: "io.harnessmonitor", category: "api")
    static let websocket = Logger(subsystem: "io.harnessmonitor", category: "websocket")
    static let store = Logger(subsystem: "io.harnessmonitor", category: "store")
    static let lifecycle = Logger(subsystem: "io.harnessmonitor", category: "lifecycle")
}
