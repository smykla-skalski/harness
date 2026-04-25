import Foundation

protocol HarnessMonitorResourceSampling: Sendable {
  func startSampling()
  func stopSampling()
}

public final class HarnessMonitorResourceMetrics: @unchecked Sendable {
  static let shared = HarnessMonitorResourceMetrics()

  private let sampleInterval: Duration
  private var sampleTask: Task<Void, Never>?
  private let lock = NSLock()

  public init(sampleInterval: Duration = .seconds(15)) {
    self.sampleInterval = sampleInterval
  }

  public func startSampling() {
    lock.withLock {
      guard sampleTask == nil else { return }
      sampleTask = Task { [weak self] in
        while !Task.isCancelled {
          self?.recordSample()
          try? await Task.sleep(for: self?.sampleInterval ?? .seconds(15))
        }
      }
    }
  }

  public func stopSampling() {
    lock.withLock {
      sampleTask?.cancel()
      sampleTask = nil
    }
  }

  func recordSample() {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { infoPtr in
      infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
      }
    }
    guard result == KERN_SUCCESS else {
      return
    }

    #if HARNESS_FEATURE_OTEL
      HarnessMonitorTelemetry.shared.recordResourceMetrics(
        residentMemoryBytes: Int64(info.phys_footprint),
        virtualMemoryBytes: Int64(info.virtual_size)
      )
    #else
      _ = info
    #endif
  }
}

extension HarnessMonitorResourceMetrics: HarnessMonitorResourceSampling {}
