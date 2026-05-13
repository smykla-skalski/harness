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
    logger.info("MCP listener started at \(path, privacy: .public)")
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
