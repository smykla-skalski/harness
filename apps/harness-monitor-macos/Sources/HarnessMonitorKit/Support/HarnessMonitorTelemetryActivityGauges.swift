import OpenTelemetryApi

struct HarnessMonitorTelemetryActivityGauges: @unchecked Sendable {
  private let activeTaskGauge: HarnessMonitorLongGaugeRecorder
  private let websocketConnectionGauge: HarnessMonitorLongGaugeRecorder

  init(meter: some Meter) {
    let activeTaskGauge =
      meter
      .gaugeBuilder(name: "harness_monitor_active_tasks")
      .ofLongs()
      .build()
    let websocketConnectionGauge =
      meter
      .gaugeBuilder(name: "harness_monitor_websocket_connections")
      .ofLongs()
      .build()

    self.activeTaskGauge = HarnessMonitorLongGaugeRecorder(gauge: activeTaskGauge)
    self.websocketConnectionGauge = HarnessMonitorLongGaugeRecorder(
      gauge: websocketConnectionGauge
    )
  }

  func recordActiveTasks(_ count: Int) {
    activeTaskGauge.record(value: max(0, count), attributes: [:])
  }

  func recordWebSocketConnections(_ count: Int) {
    websocketConnectionGauge.record(value: max(0, count), attributes: [:])
  }
}
