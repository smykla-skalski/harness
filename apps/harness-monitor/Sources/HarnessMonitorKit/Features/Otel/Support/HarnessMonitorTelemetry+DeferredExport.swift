import Foundation
import GRPC
import OpenTelemetryApi
import OpenTelemetryProtocolExporterCommon
import OpenTelemetryProtocolExporterGrpc
import OpenTelemetrySdk

struct HarnessMonitorTelemetryRegistrationPlan {
  let registration: HarnessMonitorTelemetryRegistration
  let deferredExportActivation: HarnessMonitorTelemetry.DeferredExportActivation?
}

extension HarnessMonitorTelemetry {
  private static let deferredExportProbeBackoff: Duration = .seconds(1)

  func registrationPlan(
    resource: Resource,
    config: HarnessMonitorObservabilityConfig?,
    environment: HarnessMonitorEnvironment
  ) -> HarnessMonitorTelemetryRegistrationPlan {
    guard let config else {
      return HarnessMonitorTelemetryRegistrationPlan(
        registration: registerProviders(resource: resource, config: nil),
        deferredExportActivation: nil
      )
    }

    guard let activation = deferredExportActivation(resource: resource, config: config) else {
      return HarnessMonitorTelemetryRegistrationPlan(
        registration: registerExportingProviders(
          resource: resource,
          config: config,
          environment: environment
        ),
        deferredExportActivation: nil
      )
    }

    let endpoint = config.grpcEndpoint?.absoluteString ?? ""
    HarnessMonitorLogger.lifecycle.notice(
      "Deferring gRPC export until the loopback collector accepts OTLP traffic at \(endpoint)"
    )
    return HarnessMonitorTelemetryRegistrationPlan(
      registration: registerExportingProviders(
        resource: resource,
        config: config,
        environment: environment,
        deferredExportActivation: activation
      ),
      deferredExportActivation: activation
    )
  }

  func bootstrapMessage(
    config: HarnessMonitorObservabilityConfig?,
    deferredExportActivation: DeferredExportActivation?
  ) -> String {
    guard let config else {
      return "Harness Monitor telemetry bootstrapped without exporter."
    }
    guard deferredExportActivation != nil else {
      return "Harness Monitor telemetry bootstrapped with exporter."
    }
    if config.transport == .grpc {
      return [
        "Harness Monitor telemetry bootstrapped with persistent export buffering",
        "while the loopback gRPC collector becomes ready for OTLP traffic.",
      ].joined(separator: " ")
    }
    return "Harness Monitor telemetry bootstrapped with exporter."
  }

  func activateDeferredExportIfNeeded() {
    guard let activation = deferredActivationCandidate() else {
      return
    }
    Task.detached(priority: .utility) { [self] in
      let ready = otlpCollectorAcceptsTraceExports(for: activation)
      finishDeferredExportAttempt(activation: activation, ready: ready)
    }
  }

  func deferredExportActivation(
    resource: Resource,
    config: HarnessMonitorObservabilityConfig
  ) -> DeferredExportActivation? {
    guard
      config.transport == .grpc,
      let grpcEndpoint = config.grpcEndpoint,
      let probe = deferredLoopbackProbe(for: grpcEndpoint)
    else {
      return nil
    }
    guard
      DaemonPortProbe.isListening(
        host: probe.host,
        port: probe.port,
        timeout: .milliseconds(200)
      ) == false
    else {
      return nil
    }

    return DeferredExportActivation(
      resource: resource,
      config: config,
      probeHost: probe.host,
      probePort: probe.port,
      nextProbeAfter: ContinuousClock().now + Self.deferredExportProbeBackoff
    )
  }

  private func deferredActivationCandidate() -> DeferredExportActivation? {
    let clock = ContinuousClock()
    let activation = stateLock.withLock { () -> DeferredExportActivation? in
      guard
        let activation = state.deferredExportActivation,
        state.deferredExportActivationInFlight == false,
        clock.now >= activation.nextProbeAfter
      else {
        return nil
      }
      return activation
    }
    guard let activation else {
      return nil
    }
    guard
      DaemonPortProbe.isListening(
        host: activation.probeHost,
        port: activation.probePort,
        timeout: .milliseconds(200)
      )
    else {
      stateLock.withLock {
        guard state.deferredExportActivationInFlight == false else {
          return
        }
        state.deferredExportActivation?.nextProbeAfter =
          clock.now + Self.deferredExportProbeBackoff
      }
      return nil
    }

    return stateLock.withLock { () -> DeferredExportActivation? in
      guard
        let currentActivation = state.deferredExportActivation,
        currentActivation.probeHost == activation.probeHost,
        currentActivation.probePort == activation.probePort,
        state.deferredExportActivationInFlight == false
      else {
        return nil
      }
      state.deferredExportActivationInFlight = true
      return currentActivation
    }
  }

  private func deferredLoopbackProbe(for endpoint: URL) -> (host: String, port: UInt16)? {
    guard let host = endpoint.host(percentEncoded: false) else {
      return nil
    }
    guard let normalizedHost = normalizedLoopbackHost(host) else {
      return nil
    }
    let rawPort = endpoint.port ?? 4317
    guard let port = UInt16(exactly: rawPort), port != 0 else {
      return nil
    }
    return (host: normalizedHost, port: port)
  }

  private func normalizedLoopbackHost(_ host: String) -> String? {
    switch host.lowercased() {
    case "127.0.0.1", "localhost":
      return "127.0.0.1"
    default:
      return nil
    }
  }

  private func activationAttributes(
    config: HarnessMonitorObservabilityConfig
  ) -> [String: AttributeValue] {
    var attributes = bootstrapAttributes(config: config)
    attributes["otel.export.activation_reason"] = .string("loopback_collector_accepted_otlp_export")
    return attributes
  }

  private func finishDeferredExportAttempt(
    activation: DeferredExportActivation,
    ready: Bool
  ) {
    let clock = ContinuousClock()
    let exportControl = stateLock.withLock { () -> HarnessMonitorTelemetryExportControl? in
      guard
        let currentActivation = state.deferredExportActivation,
        currentActivation.id == activation.id
      else {
        state.deferredExportActivationInFlight = false
        return nil
      }

      state.deferredExportActivationInFlight = false
      guard ready else {
        state.deferredExportActivation?.nextProbeAfter =
          clock.now + Self.deferredExportProbeBackoff
        return nil
      }

      state.deferredExportActivation = nil
      return state.exportControl
    }

    guard ready else {
      return
    }

    exportControl?.forceFlush()

    let endpoint = activation.config.grpcEndpoint?.absoluteString ?? ""
    HarnessMonitorLogger.lifecycle.info(
      "Activated gRPC export after collector accepted OTLP traffic at \(endpoint, privacy: .public)"
    )
    emitLog(
      name: "observability.export.activated",
      severity: .info,
      body: "Telemetry activated gRPC exporter after the loopback collector accepted OTLP exports.",
      attributes: activationAttributes(config: activation.config)
    )
  }

  private func otlpCollectorAcceptsTraceExports(
    for activation: DeferredExportActivation
  ) -> Bool {
    guard let endpoint = activation.config.grpcEndpoint else {
      return false
    }

    let otlpHeaders = activation.config.headers.map { ($0.key, $0.value) }
    let otlpConfig = OtlpConfiguration(
      timeout: 0.25,
      compression: .gzip,
      headers: otlpHeaders.isEmpty ? nil : otlpHeaders,
      exportAsJson: false
    )
    let group = PlatformSupport.makeEventLoopGroup(loopCount: 1)
    let channel = makeGRPCChannel(endpoint: endpoint, group: group)
    let exporter = OtlpTraceExporter(
      channel: channel,
      config: otlpConfig,
      envVarHeaders: nil
    )
    let result = exporter.export(spans: [], explicitTimeout: otlpConfig.timeout)
    exporter.shutdown(explicitTimeout: otlpConfig.timeout)
    try? group.syncShutdownGracefully()
    return result == .success
  }
}
