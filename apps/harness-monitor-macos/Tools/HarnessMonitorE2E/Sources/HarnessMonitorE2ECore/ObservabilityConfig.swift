import Foundation

public enum ObservabilityConfig {
  /// Write the localhost observability fixture into `<dataHome>/harness/observability/config.json`.
  /// Mirrors the heredoc in test-agents-e2e.sh; bytes match for diff stability.
  public static func seed(dataHome: URL) throws {
    let dir =
      dataHome
      .appendingPathComponent("harness", isDirectory: true)
      .appendingPathComponent("observability", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("config.json")
    let json = """
      {
        "enabled": true,
        "grpc_endpoint": "http://127.0.0.1:4317",
        "http_endpoint": "http://127.0.0.1:4318",
        "grafana_url": "http://127.0.0.1:3000",
        "tempo_url": "http://127.0.0.1:3200",
        "loki_url": "http://127.0.0.1:3100",
        "prometheus_url": "http://127.0.0.1:9090",
        "pyroscope_url": "http://127.0.0.1:4040",
        "monitor_smoke_enabled": false,
        "headers": {}
      }
      """
    try Data(json.utf8).write(to: path, options: .atomic)
  }
}
