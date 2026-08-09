import Darwin
import Foundation

private enum ManagedDaemonQuiescenceAction {
  case finish
  case wait
  case requestStop
}

private struct ManagedDaemonQuiescenceResult: Sendable {
  let rootURL: URL
  let stoppedPID: Int32?
  let failure: String?
}

private enum ManagedDaemonControlOutcome: Sendable {
  case stopped
  case failed(String)
  case timedOut
  case cancelled
}

private actor ManagedDaemonControlGate {
  private var outcome: ManagedDaemonControlOutcome?
  private var waiters: [CheckedContinuation<ManagedDaemonControlOutcome, Never>] = []

  func wait() async -> ManagedDaemonControlOutcome {
    if let outcome {
      return outcome
    }
    return await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func finish(_ outcome: ManagedDaemonControlOutcome) {
    guard self.outcome == nil else {
      return
    }
    self.outcome = outcome
    let waiters = waiters
    self.waiters.removeAll()
    for waiter in waiters {
      waiter.resume(returning: outcome)
    }
  }
}

extension DaemonController {
  func quiesceManagedDaemonsAfterLegacyCleanupFailure() async throws {
    let deadline = ContinuousClock.now + managedStaleManifestGracePeriod
    let quietWindow = min(managedLaunchAgentBTMSettleDelay, .milliseconds(250))
    var quietSince: ContinuousClock.Instant?
    var stoppedDaemons: [URL: Int32] = [:]

    while true {
      let candidates = HarnessMonitorPaths.managedDaemonRootCandidates(using: environment)
      let candidateRoots = Set(candidates.map(\.rootURL))
      let results = await quiesceManagedDaemonCandidates(
        candidates,
        stoppedDaemons: stoppedDaemons,
        deadline: deadline
      )
      let failures = results.compactMap { result in
        result.failure.map { "\(result.rootURL.path): \($0)" }
      }
      guard failures.isEmpty else {
        throw DaemonControlError.commandFailed(
          "Managed daemon quiescence failed: \(failures.sorted().joined(separator: "; "))"
        )
      }
      for result in results {
        if let stoppedPID = result.stoppedPID {
          stoppedDaemons[result.rootURL] = stoppedPID
        }
      }

      let refreshedRoots = Set(
        HarnessMonitorPaths.managedDaemonRootCandidates(using: environment).map(\.rootURL)
      )
      if refreshedRoots == candidateRoots {
        quietSince = quietSince ?? ContinuousClock.now
        if let quietSince, ContinuousClock.now - quietSince >= quietWindow {
          break
        }
      } else {
        quietSince = nil
      }
      guard ContinuousClock.now < deadline else {
        throw DaemonControlError.commandFailed(
          "managed daemon roots did not remain quiescent before timeout"
        )
      }
      try await Task.sleep(for: .milliseconds(50))
    }

    if stoppedDaemons.isEmpty == false {
      HarnessMonitorLogger.lifecycle.fault(
        "Stopped managed automation after legacy daemon cleanup failed"
      )
    }
  }

  private func quiesceManagedDaemonCandidates(
    _ candidates: [ManagedDaemonRootCandidate],
    stoppedDaemons: [URL: Int32],
    deadline: ContinuousClock.Instant
  ) async -> [ManagedDaemonQuiescenceResult] {
    await withTaskGroup(
      of: ManagedDaemonQuiescenceResult.self,
      returning: [ManagedDaemonQuiescenceResult].self
    ) { group in
      for candidate in candidates {
        group.addTask {
          do {
            return ManagedDaemonQuiescenceResult(
              rootURL: candidate.rootURL,
              stoppedPID: try await quiesceManagedDaemon(
                at: candidate,
                previouslyStoppedPID: stoppedDaemons[candidate.rootURL],
                deadline: deadline
              ),
              failure: nil
            )
          } catch {
            return ManagedDaemonQuiescenceResult(
              rootURL: candidate.rootURL,
              stoppedPID: nil,
              failure: error.localizedDescription
            )
          }
        }
      }
      var collected: [ManagedDaemonQuiescenceResult] = []
      for await result in group {
        collected.append(result)
      }
      return collected
    }
  }

  private func quiesceManagedDaemon(
    at candidate: ManagedDaemonRootCandidate,
    previouslyStoppedPID: Int32?,
    deadline: ContinuousClock.Instant
  ) async throws -> Int32? {
    var stopRequestedPID = previouslyStoppedPID
    var stoppedPID: Int32?
    while true {
      let lockIsHeld = daemonSingletonLockIsHeld(at: candidate.singletonLockURL)
      switch HarnessMonitorPaths.probeManagedDaemonManifest(at: candidate.manifestURL) {
      case .absent, .invalid:
        guard lockIsHeld else {
          return stoppedPID
        }
      case .external:
        return stoppedPID
      case .managed(let pid):
        switch managedDaemonQuiescenceAction(
          pid: pid,
          lockIsHeld: lockIsHeld,
          stopRequestedPID: stopRequestedPID
        ) {
        case .finish:
          return stoppedPID
        case .wait:
          break
        case .requestStop:
          let manifest = try loadManifest(
            at: candidate.manifestURL,
            emitTrace: false,
            activate: false,
            recoverEndpoint: true
          )
          guard manifest.pid == Int(pid) else {
            continue
          }
          try await requestManagedDaemonQuiescence(
            manifest,
            trustedDaemonRoot: candidate.rootURL,
            deadline: deadline
          )
          stopRequestedPID = pid
          stoppedPID = pid
        }
      }
      guard ContinuousClock.now < deadline else {
        throw DaemonControlError.commandFailed(
          "managed daemon did not release its singleton lock before timeout"
        )
      }
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  private func managedDaemonQuiescenceAction(
    pid: Int32,
    lockIsHeld: Bool,
    stopRequestedPID: Int32?
  ) -> ManagedDaemonQuiescenceAction {
    if stopRequestedPID == pid {
      return lockIsHeld ? .wait : .finish
    }
    if processLiveness(pid) == .dead {
      return lockIsHeld ? .wait : .finish
    }
    return .requestStop
  }

  private func requestManagedDaemonQuiescence(
    _ manifest: DaemonManifest,
    trustedDaemonRoot: URL,
    deadline: ContinuousClock.Instant
  ) async throws {
    let endpoint = try endpointURL(from: manifest.endpoint)
    guard Self.isTrustedManagedEndpoint(endpoint) else {
      throw DaemonControlError.invalidManifest(
        "managed daemon endpoints must use loopback http(s): \(manifest.endpoint)"
      )
    }
    let connection = try daemonConnection(
      from: manifest,
      trustedDaemonRoot: trustedDaemonRoot,
      emitTrace: false
    )
    let client = sessionFactory(connection)
    let remaining = ContinuousClock.now.duration(to: deadline)
    guard remaining > .zero else {
      try terminateManagedDaemonAfterControlFailure(
        manifest,
        reason: "managed daemon control deadline expired"
      )
      return
    }

    let gate = ManagedDaemonControlGate()
    let request = Task {
      do {
        _ = try? await client.setPolicyCanvasSpawnKillSwitch(
          request: PolicyCanvasSetSpawnKillSwitchRequest(enabled: true)
        )
        _ = try await client.stopDaemon()
        await client.shutdown()
        await gate.finish(.stopped)
      } catch {
        await client.shutdown()
        await gate.finish(.failed(error.localizedDescription))
      }
    }
    let timeout = Task {
      do {
        try await Task.sleep(for: remaining)
      } catch {
        return
      }
      await gate.finish(.timedOut)
    }
    let outcome = await withTaskCancellationHandler {
      await gate.wait()
    } onCancel: {
      Task { await gate.finish(.cancelled) }
    }
    timeout.cancel()

    switch outcome {
    case .stopped:
      return
    case .cancelled:
      request.cancel()
      Task { await client.shutdown() }
      throw CancellationError()
    case .failed(let reason):
      try terminateManagedDaemonAfterControlFailure(manifest, reason: reason)
    case .timedOut:
      request.cancel()
      Task {
        await client.shutdown()
        await request.value
      }
      try terminateManagedDaemonAfterControlFailure(
        manifest,
        reason: "managed daemon control deadline expired"
      )
    }
  }

  private func terminateManagedDaemonAfterControlFailure(
    _ manifest: DaemonManifest,
    reason: String
  ) throws {
    do {
      let pid = try validatedManagedDaemonFallbackPID(manifest)
      guard processSignal(pid, SIGTERM) == 0 else {
        throw DaemonControlError.commandFailed(
          "validated managed daemon process could not be terminated"
        )
      }
      HarnessMonitorLogger.lifecycle.fault(
        "Signaled validated managed daemon pid \(pid, privacy: .public) after control failure"
      )
    } catch {
      throw DaemonControlError.commandFailed(
        "Managed daemon control failed: \(reason); "
          + "validated process fallback failed: \(error.localizedDescription)"
      )
    }
  }
}
