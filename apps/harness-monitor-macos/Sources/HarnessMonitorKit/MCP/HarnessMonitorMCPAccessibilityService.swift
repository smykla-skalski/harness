import Darwin
import Foundation
import HarnessMonitorRegistry
import OSLog

public enum HarnessMonitorMCPRuntimeState: Equatable, Sendable {
  case disabled
  case starting(socketPath: String?)
  case healthy(socketPath: String)
  case degraded(socketPath: String?, reason: String)

  public var socketPath: String? {
    switch self {
    case .disabled:
      nil
    case .starting(let socketPath):
      socketPath
    case .healthy(let socketPath):
      socketPath
    case .degraded(let socketPath, _):
      socketPath
    }
  }

  public var reason: String? {
    switch self {
    case .degraded(_, let reason):
      reason
    case .disabled, .starting, .healthy:
      nil
    }
  }
}

@MainActor
public protocol HarnessMonitorMCPStartupControlling: AnyObject {
  var runtimeState: HarnessMonitorMCPRuntimeState { get }
  func setEnabled(_ enabled: Bool) async
}

/// Owns the in-app accessibility registry and its NDJSON Unix-socket
/// listener. The listener stays off until `setEnabled(true)` is called so
/// the app introduces no socket surface by default.
///
/// The service is intentionally a simple reference type instead of a
/// SwiftUI observable: a startup controller owns its lifecycle, and it does
/// not drive any UI.
@MainActor
public final class HarnessMonitorMCPAccessibilityService: HarnessMonitorMCPStartupControlling {
  public static let shared = HarnessMonitorMCPAccessibilityService()

  public let registry: AccessibilityRegistry
  private let dispatcher: RegistryRequestDispatcher
  private let logger: Logger
  private let socketPathResolver: @Sendable () -> URL?
  private let startupAttempts: Int
  private let startupProbeDelay: Duration
  private let startupProbeCount: Int
  private var listener: RegistryListener?
  private var runningSocketURL: URL?
  public private(set) var runtimeState: HarnessMonitorMCPRuntimeState = .disabled

  public init(
    registry: AccessibilityRegistry = AccessibilityRegistry(),
    logger: Logger = Logger(subsystem: "io.harnessmonitor", category: "mcp-registry"),
    socketPathResolver: @escaping @Sendable () -> URL? = { HarnessMonitorMCPSocketPath.resolved() },
    startupAttempts: Int = 3,
    startupProbeDelay: Duration = .milliseconds(50),
    startupProbeCount: Int = 20
  ) {
    self.registry = registry
    self.dispatcher = RegistryRequestDispatcher(
      registry: registry,
      pingInfo: Self.makePingInfoProvider()
    )
    self.logger = logger
    self.socketPathResolver = socketPathResolver
    self.startupAttempts = max(1, startupAttempts)
    self.startupProbeDelay = startupProbeDelay
    self.startupProbeCount = max(1, startupProbeCount)
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
    guard let socket = socketPathResolver() else {
      runtimeState = .degraded(
        socketPath: nil,
        reason: "cannot resolve app-group container"
      )
      logger.error(
        "harness-monitor MCP: cannot resolve app-group container; host not started"
      )
      return
    }

    if listener != nil, await socketAcceptsPing(at: socket.path) {
      runtimeState = .healthy(socketPath: socket.path)
      return
    }

    await stopListener()
    runtimeState = .starting(socketPath: socket.path)

    for attempt in 1...startupAttempts {
      let nextListener = RegistryListener(dispatcher: dispatcher, logger: logger)
      do {
        try await nextListener.start(at: socket.path)
      } catch {
        let description = error.localizedDescription
        logger.error(
          """
          MCP start failed at \(socket.path, privacy: .public) \
          on attempt \(attempt, privacy: .public): \(description, privacy: .public)
          """
        )
        runtimeState = .degraded(socketPath: socket.path, reason: description)
        cleanupSocketFileIfPresent(at: socket)
        continue
      }

      listener = nextListener
      runningSocketURL = socket

      if await waitForHealthySocket(at: socket.path) {
        runtimeState = .healthy(socketPath: socket.path)
        logger.trace(
          "harness-monitor MCP: registry host started at \(socket.path, privacy: .public)"
        )
        return
      }

      logger.error(
        """
        MCP listener never passed the local ping probe at \
        \(socket.path, privacy: .public) on attempt \(attempt, privacy: .public)
        """
      )
      await stopListener()
    }

    runtimeState = .degraded(
      socketPath: socket.path,
      reason: "listener never passed the local ping probe"
    )
  }

  private func stop() async {
    await stopListener()
    if let socketURL = socketPathResolver() {
      cleanupSocketFileIfPresent(at: socketURL)
    }
    runtimeState = .disabled
  }

  private func stopListener() async {
    guard let listener else {
      runningSocketURL = nil
      return
    }
    await listener.stop()
    self.listener = nil
    if let socketURL = runningSocketURL {
      logger.trace(
        "harness-monitor MCP: registry host stopped at \(socketURL.path, privacy: .public)"
      )
      runningSocketURL = nil
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

  private func waitForHealthySocket(at path: String) async -> Bool {
    for _ in 0..<startupProbeCount {
      if await socketAcceptsPing(at: path) {
        return true
      }
      try? await Task.sleep(for: startupProbeDelay)
    }
    return false
  }

  private func socketAcceptsPing(at path: String) async -> Bool {
    await Task.detached(priority: .utility) {
      pingSocket(at: path)
    }.value
  }

  private func cleanupSocketFileIfPresent(at socketURL: URL) {
    guard FileManager.default.fileExists(atPath: socketURL.path) else {
      return
    }
    do {
      try FileManager.default.removeItem(at: socketURL)
    } catch {
      logger.error(
        """
        Failed to remove stale MCP socket at \
        \(socketURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)
        """
      )
    }
  }
}

private func pingSocket(at path: String) -> Bool {
  let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else {
    return false
  }
  defer { Darwin.close(fd) }

  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  let pathBytes = Array(path.utf8)
  let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
  guard pathBytes.count < maxPathLength else {
    return false
  }
  withUnsafeMutableBytes(of: &addr.sun_path) { pointer in
    pointer.baseAddress?.copyMemory(from: pathBytes, byteCount: pathBytes.count)
  }
  let connectResult = withUnsafePointer(to: &addr) { addrPointer -> Int32 in
    addrPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
      Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  guard connectResult == 0 else {
    return false
  }

  var timeout = timeval(tv_sec: 1, tv_usec: 0)
  _ = Darwin.setsockopt(
    fd,
    SOL_SOCKET,
    SO_RCVTIMEO,
    &timeout,
    socklen_t(MemoryLayout<timeval>.size)
  )
  _ = Darwin.setsockopt(
    fd,
    SOL_SOCKET,
    SO_SNDTIMEO,
    &timeout,
    socklen_t(MemoryLayout<timeval>.size)
  )

  let payload = Data("{\"id\":1,\"op\":\"ping\"}\n".utf8)
  let sent = payload.withUnsafeBytes { buffer in
    Darwin.send(fd, buffer.baseAddress, buffer.count, 0)
  }
  guard sent >= 0 else {
    return false
  }

  var scratch = [UInt8](repeating: 0, count: 8 * 1024)
  let received = scratch.withUnsafeMutableBufferPointer { buffer in
    Darwin.recv(fd, buffer.baseAddress, buffer.count, 0)
  }
  guard received > 0 else {
    return false
  }

  guard let response = String(bytes: scratch.prefix(received), encoding: .utf8) else {
    return false
  }
  return response.contains("\"ok\":true")
}
