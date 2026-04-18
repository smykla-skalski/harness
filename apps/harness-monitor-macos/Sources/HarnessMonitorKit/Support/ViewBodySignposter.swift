import OSLog

public enum ViewBodySignposter {
  private static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "view"
  )

  public static func measure<T>(_ viewName: String, body: () -> T) -> T {
    let state = signposter.beginInterval("view.body", id: .exclusive)
    defer { signposter.endInterval("view.body", state) }
    return body()
  }
}
