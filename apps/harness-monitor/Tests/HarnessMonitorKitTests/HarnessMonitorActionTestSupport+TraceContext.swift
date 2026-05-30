import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func recordActiveTraceContext(operation: String) {
    #if HARNESS_FEATURE_OTEL
      let traceContext = HarnessMonitorTelemetry.shared.traceContext()
    #else
      let traceContext: [String: String] = [:]
    #endif
    lock.withLock {
      recordedTraceContextsByOperation[operation, default: []].append(traceContext)
    }
  }

  func lastRecordedTraceContext(for operation: String) -> [String: String]? {
    lock.withLock {
      recordedTraceContextsByOperation[operation]?.last
    }
  }
}
