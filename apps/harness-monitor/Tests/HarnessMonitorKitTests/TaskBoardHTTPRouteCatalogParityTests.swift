import Foundation
import Testing

@Suite("Task-board HTTP route catalog parity")
struct TaskBoardHTTPRouteCatalogParityTests {
  @Test("Swift task-board HTTP paths match daemon catalog")
  func swiftTaskBoardHTTPPathsMatchDaemonCatalog() throws {
    let daemonRoutes = try daemonTaskBoardHTTPRoutes()
    let swiftRoutes = try swiftTaskBoardHTTPRoutes()

    #expect(swiftRoutes == daemonRoutes)
  }
}

@Suite("Reviews HTTP route catalog parity")
struct ReviewsHTTPRouteCatalogParityTests {
  @Test("Swift reviews HTTP paths match daemon catalog")
  func swiftReviewsHTTPPathsMatchDaemonCatalog() throws {
    let daemonRoutes = try daemonReviewsHTTPRoutes()
    let swiftRoutes = try swiftReviewsHTTPRoutes()

    #expect(swiftRoutes == daemonRoutes)
  }
}

private struct TaskBoardHTTPRoute: Comparable, CustomStringConvertible, Hashable {
  let method: String
  let path: String

  var description: String { "\(method) \(path)" }

  static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.path == rhs.path {
      return lhs.method < rhs.method
    }
    return lhs.path < rhs.path
  }
}

private enum TaskBoardHTTPRouteCatalogError: Error, CustomStringConvertible {
  case missingCapture(pattern: String)
  case missingPathConstant(String)
  case noRoutes(relativePath: String)

  var description: String {
    switch self {
    case .missingCapture(let pattern):
      return "Missing route catalog capture for pattern \(pattern)"
    case .missingPathConstant(let constant):
      return "Missing HTTP path constant \(constant)"
    case .noRoutes(let relativePath):
      return "No HTTP routes found in \(relativePath)"
    }
  }
}

private func daemonTaskBoardHTTPRoutes() throws -> [TaskBoardHTTPRoute] {
  let relativePath = "src/daemon/protocol/api_contract/routes_task_board.rs"
  let source = try repoFileContents(relativePath: relativePath)
  let pathConstants = try daemonHTTPPathConstants()
  let blocks = source.components(separatedBy: "HttpApiRouteContract {").dropFirst()
  var routes: [TaskBoardHTTPRoute] = []

  for block in blocks where block.contains("swift_client_exposed: true") {
    let method = try firstCapture(in: block, pattern: "method:\\s*HttpRouteMethod::([A-Za-z]+)")
    let pathConstant = try firstCapture(in: block, pattern: "path:\\s*http_paths::([A-Z0-9_]+)")
    guard let path = pathConstants[pathConstant] else {
      throw TaskBoardHTTPRouteCatalogError.missingPathConstant(pathConstant)
    }
    guard path.hasPrefix("/v1/task-board/") else {
      continue
    }
    routes.append(TaskBoardHTTPRoute(method: method.uppercased(), path: path))
  }

  guard routes.isEmpty == false else {
    throw TaskBoardHTTPRouteCatalogError.noRoutes(relativePath: relativePath)
  }
  return routes.sorted()
}

private func daemonHTTPPathConstants() throws -> [String: String] {
  let source = try repoFileContents(relativePath: "src/daemon/protocol/api_contract/http_paths.rs")
  let matches = try captures(
    in: source,
    pattern: "pub const\\s+([A-Z0-9_]+):\\s*&str\\s*=\\s*\"([^\"]+)\";"
  )
  return Dictionary(uniqueKeysWithValues: matches.map { ($0[0], $0[1]) })
}

private func swiftTaskBoardHTTPRoutes() throws -> [TaskBoardHTTPRoute] {
  let relativePaths = [
    "apps/harness-monitor/Sources/HarnessMonitorKit/API/HarnessMonitorAPIClient+TaskBoard.swift",
  ]
  let routes = try relativePaths.flatMap { relativePath in
    let source = try repoFileContents(relativePath: relativePath)
    return try captures(
      in: source,
      pattern: "\\b(get|post|put|delete)\\s*\\(\\s*\"([^\"]+)\""
    ).compactMap { capture -> TaskBoardHTTPRoute? in
      let path = normalizedSwiftHTTPPath(capture[1])
      guard path.hasPrefix("/v1/task-board/") else {
        return nil
      }
      return TaskBoardHTTPRoute(
        method: capture[0].uppercased(),
        path: path
      )
    }
  }

  guard routes.isEmpty == false else {
    throw TaskBoardHTTPRouteCatalogError.noRoutes(
      relativePath: relativePaths.joined(separator: ", ")
    )
  }
  return routes.sorted()
}

private func daemonReviewsHTTPRoutes() throws -> [TaskBoardHTTPRoute] {
  let relativePath = "src/daemon/protocol/api_contract/routes_reviews.rs"
  let source = try repoFileContents(relativePath: relativePath)
  let pathConstants = try daemonHTTPPathConstants()
  let blocks = source.components(separatedBy: "HttpApiRouteContract {").dropFirst()
  var routes: [TaskBoardHTTPRoute] = []

  for block in blocks where block.contains("swift_client_exposed: true") {
    let method = try firstCapture(in: block, pattern: "method:\\s*HttpRouteMethod::([A-Za-z]+)")
    let pathConstant = try firstCapture(in: block, pattern: "path:\\s*http_paths::([A-Z0-9_]+)")
    guard let path = pathConstants[pathConstant] else {
      throw TaskBoardHTTPRouteCatalogError.missingPathConstant(pathConstant)
    }
    routes.append(TaskBoardHTTPRoute(method: method.uppercased(), path: path))
  }

  guard routes.isEmpty == false else {
    throw TaskBoardHTTPRouteCatalogError.noRoutes(relativePath: relativePath)
  }
  return routes.sorted()
}

private func swiftReviewsHTTPRoutes() throws -> [TaskBoardHTTPRoute] {
  let relativePath =
    "apps/harness-monitor/Sources/HarnessMonitorKit/API/HarnessMonitorAPIClient+Reviews.swift"
  let source = try repoFileContents(relativePath: relativePath)
  let matches = try captures(
    in: source,
    pattern: "\\b(get|post|put|delete)\\s*\\(\\s*\"([^\"]+)\""
  )
  let routes = matches.compactMap { capture -> TaskBoardHTTPRoute? in
    let path = normalizedSwiftHTTPPath(capture[1])
    guard path.hasPrefix("/v1/reviews/") else {
      return nil
    }
    return TaskBoardHTTPRoute(method: capture[0].uppercased(), path: path)
  }

  guard routes.isEmpty == false else {
    throw TaskBoardHTTPRouteCatalogError.noRoutes(relativePath: relativePath)
  }
  return routes.sorted()
}

private func normalizedSwiftHTTPPath(_ path: String) -> String {
  path.replacingOccurrences(of: "\\(id)", with: "{item_id}")
}

private func repoFileContents(relativePath: String) throws -> String {
  let file = try repoFileURL(relativePath: relativePath)
  return try String(contentsOf: file, encoding: .utf8)
}

private func repoFileURL(relativePath: String) throws -> URL {
  let env = ProcessInfo.processInfo.environment
  let candidateRoots = [
    env["HARNESS_MONITOR_REPO_ROOT"].map(URL.init(fileURLWithPath:)),
    env["HARNESS_MONITOR_APP_ROOT"].map(URL.init(fileURLWithPath:)),
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    repoRoot(filePath: #filePath),
  ].compactMap { $0 }
  if let existing = candidateRoots.compactMap({
    existingFilePath(relativePath: relativePath, startingAt: $0)
  }).first {
    return existing
  }
  throw CocoaError(.fileNoSuchFile)
}

private func existingFilePath(relativePath: String, startingAt seed: URL) -> URL? {
  var current = seed
  while true {
    let candidate = current.appendingPathComponent(relativePath)
    if FileManager.default.fileExists(atPath: candidate.path) {
      return candidate
    }
    let parent = current.deletingLastPathComponent()
    guard parent.path != current.path else {
      return nil
    }
    current = parent
  }
}

private func firstCapture(in source: String, pattern: String) throws -> String {
  guard let capture = try captures(in: source, pattern: pattern).first?.first else {
    throw TaskBoardHTTPRouteCatalogError.missingCapture(pattern: pattern)
  }
  return capture
}

private func captures(in source: String, pattern: String) throws -> [[String]] {
  let regex = try NSRegularExpression(
    pattern: pattern,
    options: [.dotMatchesLineSeparators]
  )
  let range = NSRange(source.startIndex..<source.endIndex, in: source)
  return regex.matches(in: source, range: range).map { match in
    (1..<match.numberOfRanges).compactMap { index in
      guard let captureRange = Range(match.range(at: index), in: source) else {
        return nil
      }
      return String(source[captureRange])
    }
  }
}
