import OpenTelemetryApi

struct HarnessMonitorTelemetryPhase1Instruments: @unchecked Sendable {
  private let appLifecycleCounter: HarnessMonitorLongCounterRecorder
  private let appBootstrapDuration: HarnessMonitorDoubleHistogramRecorder
  private let bootstrapPhaseCounter: HarnessMonitorLongCounterRecorder
  private let bootstrapPhaseDuration: HarnessMonitorDoubleHistogramRecorder
  private let userInteractionCounter: HarnessMonitorLongCounterRecorder
  private let userInteractionDuration: HarnessMonitorDoubleHistogramRecorder
  private let cacheHitCounter: HarnessMonitorLongCounterRecorder
  private let cacheMissCounter: HarnessMonitorLongCounterRecorder
  private let cacheReadDuration: HarnessMonitorDoubleHistogramRecorder
  private let residentMemoryGauge: HarnessMonitorLongGaugeRecorder
  private let virtualMemoryGauge: HarnessMonitorLongGaugeRecorder
  private let activityGauges: HarnessMonitorTelemetryActivityGauges
  private let apiErrorCounter: HarnessMonitorLongCounterRecorder
  private let decodingErrorCounter: HarnessMonitorLongCounterRecorder
  private let timeoutErrorCounter: HarnessMonitorLongCounterRecorder

  init(meter: some Meter) {
    let appLifecycleCounter =
      meter
      .counterBuilder(name: "harness_monitor_app_lifecycle_total")
      .build()
    let appBootstrapDuration =
      meter
      .histogramBuilder(name: "harness_monitor_bootstrap_duration_ms")
      .build()
    let bootstrapPhaseCounter =
      meter
      .counterBuilder(name: "harness_monitor_bootstrap_phases_total")
      .build()
    let bootstrapPhaseDuration =
      meter
      .histogramBuilder(name: "harness_monitor_bootstrap_phase_duration_ms")
      .build()
    let userInteractionCounter =
      meter
      .counterBuilder(name: "harness_monitor_user_interactions_total")
      .build()
    let userInteractionDuration =
      meter
      .histogramBuilder(name: "harness_monitor_user_interaction_duration_ms")
      .build()
    let cacheHitCounter =
      meter
      .counterBuilder(name: "harness_monitor_cache_hits_total")
      .build()
    let cacheMissCounter =
      meter
      .counterBuilder(name: "harness_monitor_cache_misses_total")
      .build()
    let cacheReadDuration =
      meter
      .histogramBuilder(name: "harness_monitor_cache_read_duration_ms")
      .build()
    let residentMemoryGauge =
      meter
      .gaugeBuilder(name: "harness_monitor_memory_resident_bytes")
      .ofLongs()
      .build()
    let virtualMemoryGauge =
      meter
      .gaugeBuilder(name: "harness_monitor_memory_virtual_bytes")
      .ofLongs()
      .build()
    let activityGauges = HarnessMonitorTelemetryActivityGauges(meter: meter)
    let apiErrorCounter =
      meter
      .counterBuilder(name: "harness_monitor_api_errors_total")
      .build()
    let decodingErrorCounter =
      meter
      .counterBuilder(name: "harness_monitor_decoding_errors_total")
      .build()
    let timeoutErrorCounter =
      meter
      .counterBuilder(name: "harness_monitor_timeout_errors_total")
      .build()

    self.appLifecycleCounter = HarnessMonitorLongCounterRecorder(counter: appLifecycleCounter)
    self.appBootstrapDuration = HarnessMonitorDoubleHistogramRecorder(
      histogram: appBootstrapDuration
    )
    self.bootstrapPhaseCounter = HarnessMonitorLongCounterRecorder(counter: bootstrapPhaseCounter)
    self.bootstrapPhaseDuration = HarnessMonitorDoubleHistogramRecorder(
      histogram: bootstrapPhaseDuration
    )
    self.userInteractionCounter = HarnessMonitorLongCounterRecorder(counter: userInteractionCounter)
    self.userInteractionDuration = HarnessMonitorDoubleHistogramRecorder(
      histogram: userInteractionDuration
    )
    self.cacheHitCounter = HarnessMonitorLongCounterRecorder(counter: cacheHitCounter)
    self.cacheMissCounter = HarnessMonitorLongCounterRecorder(counter: cacheMissCounter)
    self.cacheReadDuration = HarnessMonitorDoubleHistogramRecorder(histogram: cacheReadDuration)
    self.residentMemoryGauge = HarnessMonitorLongGaugeRecorder(gauge: residentMemoryGauge)
    self.virtualMemoryGauge = HarnessMonitorLongGaugeRecorder(gauge: virtualMemoryGauge)
    self.activityGauges = activityGauges
    self.apiErrorCounter = HarnessMonitorLongCounterRecorder(counter: apiErrorCounter)
    self.decodingErrorCounter = HarnessMonitorLongCounterRecorder(counter: decodingErrorCounter)
    self.timeoutErrorCounter = HarnessMonitorLongCounterRecorder(counter: timeoutErrorCounter)
  }

  func recordAppLifecycleEvent(
    event: String,
    launchMode: String,
    durationMs: Double?
  ) {
    let attributes: [String: AttributeValue] = [
      "app.lifecycle.event": .string(event),
      "app.launch_mode": .string(launchMode),
    ]
    appLifecycleCounter.add(value: 1, attributes: attributes)
    if let durationMs, event == "bootstrap" {
      appBootstrapDuration.record(value: durationMs, attributes: attributes)
    }
  }

  func recordBootstrapPhase(
    phase: String,
    launchMode: String,
    durationMs: Double,
    failed: Bool
  ) {
    let attributes: [String: AttributeValue] = [
      "bootstrap.phase": .string(phase),
      "app.launch_mode": .string(launchMode),
      "bootstrap.failed": .bool(failed),
    ]
    bootstrapPhaseCounter.add(value: 1, attributes: attributes)
    bootstrapPhaseDuration.record(value: durationMs, attributes: attributes)
  }

  func recordUserInteraction(
    interaction: String,
    sessionID: String?,
    durationMs: Double
  ) {
    var attributes: [String: AttributeValue] = [
      "user.interaction.type": .string(interaction)
    ]
    if let sessionID {
      attributes["session.id"] = .string(sessionID)
    }
    userInteractionCounter.add(value: 1, attributes: attributes)
    userInteractionDuration.record(value: durationMs, attributes: attributes)
  }

  func recordCacheRead(
    operation: String,
    hit: Bool,
    durationMs: Double
  ) {
    let attributes: [String: AttributeValue] = [
      "cache.operation": .string(operation),
      "cache.hit": .bool(hit),
    ]
    if hit {
      cacheHitCounter.add(value: 1, attributes: attributes)
    } else {
      cacheMissCounter.add(value: 1, attributes: attributes)
    }
    cacheReadDuration.record(value: durationMs, attributes: attributes)
  }

  func recordResourceMetrics(
    residentMemoryBytes: Int64,
    virtualMemoryBytes: Int64
  ) {
    residentMemoryGauge.record(value: Int(clamping: residentMemoryBytes), attributes: [:])
    virtualMemoryGauge.record(value: Int(clamping: virtualMemoryBytes), attributes: [:])
  }

  func recordActiveTasks(_ count: Int) {
    activityGauges.recordActiveTasks(count)
  }

  func recordWebSocketConnections(_ count: Int) {
    activityGauges.recordWebSocketConnections(count)
  }

  func recordAPIError(
    endpoint: String,
    method: String,
    errorType: String,
    statusCode: Int?
  ) {
    var attributes: [String: AttributeValue] = [
      "url.path": .string(endpoint),
      "http.request.method": .string(method),
      "error.type": .string(errorType),
    ]
    if let statusCode {
      attributes["http.response.status_code"] = .int(statusCode)
    }
    apiErrorCounter.add(value: 1, attributes: attributes)
  }

  func recordDecodingError(
    entity: String,
    reason: String
  ) {
    decodingErrorCounter.add(
      value: 1,
      attributes: [
        "error.entity": .string(entity),
        "error.reason": .string(reason),
      ]
    )
  }

  func recordTimeoutError(
    operation: String,
    durationMs: Double
  ) {
    timeoutErrorCounter.add(
      value: 1,
      attributes: [
        "timeout.operation": .string(operation),
        "timeout.duration_ms": .double(durationMs),
      ]
    )
  }
}
