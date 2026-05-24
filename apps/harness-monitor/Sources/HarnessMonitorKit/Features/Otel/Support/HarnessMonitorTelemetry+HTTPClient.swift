import Foundation
import OpenTelemetryProtocolExporterHttp

extension HarnessMonitorTelemetry {
  func makeHTTPExporterClient() -> any HTTPClient {
    let session = stateLock.withLock { state.httpExporterSessionOverride }
    guard let session else {
      return BaseHTTPClient()
    }
    return BaseHTTPClient(session: session)
  }

  func swiftDataStoreSize(atPath path: String) -> Int64 {
    let paths = [path, path + "-wal", path + "-shm"]
    var total: Int64 = 0
    for candidate in paths {
      let attrs = try? FileManager.default.attributesOfItem(atPath: candidate)
      if let size = attrs?[.size] as? Int64 {
        total += size
      }
    }
    return total
  }
}
