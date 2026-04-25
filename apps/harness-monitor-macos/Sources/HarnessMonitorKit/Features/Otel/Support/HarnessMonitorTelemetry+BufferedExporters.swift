import Foundation
import OpenTelemetrySdk
import PersistenceExporter

struct BufferedExporters {
  let traceExporter: any SpanExporter
  let logExporter: any LogRecordExporter
  let metricExporter: any MetricExporter
}

extension HarnessMonitorTelemetry {
  func bufferedExportersIfNeeded(
    traceExporter: any SpanExporter,
    logExporter: any LogRecordExporter,
    metricExporter: any MetricExporter,
    environment: HarnessMonitorEnvironment,
    activation: DeferredExportActivation?
  ) -> BufferedExporters {
    guard let activation else {
      return BufferedExporters(
        traceExporter: traceExporter,
        logExporter: logExporter,
        metricExporter: metricExporter
      )
    }

    let storageRoot = deferredExportStorageRoot(using: environment)
    let exportCondition = makeDeferredExportCondition(for: activation)

    do {
      let traceStorage = try deferredExportSignalStorageDirectory(
        named: "traces",
        root: storageRoot
      )
      let logStorage = try deferredExportSignalStorageDirectory(
        named: "logs",
        root: storageRoot
      )
      let metricStorage = try deferredExportSignalStorageDirectory(
        named: "metrics",
        root: storageRoot
      )
      return BufferedExporters(
        traceExporter: try PersistenceSpanExporterDecorator(
          spanExporter: traceExporter,
          storageURL: traceStorage,
          exportCondition: exportCondition,
          performancePreset: .instantDataDelivery
        ),
        logExporter: try PersistenceLogExporterDecorator(
          logRecordExporter: logExporter,
          storageURL: logStorage,
          exportCondition: exportCondition,
          performancePreset: .instantDataDelivery
        ),
        metricExporter: try PersistenceMetricExporterDecorator(
          metricExporter: metricExporter,
          storageURL: metricStorage,
          exportCondition: exportCondition,
          performancePreset: .instantDataDelivery
        )
      )
    } catch {
      HarnessMonitorLogger.lifecycle.warning(
        "Failed to enable persistent deferred OTLP export: \(error.localizedDescription, privacy: .public)"
      )
      return BufferedExporters(
        traceExporter: traceExporter,
        logExporter: logExporter,
        metricExporter: metricExporter
      )
    }
  }

  private func deferredExportStorageRoot(
    using environment: HarnessMonitorEnvironment
  ) -> URL {
    let root =
      HarnessMonitorPaths.harnessRoot(using: environment)
      .appendingPathComponent("observability", isDirectory: true)
      .appendingPathComponent("otlp-buffer", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    return root
  }

  private func deferredExportSignalStorageDirectory(
    named name: String,
    root: URL
  ) throws -> URL {
    let directory = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
  }

  private func makeDeferredExportCondition(
    for activation: DeferredExportActivation
  ) -> @Sendable () -> Bool {
    { [self, activationID = activation.id] in
      stateLock.withLock {
        state.deferredExportActivation?.id != activationID
      }
    }
  }
}
