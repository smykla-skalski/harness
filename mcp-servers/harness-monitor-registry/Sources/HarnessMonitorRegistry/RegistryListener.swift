import Darwin
import Dispatch
import Foundation
import OSLog

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
  private var connections: [Int32: Connection] = [:]
  private var running = false

  public init(
    dispatcher: RegistryRequestDispatcher,
    logger: Logger = Logger(subsystem: "io.harnessmonitor", category: "mcp-registry")
  ) {
    self.dispatcher = dispatcher
    self.logger = logger
    self.queue = DispatchQueue(label: "io.harnessmonitor.mcp-registry.listener", qos: .utility)
  }

  public func start(at path: String) throws {
    guard running == false else { return }
    try ensureSocketPathAvailable(path)

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
    for (fd, connection) in connections {
      connection.readSource.cancel()
      connection.writeQueue.cancel()
      Darwin.close(fd)
    }
    connections.removeAll()
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
    _ = Darwin.fcntl(fd, F_SETFL, Darwin.fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
    let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    let writeQueue = DispatchSource.makeUserDataAddSource(queue: queue)
    writeQueue.resume()
    let buffer = BufferBox()
    let closed = ClosedFlag()
    readSource.setEventHandler { [weak self] in
      self?.handleReadable(fd: fd, buffer: buffer, closed: closed)
    }
    readSource.setCancelHandler {
      Darwin.close(fd)
    }
    connections[fd] = Connection(readSource: readSource, writeQueue: writeQueue)
    readSource.resume()
  }

  private nonisolated func handleReadable(fd: Int32, buffer: BufferBox, closed: ClosedFlag) {
    if closed.isClosed { return }
    var scratch = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      let bytesRead = scratch.withUnsafeMutableBufferPointer { pointer in
        Darwin.recv(fd, pointer.baseAddress, pointer.count, 0)
      }
      if bytesRead > 0 {
        let chunk = Data(scratch.prefix(bytesRead))
        let lines = buffer.append(chunk)
        for line in lines {
          Task { await self.handleLine(line, fd: fd) }
        }
        continue
      }
      if bytesRead == 0 {
        closed.mark()
        Task { await self.closeConnection(fd: fd) }
        return
      }
      if errno == EAGAIN || errno == EWOULDBLOCK {
        return
      }
      closed.mark()
      Task { await self.closeConnection(fd: fd) }
      return
    }
  }

  private func handleLine(_ line: Data, fd: Int32) async {
    let response: RegistryResponse
    do {
      let request = try RegistryWireCodec.decodeRequest(line)
      response = await dispatcher.dispatch(request)
    } catch {
      response = .failure(
        id: -1,
        error: RegistryErrorPayload(code: "invalid-json", message: error.localizedDescription)
      )
    }
    do {
      var payload = try RegistryWireCodec.encodeResponse(response)
      payload.append(0x0A)
      guard connections[fd] != nil else { return }
      _ = payload.withUnsafeBytes { bytes -> Int in
        guard let base = bytes.baseAddress else { return 0 }
        return Darwin.send(fd, base, bytes.count, 0)
      }
    } catch {
      logger.error(
        "harness-monitor MCP failed to encode response: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func closeConnection(fd: Int32) {
    guard let connection = connections.removeValue(forKey: fd) else { return }
    connection.writeQueue.cancel()
    connection.readSource.cancel()
  }
}

private struct Connection {
  let readSource: DispatchSourceRead
  let writeQueue: DispatchSourceUserDataAdd
}

private final class BufferBox: @unchecked Sendable {
  private var buffer = NDJSONLineBuffer()
  private let lock = NSLock()

  func append(_ data: Data) -> [Data] {
    lock.lock()
    defer { lock.unlock() }
    return buffer.append(data)
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

public enum RegistryListenerError: Error, CustomStringConvertible {
  case socketFailed(errno: Int32)
  case bindFailed(errno: Int32)
  case listenFailed(errno: Int32)
  case pathTooLong(String)

  public var description: String {
    switch self {
    case .socketFailed(let code):
      return "socket() failed: \(String(cString: strerror(code)))"
    case .bindFailed(let code):
      return "bind() failed: \(String(cString: strerror(code)))"
    case .listenFailed(let code):
      return "listen() failed: \(String(cString: strerror(code)))"
    case .pathTooLong(let path):
      return "unix socket path too long: \(path)"
    }
  }
}

private func ensureSocketPathAvailable(_ path: String) throws {
  let fileManager = FileManager.default
  let directory = (path as NSString).deletingLastPathComponent
  var isDirectory: ObjCBool = false
  if fileManager.fileExists(atPath: directory, isDirectory: &isDirectory) == false {
    try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
  }
  if fileManager.fileExists(atPath: path) {
    try fileManager.removeItem(atPath: path)
  }
}

private func removeSocketFile(_ path: String) {
  try? FileManager.default.removeItem(atPath: path)
}
