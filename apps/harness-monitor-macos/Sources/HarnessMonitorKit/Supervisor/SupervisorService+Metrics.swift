import Foundation

extension SupervisorService {
  func recordTickLatency(startedAt: Date) {
    tickLatencySamplesMs.append(Date().timeIntervalSince(startedAt) * 1_000)
    if tickLatencySamplesMs.count > 32 {
      tickLatencySamplesMs.removeFirst(tickLatencySamplesMs.count - 32)
    }
  }

  func percentile(_ value: Double) -> Double {
    guard !tickLatencySamplesMs.isEmpty else {
      return 0
    }
    let sorted = tickLatencySamplesMs.sorted()
    let lastIndex = sorted.count - 1
    let index = Int((Double(lastIndex) * value).rounded(.down))
    return sorted[max(0, min(lastIndex, index))]
  }
}
