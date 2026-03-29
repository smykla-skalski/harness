import Foundation

public enum TransportKind: String, Equatable, Sendable {
  case webSocket
  case httpSSE

  public var title: String {
    switch self {
    case .webSocket:
      "WebSocket"
    case .httpSSE:
      "Server-Sent Events"
    }
  }

  public var shortTitle: String {
    switch self {
    case .webSocket:
      "WS"
    case .httpSSE:
      "SSE"
    }
  }
}

public enum ConnectionQuality: String, Equatable, Sendable {
  case excellent
  case good
  case degraded
  case poor
  case disconnected

  public init(latencyMs: Int?) {
    guard let latencyMs else {
      self = .disconnected
      return
    }
    switch latencyMs {
    case ..<50: self = .excellent
    case ..<150: self = .good
    case ..<500: self = .degraded
    default: self = .poor
    }
  }

  public var title: String {
    switch self {
    case .excellent:
      "Excellent"
    case .good:
      "Good"
    case .degraded:
      "Degraded"
    case .poor:
      "Poor"
    case .disconnected:
      "Disconnected"
    }
  }
}

public struct ConnectionMetrics: Equatable, Sendable {
  public var transportKind: TransportKind
  public var latencyMs: Int?
  public var averageLatencyMs: Int?
  public var messagesReceived: Int
  public var messagesSent: Int
  public var messagesPerSecond: Double
  public var connectedSince: Date?
  public var lastMessageAt: Date?
  public var reconnectAttempt: Int
  public var reconnectCount: Int
  public var isFallback: Bool
  public var fallbackReason: String?

  public var quality: ConnectionQuality {
    ConnectionQuality(latencyMs: latencyMs)
  }

  public static let initial: Self = {
    Self(
      transportKind: .httpSSE,
      latencyMs: nil,
      averageLatencyMs: nil,
      messagesReceived: 0,
      messagesSent: 0,
      messagesPerSecond: 0,
      connectedSince: nil,
      lastMessageAt: nil,
      reconnectAttempt: 0,
      reconnectCount: 0,
      isFallback: false,
      fallbackReason: nil
    )
  }()
}

public struct ConnectionEvent: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let timestamp: Date
  public let kind: ConnectionEventKind
  public let detail: String
  public let transportKind: TransportKind

  public init(kind: ConnectionEventKind, detail: String, transportKind: TransportKind) {
    id = UUID()
    timestamp = Date()
    self.kind = kind
    self.detail = detail
    self.transportKind = transportKind
  }
}

public enum ConnectionEventKind: String, Equatable, Sendable {
  case connected
  case disconnected
  case reconnecting
  case fallback
  case error

  public var title: String {
    switch self {
    case .connected:
      "Connected"
    case .disconnected:
      "Disconnected"
    case .reconnecting:
      "Reconnecting"
    case .fallback:
      "Fallback"
    case .error:
      "Error"
    }
  }
}
