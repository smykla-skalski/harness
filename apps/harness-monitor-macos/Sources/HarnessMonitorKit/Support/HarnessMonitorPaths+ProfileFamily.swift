import Foundation

/// Profile-family classification mirroring the Rust
/// `crate::daemon::discovery::ProfileFamily` enum. Two siblings are
/// adoption-compatible iff they share a family. Agent profiles are
/// hermetic: `agent-X` only matches `agent-X`, never `agent-Y` and
/// never the user/non-agent lane.
public enum HarnessMonitorProfileFamily: Equatable {
  case agent(String)
  case nonAgent

  public static let agentPrefix = "agent-"

  /// Classify the family for the given runtime-profile slug. `nil`,
  /// empty, or any non-`agent-*` profile is `nonAgent`.
  public static func from(profile: String?) -> Self {
    guard let profile = profile?.trimmingCharacters(in: .whitespacesAndNewlines),
      !profile.isEmpty
    else {
      return Self.nonAgent
    }
    if profile.hasPrefix(agentPrefix) {
      let id = String(profile.dropFirst(agentPrefix.count))
      return Self.agent(id)
    }
    return Self.nonAgent
  }

  /// Classify the family by walking a filesystem path for the
  /// `runtime-profiles/<name>` segment. Used to derive the family of a
  /// daemon manifest from its on-disk root.
  public static func from(rootPath: String) -> Self {
    let components = NSString(string: rootPath).standardizingPath
      .split(separator: "/")
      .map(String.init)
    let profileDirectoryIndex = components.firstIndex(
      of: HarnessMonitorRuntimeProfile.dataHomeProfilesDirectoryName
    )
    guard let profileDirectoryIndex,
      components.indices.contains(profileDirectoryIndex + 1)
    else {
      return Self.nonAgent
    }
    return from(profile: components[profileDirectoryIndex + 1])
  }

  /// Same hermetic rule the daemon uses: identical agent ids only;
  /// non-agent only adopts non-agent.
  public static func compatible(
    _ own: Self,
    _ sibling: Self
  ) -> Bool {
    switch (own, sibling) {
    case (.agent(let ownAgentID), .agent(let siblingAgentID)):
      return ownAgentID == siblingAgentID
    case (.nonAgent, .nonAgent):
      return true
    default:
      return false
    }
  }
}

extension HarnessMonitorPaths {
  /// Resolve the current process's profile family from the monitor
  /// environment. Mirrors `resolvedRuntimeProfile` so agent builds
  /// classify as `.agent(<uuid>)` and the user/base lane classifies as
  /// `.nonAgent`.
  public static func ownProfileFamily(
    using environment: HarnessMonitorEnvironment = .current
  ) -> HarnessMonitorProfileFamily {
    HarnessMonitorProfileFamily.from(
      profile: resolvedRuntimeProfile(using: environment)
    )
  }

  /// Classify the family of a daemon root URL. The manifest URL is one
  /// directory deeper, so callers normally pass
  /// `manifestURL.deletingLastPathComponent()`.
  public static func profileFamily(forRoot rootURL: URL) -> HarnessMonitorProfileFamily {
    HarnessMonitorProfileFamily.from(rootPath: rootURL.path)
  }
}
