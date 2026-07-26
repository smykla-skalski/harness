import Darwin
import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor store observation lifetime")
struct HarnessMonitorStoreObservationLifetimeTests {
  /// `start()` opens the daemon directory and resumes a dispatch source that
  /// libdispatch then owns. Dropping the watcher releases the last thing that
  /// could ever cancel that source, so it goes on watching, and goes on holding
  /// its descriptor, until the process exits.
  @Test("Dropped manifest watchers do not strand their descriptors")
  func droppedManifestWatchersDoNotStrandTheirDescriptors() async throws {
    let directory = try makeWatchableDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let manifestURL = directory.appendingPathComponent("manifest.json")

    let baseline = try openDescriptorCount()
    for _ in 0..<watchersPerRun {
      let watcher = ManifestWatcher(manifestURL: manifestURL, currentEndpoint: "") { _ in }
      watcher.start()
    }
    try await settleCancellations()

    let stranded = try openDescriptorCount() - baseline
    #expect(stranded < descriptorDriftAllowance)
  }

  /// A store that cannot reach a daemon still watches the daemon directory,
  /// waiting for one to turn up, and that is the path a test run walks most: no
  /// daemon is listening, so store after store ends here and walks away. Every
  /// one of them leaves a live source on a directory the run never meant to
  /// touch in the first place.
  @Test("A store nobody holds any more leaves no watcher behind")
  func aStoreNobodyHoldsAnyMoreLeavesNoWatcherBehind() async throws {
    let directory = try makeWatchableDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let manifestURL = directory.appendingPathComponent("manifest.json")

    let baseline = try openDescriptorCount()
    for _ in 0..<storesPerRun {
      let store = HarnessMonitorStore(
        daemonController: RecordingDaemonController(warmUpError: DaemonUnreachable()),
        daemonOwnership: .external
      )
      store.manifestURL = manifestURL
      await store.bootstrap()
      // The watcher installs on its own task, so a store dropped before that
      // task lands would prove nothing.
      try await waitForWatchingStore(store)
    }
    try await settleCancellations()

    let stranded = try openDescriptorCount() - baseline
    #expect(stranded < descriptorDriftAllowance)
  }

  /// The stream loops re-bootstrap the connection for as long as they run, and
  /// the recovery they schedule starts them again, so between them they never
  /// end. Holding the store while they wait therefore keeps it working forever,
  /// on the main actor every other test in the run is queued behind.
  @Test("A store nobody holds any more is released")
  func aStoreNobodyHoldsAnyMoreIsReleased() async throws {
    weak var dropped: HarnessMonitorStore?
    do {
      let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
      await store.bootstrap()
      try #require(store.connectionState == .online)
      // The loops start on their own tasks, so a store dropped before they run
      // would be released whether or not they let go of it.
      try await Task.sleep(for: .milliseconds(250))
      dropped = store
    }

    var remainingChecks = 60
    while dropped != nil, remainingChecks > 0 {
      remainingChecks -= 1
      try await Task.sleep(for: .milliseconds(50))
    }

    #expect(dropped == nil)
  }

  private struct DaemonUnreachable: Error {}

  private var watchersPerRun: Int { 200 }
  private var storesPerRun: Int { 50 }

  /// The rest of the process opens and closes descriptors while this runs, so
  /// allow for drift and fail only on the ones a run of this size strands.
  private var descriptorDriftAllowance: Int { 40 }

  /// Cancellation runs on the source's own queue, so a count taken on the way
  /// out of the loop would read descriptors that are already on their way back.
  private func settleCancellations() async throws {
    try await Task.sleep(for: .milliseconds(500))
  }

  private func waitForWatchingStore(_ store: HarnessMonitorStore) async throws {
    var remainingChecks = 100
    while store.manifestWatcher?.isWatching != true, remainingChecks > 0 {
      remainingChecks -= 1
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(store.manifestWatcher?.isWatching == true)
  }

  private func makeWatchableDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("manifest-watcher-lifetime-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// How many descriptors this process holds. Probing with `open` instead would
  /// report the lowest free slot, which a busy run keeps refilling underneath
  /// the leak and so reads clean while descriptors pile up above it.
  private func openDescriptorCount() throws -> Int {
    let sizingResult = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
    try #require(sizingResult > 0)
    var entries = [proc_fdinfo](
      repeating: proc_fdinfo(),
      count: Int(sizingResult) / MemoryLayout<proc_fdinfo>.stride
    )
    let listedBytes = entries.withUnsafeMutableBufferPointer { buffer in
      proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, buffer.baseAddress, sizingResult)
    }
    try #require(listedBytes > 0)
    return Int(listedBytes) / MemoryLayout<proc_fdinfo>.stride
  }
}
