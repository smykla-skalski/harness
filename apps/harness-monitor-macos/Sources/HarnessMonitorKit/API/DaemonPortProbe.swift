import Darwin
import Foundation

// Silent TCP reachability probe used during daemon warm-up.
//
// URLSession routes through Network.framework, which emits a cascade of
// `nw_connection_*` and `nw_socket_handle_socket_event` diagnostics every time
// a loopback connect is refused. Warm-up loops retry roughly every 250 ms, so
// each stale-manifest window floods the unified log with tens of lines. A raw
// BSD socket connect bypasses Network.framework entirely and fails in silence.
enum DaemonPortProbe {
  static func isListening(
    host: String,
    port: UInt16,
    timeout: Duration
  ) -> Bool {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }

    let currentFlags = fcntl(descriptor, F_GETFL, 0)
    guard currentFlags >= 0,
      fcntl(descriptor, F_SETFL, currentFlags | O_NONBLOCK) >= 0
    else {
      return false
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
      return false
    }

    let connectResult = withUnsafePointer(to: &address) { addressPointer in
      addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { genericPointer in
        Darwin.connect(
          descriptor,
          genericPointer,
          socklen_t(MemoryLayout<sockaddr_in>.size)
        )
      }
    }

    if connectResult == 0 {
      return true
    }
    guard errno == EINPROGRESS else {
      return false
    }

    var entry = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
    let timeoutMilliseconds = Int32(clamping: timeout.totalMilliseconds)
    let polled = poll(&entry, 1, timeoutMilliseconds)
    guard polled > 0, entry.revents & Int16(POLLOUT) != 0 else {
      return false
    }

    var socketError: Int32 = 0
    var errorLength = socklen_t(MemoryLayout<Int32>.size)
    guard
      getsockopt(
        descriptor,
        SOL_SOCKET,
        SO_ERROR,
        &socketError,
        &errorLength
      ) == 0
    else {
      return false
    }
    return socketError == 0
  }
}

extension Duration {
  fileprivate var totalMilliseconds: Int64 {
    let (seconds, attoseconds) = components
    return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
  }
}
