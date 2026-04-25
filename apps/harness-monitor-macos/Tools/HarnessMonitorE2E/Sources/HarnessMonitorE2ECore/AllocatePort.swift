import Darwin
import Foundation

public enum PortAllocator {
  public enum Failure: Error, CustomStringConvertible {
    case socketCreate(errno: Int32)
    case bindFailed(errno: Int32)
    case getsockname(errno: Int32)

    public var description: String {
      switch self {
      case .socketCreate(let code):
        return "socket() failed: errno=\(code) \(String(cString: strerror(code)))"
      case .bindFailed(let code):
        return "bind() failed: errno=\(code) \(String(cString: strerror(code)))"
      case .getsockname(let code):
        return "getsockname() failed: errno=\(code) \(String(cString: strerror(code)))"
      }
    }
  }

  /// Bind a TCP socket to 127.0.0.1:0, read the assigned port, close the socket.
  /// Same approach the python block used; the kernel keeps the port in TIME_WAIT-free state long enough for the caller to reuse it.
  public static func allocateLocalTCPPort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw Failure.socketCreate(errno: errno) }
    defer { close(fd) }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

    let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else { throw Failure.bindFailed(errno: errno) }

    var bound = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &bound) { ptr -> Int32 in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        getsockname(fd, sockPtr, &len)
      }
    }
    guard nameResult == 0 else { throw Failure.getsockname(errno: errno) }

    return UInt16(bigEndian: bound.sin_port)
  }
}
