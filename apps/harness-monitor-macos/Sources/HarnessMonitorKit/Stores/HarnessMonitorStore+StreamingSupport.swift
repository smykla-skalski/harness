import Foundation

extension HarnessMonitorStore {
  func reconnectDelay(for attempt: Int) -> Duration {
    Self.streamReconnectDelays[min(attempt, Self.streamReconnectDelays.count - 1)]
  }
}
