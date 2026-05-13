import Darwin
import Dispatch
import Foundation

struct Connection {
  let id: UInt64
  let fd: Int32
  let readSource: DispatchSourceRead
  let ingress: ConnectionIngress
  let writer: ConnectionWriter
  let closed: ClosedFlag
}

final class ConnectionIngress: @unchecked Sendable {
  enum EnqueueResult {
    case scheduled
    case queued
    case overflow
    case closed
  }

  private var queue: [Data] = []
  private var headIndex = 0
  private var pendingByteCount = 0
  private var draining = false
  private var closed = false
  private let lock = NSLock()

  func enqueue(
    _ lines: [Data],
    maxPendingRequests: Int,
    maxPendingBytes: Int
  ) -> EnqueueResult {
    let additionalBytes = lines.reduce(into: 0) { partialResult, line in
      partialResult += line.count
    }

    lock.lock()
    defer { lock.unlock() }

    guard closed == false else {
      return .closed
    }
    let pendingCount = queue.count - headIndex
    guard pendingCount + lines.count <= maxPendingRequests,
      pendingByteCount + additionalBytes <= maxPendingBytes
    else {
      return .overflow
    }

    queue.append(contentsOf: lines)
    pendingByteCount += additionalBytes
    if draining {
      return .queued
    }
    draining = true
    return .scheduled
  }

  func dequeue() -> Data? {
    lock.lock()
    defer { lock.unlock() }

    guard headIndex < queue.count else {
      queue.removeAll(keepingCapacity: false)
      headIndex = 0
      pendingByteCount = 0
      draining = false
      return nil
    }

    let next = queue[headIndex]
    headIndex += 1
    pendingByteCount -= next.count
    if headIndex >= 16, headIndex * 2 >= queue.count {
      queue.removeFirst(headIndex)
      headIndex = 0
    }
    return next
  }

  func close() {
    lock.lock()
    defer { lock.unlock() }
    closed = true
    queue.removeAll(keepingCapacity: false)
    headIndex = 0
    pendingByteCount = 0
    draining = false
  }
}

final class ConnectionWriter: @unchecked Sendable {
  private struct PendingWrite {
    let payload: Data
    let onDelivered: (@Sendable () async -> Void)?
    let closeAfterDelivery: Bool
  }

  // Keep descriptor teardown here so shutdown runs on one queue/owner. The
  // read source can cancel independently, but it never closes the fd directly.
  private let fd: Int32
  private let maxPendingBytes: Int
  private let closeHandler: @Sendable () -> Void
  private let queue: DispatchQueue
  private let lock = NSLock()
  private var pendingWrites: [PendingWrite] = []
  private var pendingWriteHeadIndex = 0
  private var pendingByteCount = 0
  private var isWriting = false
  private var closed = false
  private var descriptorCloseScheduled = false

  init(
    fd: Int32,
    maxPendingBytes: Int,
    closeHandler: @escaping @Sendable () -> Void
  ) {
    self.fd = fd
    self.maxPendingBytes = maxPendingBytes
    self.closeHandler = closeHandler
    self.queue = DispatchQueue(
      label: "io.harnessmonitor.mcp-registry.writer.\(fd)",
      qos: .utility
    )
  }

  func enqueue(
    _ payload: Data,
    onDelivered: (@Sendable () async -> Void)?,
    closeAfterDelivery: Bool
  ) -> Bool {
    lock.lock()
    defer { lock.unlock() }

    guard closed == false, pendingByteCount + payload.count <= maxPendingBytes else {
      return false
    }

    pendingWrites.append(
      PendingWrite(
        payload: payload,
        onDelivered: onDelivered,
        closeAfterDelivery: closeAfterDelivery
      )
    )
    pendingByteCount += payload.count
    guard isWriting == false else {
      return true
    }
    isWriting = true
    queue.async { [weak self] in
      self?.drainPendingWrites()
    }
    return true
  }

  func close() {
    lock.lock()
    let shouldScheduleDescriptorClose = descriptorCloseScheduled == false
    guard shouldScheduleDescriptorClose else {
      lock.unlock()
      return
    }
    closed = true
    pendingWrites.removeAll(keepingCapacity: false)
    pendingWriteHeadIndex = 0
    pendingByteCount = 0
    descriptorCloseScheduled = true
    lock.unlock()

    _ = Darwin.shutdown(fd, SHUT_RDWR)
    queue.async { [fd] in
      Darwin.close(fd)
    }
  }

  private func drainPendingWrites() {
    while let pendingWrite = dequeuePendingWrite() {
      do {
        try sendAll(pendingWrite.payload)
      } catch {
        closeHandler()
        return
      }

      if let onDelivered = pendingWrite.onDelivered {
        Task {
          await onDelivered()
        }
      }
      if pendingWrite.closeAfterDelivery {
        closeHandler()
        return
      }
    }
  }

  private func dequeuePendingWrite() -> PendingWrite? {
    lock.lock()
    defer { lock.unlock() }

    guard pendingWriteHeadIndex < pendingWrites.count else {
      pendingWrites.removeAll(keepingCapacity: false)
      pendingWriteHeadIndex = 0
      isWriting = false
      return nil
    }

    let pendingWrite = pendingWrites[pendingWriteHeadIndex]
    pendingWriteHeadIndex += 1
    pendingByteCount -= pendingWrite.payload.count
    if pendingWriteHeadIndex >= 16, pendingWriteHeadIndex * 2 >= pendingWrites.count {
      pendingWrites.removeFirst(pendingWriteHeadIndex)
      pendingWriteHeadIndex = 0
    }
    return pendingWrite
  }

  private func sendAll(_ payload: Data) throws {
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
          throw RegistryListenerError.writeFailed(errno: EPIPE)
        }
        if errno == EINTR {
          continue
        }
        if errno == EAGAIN || errno == EWOULDBLOCK {
          guard waitForWritable() else {
            throw RegistryListenerError.writeTimedOut
          }
          continue
        }
        throw RegistryListenerError.writeFailed(errno: errno)
      }
    }
  }

  private func waitForWritable() -> Bool {
    var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    while true {
      let result = Darwin.poll(&pollFD, 1, 1_000)
      if result > 0 {
        return true
      }
      if result == 0 {
        return false
      }
      if errno == EINTR {
        continue
      }
      return false
    }
  }
}

final class BufferBox: @unchecked Sendable {
  private var buffer = NDJSONLineBuffer()
  private let lock = NSLock()

  func append(_ data: Data, maxBufferedBytes: Int) throws -> [Data] {
    lock.lock()
    defer { lock.unlock() }
    return try buffer.append(data, maxBufferedBytes: maxBufferedBytes)
  }
}

final class ClosedFlag: @unchecked Sendable {
  private var closed = false
  private let lock = NSLock()

  var isClosed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return closed
  }

  func mark() {
    lock.lock()
    defer { lock.unlock() }
    closed = true
  }
}

public enum RegistryListenerError: Error, CustomStringConvertible, LocalizedError {
  case socketFailed(errno: Int32)
  case bindFailed(errno: Int32)
  case listenFailed(errno: Int32)
  case writeFailed(errno: Int32)
  case writeTimedOut
  case writeQueueOverflow
  case pathTooLong(String)

  public var description: String {
    switch self {
    case .socketFailed(let code):
      return "socket() failed: \(String(cString: strerror(code)))"
    case .bindFailed(let code):
      return "bind() failed: \(String(cString: strerror(code)))"
    case .listenFailed(let code):
      return "listen() failed: \(String(cString: strerror(code)))"
    case .writeFailed(let code):
      return "send() failed: \(String(cString: strerror(code)))"
    case .writeTimedOut:
      return "send() timed out waiting for the registry peer"
    case .writeQueueOverflow:
      return "registry response queue exceeded the per-connection backpressure limit"
    case .pathTooLong(let path):
      return "unix socket path too long: \(path)"
    }
  }

  public var errorDescription: String? {
    description
  }
}

func ensureSocketPathAvailable(_ path: String, replaceExistingSocketFile: Bool) throws {
  let fileManager = FileManager.default
  let directory = (path as NSString).deletingLastPathComponent
  try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
  if replaceExistingSocketFile, fileManager.fileExists(atPath: path) {
    try fileManager.removeItem(atPath: path)
  }
}

func removeSocketFile(_ path: String) {
  try? FileManager.default.removeItem(atPath: path)
}
