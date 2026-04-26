import CryptoKit
import Foundation

public struct SwarmRunLayout {
  public static let agentsE2ETestBundleID = "io.harnessmonitor.agents-e2e-tests"
  public static let runnerContainerEnvironmentKey = "AGENTS_E2E_RUNNER_CONTAINER_ROOT"
  public static let defaultRunnerBundleID = "\(agentsE2ETestBundleID).xctrunner"

  public let runID: String
  public let sessionID: String
  public let repoRoot: URL
  public let appRoot: URL
  public let stateRoot: URL
  public let dataRoot: URL
  public let dataHome: URL
  public let syncRoot: URL
  public let syncDir: URL
  public let logRoot: URL
  public let daemonLog: URL
  public let actDriverLog: URL
  public let derivedDataPath: URL
  public let triageRoot: URL
  public let triageRunSlug: String
  public let artifactsDir: URL
  public let findingsFile: URL
  public let generateLog: URL
  public let buildXcodebuildLog: URL
  public let harnessBuildLog: URL
  public let testXcodebuildLog: URL
  public let screenRecordingPath: URL
  public let screenRecordingLog: URL
  public let screenRecordingControlDirectory: URL
  public let screenRecordingManifestPath: URL
  public let resultBundlePath: URL
  public let uiSnapshotsSource: URL

  public init(
    runID: String,
    repoRoot: URL,
    commonRepoRoot: URL,
    temporaryDirectory: URL,
    homeDirectory: URL,
    sessionID: String? = nil,
    stateRootOverride: URL? = nil,
    dataRootOverride: URL? = nil,
    dataHomeOverride: URL? = nil,
    runnerContainerRootOverride: URL? = nil,
    syncRootOverride: URL? = nil,
    triageRootOverride: URL? = nil,
    timestampSlug: String? = nil
  ) {
    self.runID = runID
    self.sessionID = sessionID ?? "sess-e2e-swarm-\(runID)"
    self.repoRoot = repoRoot
    self.appRoot = repoRoot.appendingPathComponent("apps/harness-monitor-macos", isDirectory: true)

    let stateRoot =
      stateRootOverride
      ?? temporaryDirectory
      .appendingPathComponent("HarnessMonitorSwarmE2E", isDirectory: true)
      .appendingPathComponent(runID, isDirectory: true)
    self.stateRoot = stateRoot
    self.dataRoot =
      dataRootOverride ?? stateRoot.appendingPathComponent("data-root", isDirectory: true)
    self.dataHome =
      dataHomeOverride ?? dataRoot.appendingPathComponent("data-home", isDirectory: true)

    let runnerContainerRoot =
      runnerContainerRootOverride
      ?? syncRootOverride?.deletingLastPathComponent()
      ?? homeDirectory
      .appendingPathComponent(
        "Library/Containers/\(Self.defaultRunnerBundleID)/Data", isDirectory: true)
    self.syncRoot =
      syncRootOverride
      ?? runnerContainerRoot
      .appendingPathComponent("tmp/HarnessMonitorSwarmE2E/\(runID)", isDirectory: true)
    self.syncDir = syncRoot.appendingPathComponent("e2e-sync", isDirectory: true)

    self.logRoot = stateRoot.appendingPathComponent("logs", isDirectory: true)
    self.daemonLog = logRoot.appendingPathComponent("daemon.log")
    self.actDriverLog = logRoot.appendingPathComponent("act-driver.log")
    self.derivedDataPath = commonRepoRoot.appendingPathComponent(
      "xcode-derived-e2e", isDirectory: true)

    self.triageRoot =
      triageRootOverride
      ?? repoRoot.appendingPathComponent("_artifacts", isDirectory: true)
    let slug = (timestampSlug ?? Self.timestampSlugUTC()) + "-swarm-full-flow-\(runID)"
    self.triageRunSlug = slug
    self.artifactsDir = triageRoot.appendingPathComponent("runs/\(slug)", isDirectory: true)
    self.findingsFile = triageRoot.appendingPathComponent("findings/\(slug).md")

    self.generateLog = artifactsDir.appendingPathComponent("generate.log")
    self.buildXcodebuildLog = artifactsDir.appendingPathComponent("build-for-testing.log")
    self.harnessBuildLog = artifactsDir.appendingPathComponent("harness-build.log")
    self.testXcodebuildLog = artifactsDir.appendingPathComponent("test-without-building.log")
    self.screenRecordingPath = artifactsDir.appendingPathComponent("swarm-full-flow.mov")
    self.screenRecordingLog = artifactsDir.appendingPathComponent("screen-recording.log")
    self.screenRecordingControlDirectory = syncRoot.appendingPathComponent(
      "recording-control", isDirectory: true)
    self.screenRecordingManifestPath = stateRoot.appendingPathComponent("screen-recording.json")
    self.resultBundlePath = artifactsDir.appendingPathComponent("swarm-full-flow.xcresult")
    self.uiSnapshotsSource = syncRoot.appendingPathComponent("ui-snapshots", isDirectory: true)
  }

  public static func projectContextRoot(projectDir: URL, dataHome: URL) -> URL {
    let canonicalProjectPath = projectDir.resolvingSymlinksInPath().standardizedFileURL.path
    let digest = SHA256.hash(data: Data(canonicalProjectPath.utf8))
      .compactMap { String(format: "%02x", $0) }
      .joined()
    let prefix = String(digest.prefix(16))
    return
      dataHome
      .appendingPathComponent("harness/projects", isDirectory: true)
      .appendingPathComponent("project-\(prefix)", isDirectory: true)
  }

  public static func timestampUTC(date: Date = Date()) -> String {
    formatter(format: "yyyy-MM-dd'T'HH:mm:ss'Z'").string(from: date)
  }

  public static func timestampSlugUTC(date: Date = Date()) -> String {
    formatter(format: "yyMMddHHmmss").string(from: date)
  }

  private static func formatter(format: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = format
    return formatter
  }
}
