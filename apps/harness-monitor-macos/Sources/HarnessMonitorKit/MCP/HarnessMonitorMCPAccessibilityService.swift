import Foundation
import HarnessMonitorRegistry
import OSLog

/// Owns the in-app accessibility registry and its NDJSON Unix-socket
/// listener. The listener stays off until `setEnabled(true)` is called so
/// the app introduces no socket surface by default.
///
/// The service is intentionally a simple reference type instead of a
/// SwiftUI observable: it is started and stopped from the scene layer in
/// response to `@AppStorage` changes, and it does not drive any UI.
@MainActor
public final class HarnessMonitorMCPAccessibilityService {
  public static let shared = HarnessMonitorMCPAccessibilityService()

  public let registry: AccessibilityRegistry
  private let dispatcher: RegistryRequestDispatcher
  private let logger: Logger
  private var listener: RegistryListener?
  private var runningSocketURL: URL?

  public init(
    registry: AccessibilityRegistry = AccessibilityRegistry(),
    logger: Logger = Logger(subsystem: "io.harnessmonitor", category: "mcp-registry")
  ) {
    self.registry = registry
    self.dispatcher = RegistryRequestDispatcher(
      registry: registry,
      pingInfo: Self.makePingInfoProvider()
    )
    self.logger = logger
  }

  /// Whether the listener is currently bound to its socket.
  public var isRunning: Bool {
    listener != nil
  }

  /// Start or stop the registry host to match `enabled`. Safe to call
  /// repeatedly with the same value.
  public func setEnabled(_ enabled: Bool) async {
    if enabled {
      await startIfNeeded()
    } else {
      await stop()
    }
  }

  private func startIfNeeded() async {
    guard listener == nil else { return }
    guard let socket = HarnessMonitorMCPSocketPath.resolved() else {
      logger.error(
        "harness-monitor MCP: cannot resolve app-group container; host not started"
      )
      return
    }
    let listener = RegistryListener(dispatcher: dispatcher, logger: logger)
    do {
      try await listener.start(at: socket.path)
    } catch {
      let socketPath = socket.path
      let description = error.localizedDescription
      logger.error(
        "MCP start failed at \(socketPath, privacy: .public): \(description, privacy: .public)"
      )
      return
    }
    self.listener = listener
    self.runningSocketURL = socket
    logger.trace(
      "harness-monitor MCP: registry host started at \(socket.path, privacy: .public)"
    )
  }

  private func stop() async {
    guard let listener else { return }
    await listener.stop()
    self.listener = nil
    if let socketURL = runningSocketURL {
      logger.trace(
        "harness-monitor MCP: registry host stopped at \(socketURL.path, privacy: .public)"
      )
      self.runningSocketURL = nil
    }
  }

  private static func makePingInfoProvider() -> @Sendable () -> PingResult {
    let bundle = Bundle.main
    let version =
      (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    let bundleId = bundle.bundleIdentifier ?? "io.harnessmonitor.app"
    return { @Sendable in
      PingResult(
        protocolVersion: 1,
        appVersion: version,
        bundleIdentifier: bundleId
      )
    }
  }
}
