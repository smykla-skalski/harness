import Darwin
import Foundation

public struct RegistrySocketClient: Sendable {
  public let timeout: TimeInterval

  public init(timeout: TimeInterval = 1) {
    self.timeout = timeout
  }

  public func ping(at socketPath: String) async throws -> PingResult {
    try await send(
      RegistryRequest(id: 1, op: .ping),
      toSocketAt: socketPath
    )
  }

  public func syncClientSnapshot(
    _ snapshot: RegistryClientSnapshot,
    toSocketAt socketPath: String
  ) async throws -> RegistryAckResult {
    try await send(
      RegistryRequest(
        id: 2,
        op: .syncClientSnapshot,
        clientSnapshot: snapshot
      ),
      toSocketAt: socketPath
    )
  }

  public func clearClientSnapshot(
    _ clearRequest: RegistryClientClearRequest,
    toSocketAt socketPath: String
  ) async throws -> RegistryAckResult {
    try await send(
      RegistryRequest(
        id: 3,
        op: .clearClientSnapshot,
        clientClear: clearRequest
      ),
      toSocketAt: socketPath
    )
  }

  public func sendReplacementNotice(
    _ notice: RegistryReplacementNotice,
    toSocketAt socketPath: String
  ) async throws -> RegistryAckResult {
    try await send(
      RegistryRequest(
        id: 4,
        op: .replacementNotice,
        replacementNotice: notice
      ),
      toSocketAt: socketPath
    )
  }

  public func performAction(
    identifier: String,
    action: RegistrySemanticAction,
    toSocketAt socketPath: String
  ) async throws -> RegistryAckResult {
    try await send(
      RegistryRequest(
        id: 5,
        op: .performAction,
        identifier: identifier,
        action: action
      ),
      toSocketAt: socketPath
    )
  }

  private func send<Result: Decodable & Sendable>(
    _ request: RegistryRequest,
    toSocketAt socketPath: String
  ) async throws -> Result {
    try await Task.detached(priority: .utility) {
      try sendSynchronously(
        request,
        toSocketAt: socketPath
      )
    }.value
  }

  private func sendSynchronously<Result: Decodable & Sendable>(
    _ request: RegistryRequest,
    toSocketAt socketPath: String
  ) throws -> Result {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      throw RegistrySocketClientError.socketFailed(errno: errno)
    }
    defer { Darwin.close(fd) }
    var noSigPipe: Int32 = 1
    _ = Darwin.setsockopt(
      fd,
      SOL_SOCKET,
      SO_NOSIGPIPE,
      &noSigPipe,
      socklen_t(MemoryLayout<Int32>.size)
    )

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
    guard pathBytes.count < maxPathLength else {
      throw RegistrySocketClientError.pathTooLong(socketPath)
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
      throw RegistrySocketClientError.connectFailed(errno: errno)
    }

    var timeoutValue = timeoutValue()
    _ = Darwin.setsockopt(
      fd,
      SOL_SOCKET,
      SO_RCVTIMEO,
      &timeoutValue,
      socklen_t(MemoryLayout<timeval>.size)
    )
    _ = Darwin.setsockopt(
      fd,
      SOL_SOCKET,
      SO_SNDTIMEO,
      &timeoutValue,
      socklen_t(MemoryLayout<timeval>.size)
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var payload = try encoder.encode(request)
    payload.append(0x0A)
    try sendAll(payload, on: fd)
    let responseData = try receiveResponseLine(from: fd)
    return try decodeResponseData(responseData)
  }

  private func sendAll(_ payload: Data, on fd: Int32) throws {
    try payload.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else {
        return
      }
      var bytesSent = 0
      while bytesSent < bytes.count {
        let sent = Darwin.send(
          fd,
          baseAddress.advanced(by: bytesSent),
          bytes.count - bytesSent,
          0
        )
        if sent > 0 {
          bytesSent += sent
          continue
        }
        if sent == 0 {
          throw RegistrySocketClientError.sendFailed(errno: EPIPE)
        }
        if errno == EINTR {
          continue
        }
        throw RegistrySocketClientError.sendFailed(errno: errno)
      }
    }
  }

  private func receiveResponseLine(from fd: Int32) throws -> Data {
    var lineBuffer = NDJSONLineBuffer()
    var scratch = [UInt8](repeating: 0, count: 4 * 1024)
    while true {
      let received = scratch.withUnsafeMutableBufferPointer { buffer in
        Darwin.recv(fd, buffer.baseAddress, buffer.count, 0)
      }
      if received > 0 {
        let chunk = Data(scratch.prefix(received))
        let lines: [Data]
        do {
          lines = try lineBuffer.append(chunk, maxBufferedBytes: RegistryWireCodec.maximumFrameBytes)
        } catch let error as RegistryWireCodecError {
          switch error {
          case .frameTooLarge(let maxBytes):
            throw RegistrySocketClientError.frameTooLarge(maxBytes)
          }
        }
        if let line = lines.first {
          return line
        }
        continue
      }
      if received == 0 {
        if let pendingLine = lineBuffer.drainPendingBytes() {
          return pendingLine
        }
        throw RegistrySocketClientError.recvFailed(errno: ECONNRESET)
      }
      if errno == EINTR {
        continue
      }
      throw RegistrySocketClientError.recvFailed(errno: errno)
    }
  }

  private func decodeResponseData<Result: Decodable>(_ responseData: Data) throws -> Result {
    let decoder = JSONDecoder()
    if let success = try? decoder.decode(SuccessEnvelope<Result>.self, from: responseData),
      success.ok
    {
      return success.result
    }
    if let failure = try? decoder.decode(FailureEnvelope.self, from: responseData),
      failure.ok == false
    {
      throw RegistrySocketClientError.remoteFailure(failure.error)
    }
    throw RegistrySocketClientError.invalidResponse(responseData)
  }

  private func timeoutValue() -> timeval {
    let seconds = max(0, timeout)
    let integralSeconds = Int(seconds.rounded(.down))
    let microseconds = Int32((seconds - TimeInterval(integralSeconds)) * 1_000_000)
    return timeval(tv_sec: integralSeconds, tv_usec: microseconds)
  }
}

private struct SuccessEnvelope<Result: Decodable>: Decodable {
  let id: Int
  let ok: Bool
  let result: Result
}

private struct FailureEnvelope: Decodable {
  let id: Int
  let ok: Bool
  let error: RegistryErrorPayload
}

public enum RegistrySocketClientError: Error, CustomStringConvertible, LocalizedError {
  case socketFailed(errno: Int32)
  case pathTooLong(String)
  case connectFailed(errno: Int32)
  case sendFailed(errno: Int32)
  case recvFailed(errno: Int32)
  case frameTooLarge(Int)
  case remoteFailure(RegistryErrorPayload)
  case invalidResponse(Data)

  public var description: String {
    switch self {
    case .socketFailed(let code):
      "socket() failed: \(String(cString: strerror(code)))"
    case .pathTooLong(let path):
      "unix socket path too long: \(path)"
    case .connectFailed(let code):
      "connect() failed: \(String(cString: strerror(code)))"
    case .sendFailed(let code):
      "send() failed: \(String(cString: strerror(code)))"
    case .recvFailed(let code):
      "recv() failed: \(String(cString: strerror(code)))"
    case .frameTooLarge(let maxBytes):
      "registry frame exceeded the \(maxBytes)-byte limit"
    case .remoteFailure(let error):
      "remote registry failure: \(error.code) \(error.message)"
    case .invalidResponse(let data):
      "received invalid registry response: \(String(decoding: data, as: UTF8.self))"
    }
  }

  public var errorDescription: String? {
    description
  }
}
