import Foundation

// Wire/model split for the /v1/diagnostics report. The generated *Wire types pin the daemon's
// snake_case keys so the plain PolicyWireCoding.decoder reads them without convertFromSnakeCase,
// and these maps fold each wire back onto its rich hand model. The rich DaemonManifest keeps its
// legacy host-bridge reconstruction and DaemonDiagnostics its Foundation-backed path defaulting
// for the non-wire decode paths; the wire decode always carries the current daemon shape, so the
// maps construct the models directly. acp_runtime_probe and DaemonManifest.ownership are absent
// from the wire (the hand models never modelled them) - matching today's convert decode, which
// ignores those keys.

extension DaemonDiagnosticsReport {
  init(wire: DaemonDiagnosticsReportWire) {
    self.init(
      health: wire.health.map(HealthResponse.init(wire:)),
      manifest: wire.manifest.map(DaemonManifest.init(wire:)),
      launchAgent: LaunchAgentStatus(wire: wire.launchAgent),
      githubApi: wire.githubApi.map(GitHubApiDiagnostics.init(wire:)),
      workspace: DaemonDiagnostics(wire: wire.workspace),
      recentEvents: wire.recentEvents.map(DaemonAuditEvent.init(wire:))
    )
  }
}

extension DaemonManifest {
  init(wire: DaemonManifestWire) {
    self.init(
      version: wire.version,
      pid: Int(wire.pid),
      endpoint: wire.endpoint,
      startedAt: wire.startedAt,
      tokenPath: wire.tokenPath,
      sandboxed: wire.sandboxed,
      hostBridge: HostBridgeManifest(wire: wire.hostBridge),
      revision: wire.revision,
      updatedAt: wire.updatedAt,
      binaryStamp: wire.binaryStamp.map(DaemonBinaryStamp.init(wire:))
    )
  }
}

extension HostBridgeManifest {
  init(wire: HostBridgeManifestWire) {
    self.init(
      running: wire.running,
      socketPath: wire.socketPath,
      capabilities: wire.capabilities.mapValues(HostBridgeCapabilityManifest.init(wire:))
    )
  }
}

extension HostBridgeCapabilityManifest {
  init(wire: HostBridgeCapabilityManifestWire) {
    self.init(
      enabled: wire.enabled,
      healthy: wire.healthy,
      transport: wire.transport,
      endpoint: wire.endpoint,
      metadata: wire.metadata
    )
  }
}

extension DaemonBinaryStamp {
  init(wire: DaemonBinaryStampWire) {
    self.init(
      helperPath: wire.helperPath,
      deviceIdentifier: wire.deviceIdentifier,
      inode: wire.inode,
      fileSize: wire.fileSize,
      modificationTimeIntervalSince1970: wire.modificationTimeIntervalSince1970
    )
  }
}

extension DaemonAuditEvent {
  init(wire: DaemonAuditEventWire) {
    self.init(recordedAt: wire.recordedAt, level: wire.level, message: wire.message)
  }
}

extension DaemonDiagnostics {
  init(wire: DaemonDiagnosticsWire) {
    self.init(
      daemonRoot: wire.daemonRoot,
      manifestPath: wire.manifestPath,
      authTokenPath: wire.authTokenPath,
      authTokenPresent: wire.authTokenPresent,
      eventsPath: wire.eventsPath,
      databasePath: wire.databasePath,
      databaseSizeBytes: Int(wire.databaseSizeBytes),
      lastEvent: wire.lastEvent.map(DaemonAuditEvent.init(wire:))
    )
  }
}

extension LaunchAgentStatus {
  init(wire: LaunchAgentStatusWire) {
    self.init(
      installed: wire.installed,
      loaded: wire.loaded,
      label: wire.label,
      path: wire.path,
      domainTarget: wire.domainTarget,
      serviceTarget: wire.serviceTarget,
      state: wire.state,
      pid: wire.pid.map(Int.init),
      lastExitStatus: wire.lastExitStatus.map(Int.init),
      statusError: wire.statusError
    )
  }
}

extension HealthResponse {
  init(wire: HealthResponseWire) {
    self.init(
      status: wire.status,
      version: wire.version,
      pid: Int(wire.pid),
      endpoint: wire.endpoint,
      startedAt: wire.startedAt,
      logLevel: wire.logLevel,
      projectCount: Int(wire.projectCount),
      worktreeCount: Int(wire.worktreeCount),
      sessionCount: Int(wire.sessionCount),
      wireVersion: Int(wire.wireVersion)
    )
  }
}

extension GitHubApiDiagnostics {
  init(wire: GitHubApiDiagnosticsWire) {
    self.init(
      buckets: wire.buckets.map(GitHubRateBucketDiagnostics.init(wire:)),
      cooling: wire.cooling.map(GitHubCooldownDiagnostics.init(wire:)),
      lastHourNetworkRequests: wire.lastHourNetworkRequests,
      lastHourGraphqlPoints: wire.lastHourGraphqlPoints,
      cacheHits: wire.cacheHits,
      cacheStaleHits: wire.cacheStaleHits,
      cacheDeferredHits: wire.cacheDeferredHits,
      deferredBudget: wire.deferredBudget,
      topOperations: wire.topOperations.map(GitHubOperationSpendDiagnostics.init(wire:))
    )
  }
}

extension GitHubRateBucketDiagnostics {
  init(wire: GitHubRateBucketDiagnosticsWire) {
    self.init(
      resource: wire.resource,
      remaining: wire.remaining,
      limit: wire.limit,
      used: wire.used,
      resetAt: wire.resetAt
    )
  }
}

extension GitHubCooldownDiagnostics {
  init(wire: GitHubCooldownDiagnosticsWire) {
    self.init(
      resource: wire.resource,
      reason: wire.reason,
      untilSecondsFromNow: wire.untilSecondsFromNow
    )
  }
}

extension GitHubOperationSpendDiagnostics {
  init(wire: GitHubOperationSpendDiagnosticsWire) {
    self.init(
      operation: wire.operation,
      networkRequests: wire.networkRequests,
      graphqlPoints: wire.graphqlPoints
    )
  }
}

// The /v1/daemon/stop control response (status thin mirror), backs stopDaemon on both transports.
extension DaemonControlResponse {
  init(wire: DaemonControlResponseWire) {
    self.init(status: wire.status)
  }
}

// The host-bridge reconfigure status report. pid/uptime narrow UInt -> Int; the capabilities reuse
// the daemon-state HostBridgeCapabilityManifest map.
extension BridgeStatusReport {
  init(wire: BridgeStatusReportWire) {
    self.init(
      running: wire.running,
      socketPath: wire.socketPath,
      pid: wire.pid.map(Int.init),
      startedAt: wire.startedAt,
      uptimeSeconds: wire.uptimeSeconds.map(Int.init),
      capabilities: wire.capabilities.mapValues(HostBridgeCapabilityManifest.init(wire:))
    )
  }
}
