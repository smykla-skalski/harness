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
  private var acceptSource: DispatchSourceRead?
  private var connections: [Int32: DispatchIO] = [:]
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
      throw RegistryListenerError.listenFailed(errno: err)
    }

    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in
      self?.queueBackedAccept(on: fd)
    }
    source.resume()

    socketFD = fd
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
    for (fd, io) in connections {
      io.close()
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
    let io = DispatchIO(
      type: .stream,
      fileDescriptor: fd,
      queue: queue,
      cleanupHandler: { _ in Darwin.close(fd) }
    )
    io.setLimit(lowWater: 1)
    connections[fd] = io
    pump(fd: fd, io: io)
  }

  private func pump(fd: Int32, io: DispatchIO) {
    var buffer = NDJSONLineBuffer()
    io.read(offset: 0, length: .max, queue: queue) { [weak self] isDone, data, _ in
      guard let self else { return }
      if let data, data.isEmpty == false {
        let rawData = Data(copying: data)
        let lines = buffer.append(rawData)
        for line in lines {
          Task { await self.handleLine(line, fd: fd) }
        }
      }
      if isDone {
        Task { await self.closeConnection(fd: fd) }
      }
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
      guard let io = connections[fd] else { return }
      let chunk = payload.withUnsafeBytes { bytes -> DispatchData in
        DispatchData(bytes: bytes)
      }
      io.write(offset: 0, data: chunk, queue: queue) { _, _, _ in }
    } catch {
      logger.error(
        "harness-monitor MCP failed to encode response: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func closeConnection(fd: Int32) {
    guard let io = connections.removeValue(forKey: fd) else { return }
    io.close()
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

private extension Data {
  init(copying dispatchData: DispatchData) {
    var copy = Data(count: dispatchData.count)
    copy.withUnsafeMutableBytes { destination in
      _ = dispatchData.copyBytes(to: destination)
    }
    self = copy
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
