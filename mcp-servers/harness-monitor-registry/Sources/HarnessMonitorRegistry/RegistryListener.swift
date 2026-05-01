import Darwin
import Dispatch
import Foundation
import OSLog

private let maxPendingRequestsPerConnection = 32
private let maxPendingRequestBytesPerConnection = registryMaximumFrameBytes * 2
private let maxPendingResponseBytesPerConnection = registryMaximumFrameBytes * 2

/// NDJSON-over-Unix-domain-socket server that exposes the registry to the MCP server.
///
/// Uses POSIX sockets for reliable Unix-socket binding. `NWListener` does not expose a
/// stable filesystem-socket listen path, so we handle accept() ourselves on a serial
/// dispatch queue and hand each connection off to DispatchIO for non-blocking reads.
public actor RegistryListener {
  private let dispatcher: RegistryRequestDispatcher
  private let logger: Logger
  private let queue: DispatchQueue
  private var socketFD: Int32 = -1
  private var socketPath: String?
  private var acceptSource: DispatchSourceRead?
  private var nextConnectionID: UInt64 = 0
  private var connections: [UInt64: Connection] = [:]
  private var running = false

  public init(
    dispatcher: RegistryRequestDispatcher,
    logger: Logger = Logger(subsystem: "io.harnessmonitor", category: "mcp-registry")
  ) {
    self.dispatcher = dispatcher
    self.logger = logger
    self.queue = DispatchQueue(label: "io.harnessmonitor.mcp-registry.listener", qos: .utility)
  }

  public func start(at path: String, replaceExistingSocketFile: Bool = true) throws {
    guard running == false else { return }
    try ensureSocketPathAvailable(path, replaceExistingSocketFile: replaceExistingSocketFile)

    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      throw RegistryListenerError.socketFailed(errno: errno)
    }
    var flag: Int32 = 1
    _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &flag, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < maxPathLength else {
      Darwin.close(fd)
      throw RegistryListenerError.pathTooLong(path)
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { pointer in
      pointer.baseAddress?.copyMemory(from: pathBytes, byteCount: pathBytes.count)
    }

    let bindResult = withUnsafePointer(to: &addr) { addrPointer -> Int32 in
      addrPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if bindResult != 0 {
      let err = errno
      Darwin.close(fd)
      throw RegistryListenerError.bindFailed(errno: err)
    }
    if Darwin.listen(fd, 16) != 0 {
      let err = errno
      Darwin.close(fd)
      removeSocketFile(path)
      throw RegistryListenerError.listenFailed(errno: err)
    }

    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in
      self?.queueBackedAccept(on: fd)
    }
    source.resume()

    socketFD = fd
    socketPath = path
    acceptSource = source
    running = true
    logger.info("harness-monitor MCP listener started at \(path, privacy: .public)")
  }

  public func stop() {
    guard running else { return }
    running = false
    acceptSource?.cancel()
    acceptSource = nil
    if socketFD >= 0 {
      Darwin.close(socketFD)
      socketFD = -1
    }
    if let path = socketPath {
      removeSocketFile(path)
      socketPath = nil
    }
    let connectionIDs = Array(connections.keys)
    for connectionID in connectionIDs {
      closeConnection(id: connectionID)
    }
  }

  private nonisolated func queueBackedAccept(on serverFD: Int32) {
    var peer = sockaddr()
    var peerLen = socklen_t(MemoryLayout<sockaddr>.size)
    let clientFD = Darwin.accept(serverFD, &peer, &peerLen)
    if clientFD < 0 { return }
    var flag: Int32 = 1
    _ = Darwin.setsockopt(
      clientFD, SOL_SOCKET, SO_NOSIGPIPE, &flag, socklen_t(MemoryLayout<Int32>.size)
    )
    Task { await self.attachConnection(fd: clientFD) }
  }

  private func attachConnection(fd: Int32) {
    nextConnectionID &+= 1
    let connectionID = nextConnectionID
    _ = Darwin.fcntl(fd, F_SETFL, Darwin.fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
    let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    let buffer = BufferBox()
    let closed = ClosedFlag()
    let ingress = ConnectionIngress()
    let writer = ConnectionWriter(
      fd: fd,
      maxPendingBytes: maxPendingResponseBytesPerConnection,
      closeHandler: { [weak self] in
        Task { await self?.closeConnection(id: connectionID) }
      }
    )
    readSource.setEventHandler { [weak self] in
      self?.handleReadable(
        id: connectionID,
        fd: fd,
        buffer: buffer,
        closed: closed,
        ingress: ingress
      )
    }
    readSource.setCancelHandler {
      closed.mark()
      writer.close()
    }
    connections[connectionID] = Connection(
      id: connectionID,
      fd: fd,
      readSource: readSource,
      ingress: ingress,
      writer: writer,
      closed: closed
    )
    readSource.resume()
  }

  private nonisolated func handleReadable(
    id: UInt64,
    fd: Int32,
    buffer: BufferBox,
    closed: ClosedFlag,
    ingress: ConnectionIngress
  ) {
    if closed.isClosed {
      drainReadable(fd: fd)
      return
    }
    var scratch = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      let bytesRead = scratch.withUnsafeMutableBufferPointer { pointer in
        Darwin.recv(fd, pointer.baseAddress, pointer.count, 0)
      }
      if bytesRead > 0 {
        let chunk = Data(scratch.prefix(bytesRead))
        let lines: [Data]
        do {
          lines = try buffer.append(chunk, maxBufferedBytes: RegistryWireCodec.maximumFrameBytes)
        } catch {
          closed.mark()
          Task {
            await self.logAndCloseConnection(
              id: id,
              fd: fd,
              reason: "registry request frame exceeded the size limit"
            )
          }
          return
        }
        if lines.isEmpty == false {
          switch ingress.enqueue(
            lines,
            maxPendingRequests: maxPendingRequestsPerConnection,
            maxPendingBytes: maxPendingRequestBytesPerConnection
          ) {
          case .overflow:
            closed.mark()
            Task {
              await self.logAndCloseConnection(
                id: id,
                fd: fd,
                reason: "registry request queue exceeded the per-connection backpressure limit"
              )
            }
            return
          case .closed:
            closed.mark()
            return
          case .queued:
            break
          case .scheduled:
            Task { await self.processPendingRequests(for: id) }
          }
        }
        continue
      }
      if bytesRead == 0 {
        closed.mark()
        Task { await self.closeConnection(id: id) }
        return
      }
      if errno == EAGAIN || errno == EWOULDBLOCK {
        return
      }
      closed.mark()
      Task { await self.closeConnection(id: id) }
      return
    }
  }

  private nonisolated func drainReadable(fd: Int32) {
    var scratch = [UInt8](repeating: 0, count: 4 * 1024)
    while true {
      let bytesRead = scratch.withUnsafeMutableBufferPointer { pointer in
        Darwin.recv(fd, pointer.baseAddress, pointer.count, 0)
      }
      if bytesRead > 0 {
        continue
      }
      if bytesRead == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
        return
      }
      if errno == EINTR {
        continue
      }
      return
    }
  }

  private func processPendingRequests(for id: UInt64) async {
    while let (line, fd) = dequeueNextRequest(for: id) {
      let shouldStop = await handleLine(line, connectionID: id, fd: fd)
      if shouldStop {
        return
      }
    }
  }

  private func dequeueNextRequest(for id: UInt64) -> (line: Data, fd: Int32)? {
    guard let connection = connections[id], let line = connection.ingress.dequeue() else {
      return nil
    }
    return (line, connection.fd)
  }

  private func handleLine(_ line: Data, connectionID: UInt64, fd: Int32) async -> Bool {
    let onDelivered: (@Sendable () async -> Void)?
    let response: RegistryResponse
    let closeAfterDelivery: Bool
    do {
      let decodedRequest = try RegistryWireCodec.decodeRequest(line)
      let dispatchResult = await dispatcher.dispatch(decodedRequest)
      response = dispatchResult.response
      onDelivered = dispatchResult.onDelivered
      closeAfterDelivery = dispatchResult.closeConnectionAfterDelivery
    } catch let error as RegistryWireCodecError {
      onDelivered = nil
      closeAfterDelivery = false
      response = .failure(
        id: -1,
        error: RegistryErrorPayload(code: "invalid-argument", message: error.description)
      )
    } catch {
      onDelivered = nil
      closeAfterDelivery = false
      response = .failure(
        id: -1,
        error: RegistryErrorPayload(code: "invalid-json", message: error.localizedDescription)
      )
    }

    do {
      try await sendResponse(
        response,
        onDelivered: onDelivered,
        closeAfterDelivery: closeAfterDelivery,
        on: connectionID
      )
      if closeAfterDelivery {
        sealConnection(id: connectionID)
        return true
      }
    } catch {
      logAndCloseConnection(id: connectionID, fd: fd, reason: error.localizedDescription)
    }
    return false
  }

  private func sendResponse(
    _ response: RegistryResponse,
    onDelivered: (@Sendable () async -> Void)?,
    closeAfterDelivery: Bool,
    on connectionID: UInt64
  ) async throws {
    var payload = try RegistryWireCodec.encodeResponse(response)
    payload.append(0x0A)
    guard let connection = connections[connectionID] else {
      return
    }
    guard connection.writer.enqueue(
      payload,
      onDelivered: onDelivered,
      closeAfterDelivery: closeAfterDelivery
    ) else {
      throw RegistryListenerError.writeQueueOverflow
    }
  }

  private func sealConnection(id: UInt64) {
    guard let connection = connections[id] else {
      return
    }
    connection.closed.mark()
    connection.ingress.close()
  }

  private func logAndCloseConnection(id: UInt64, fd: Int32, reason: String) {
    logger.error(
      "harness-monitor MCP closing connection \(fd, privacy: .public): \(reason, privacy: .public)"
    )
    closeConnection(id: id)
  }

  private func closeConnection(id: UInt64) {
    guard let connection = connections.removeValue(forKey: id) else { return }
    connection.closed.mark()
    connection.ingress.close()
    connection.readSource.cancel()
    connection.writer.close()
  }
}

private struct Connection {
  let id: UInt64
  let fd: Int32
  let readSource: DispatchSourceRead
  let ingress: ConnectionIngress
  let writer: ConnectionWriter
  let closed: ClosedFlag
}

private final class ConnectionIngress: @unchecked Sendable {
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

private final class ConnectionWriter: @unchecked Sendable {
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

private final class BufferBox: @unchecked Sendable {
  private var buffer = NDJSONLineBuffer()
  private let lock = NSLock()

  func append(_ data: Data, maxBufferedBytes: Int) throws -> [Data] {
    lock.lock()
    defer { lock.unlock() }
    return try buffer.append(data, maxBufferedBytes: maxBufferedBytes)
  }
}

private final class ClosedFlag: @unchecked Sendable {
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

private func ensureSocketPathAvailable(_ path: String, replaceExistingSocketFile: Bool) throws {
  let fileManager = FileManager.default
  let directory = (path as NSString).deletingLastPathComponent
  var isDirectory: ObjCBool = false
  if fileManager.fileExists(atPath: directory, isDirectory: &isDirectory) == false {
    try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
  }
  if replaceExistingSocketFile, fileManager.fileExists(atPath: path) {
    try fileManager.removeItem(atPath: path)
  }
}

private func removeSocketFile(_ path: String) {
  try? FileManager.default.removeItem(atPath: path)
}
