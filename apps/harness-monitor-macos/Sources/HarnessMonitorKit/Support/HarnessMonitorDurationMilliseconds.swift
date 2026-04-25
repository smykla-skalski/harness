import Foundation

func harnessMonitorDurationMilliseconds(_ duration: Duration) -> Double {
  Double(duration.components.seconds) * 1_000
    + Double(duration.components.attoseconds) / 1_000_000_000_000_000
}
