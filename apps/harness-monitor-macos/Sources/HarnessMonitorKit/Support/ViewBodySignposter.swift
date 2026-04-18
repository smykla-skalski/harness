import OSLog

public enum ViewBodySignposter {
  private static let bridge = HarnessMonitorSignpostBridge(
    subsystem: "io.harnessmonitor",
    category: "view"
  )

  public static func measure<T>(_ viewName: String, body: () -> T) -> T {
    let (state, span) = bridge.beginInterval(name: "view.body")
    span.setAttribute(key: "harness.view.name", value: viewName)
    defer { bridge.endInterval(name: "view.body", state: state) }
    return body()
  }
}
