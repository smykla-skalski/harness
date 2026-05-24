import Darwin
import Foundation
import HarnessMonitorRegistry

enum HarnessMonitorMCPRegistryTokenStore {
  static let tokenByteCount = 32

  static func tokenURL(for socketURL: URL) -> URL {
    socketURL.deletingLastPathComponent().appendingPathComponent(
      registryTokenFilename,
      isDirectory: false
    )
  }

  static func loadOrCreateToken(for socketURL: URL) throws -> String {
    let tokenURL = tokenURL(for: socketURL)
    if let existingToken = try readExistingToken(at: tokenURL) {
      try hardenPermissions(at: tokenURL)
      return existingToken
    }

    try FileManager.default.createDirectory(
      at: tokenURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let token = makeToken()
    let data = Data((token + "\n").utf8)
    guard
      FileManager.default.createFile(
        atPath: tokenURL.path,
        contents: data,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
      )
    else {
      throw HarnessMonitorMCPRegistryTokenStoreError.createFailed(tokenURL)
    }
    try hardenPermissions(at: tokenURL)
    return token
  }

  private static func readExistingToken(at url: URL) throws -> String? {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    let raw = try String(contentsOf: url, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard raw.isEmpty == false else {
      return nil
    }
    return raw
  }

  private static func hardenPermissions(at url: URL) throws {
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o600))],
      ofItemAtPath: url.path
    )
  }

  private static func makeToken() -> String {
    var bytes = [UInt8](repeating: 0, count: tokenByteCount)
    arc4random_buf(&bytes, bytes.count)
    return bytes.map { String(format: "%02x", $0) }.joined()
  }
}

enum HarnessMonitorMCPRegistryTokenStoreError: LocalizedError {
  case createFailed(URL)

  var errorDescription: String? {
    switch self {
    case .createFailed(let url):
      "failed to create MCP registry token at \(url.path)"
    }
  }
}
