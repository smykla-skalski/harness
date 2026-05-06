import HarnessMonitorKit

struct AgentCapabilityTransportChoice: Identifiable, Hashable {
  let id: AgentLaunchSelection
  let title: String
  let capabilities: [String]

  var capabilityLabels: [String] {
    capabilities.map(Self.humanCapabilityLabel(for:))
  }

  var capabilitySummary: String {
    let labels = capabilityLabels.filter { !$0.isEmpty }.prefix(3)
    return labels.isEmpty ? title : labels.joined(separator: ", ")
  }

  private static func humanCapabilityLabel(for capability: String) -> String {
    switch capability {
    case "fs.read":
      "filesystem read"
    case "fs.write":
      "filesystem write"
    case "terminal.spawn":
      "terminal spawn"
    case "terminal.create":
      "terminal create"
    case "streaming":
      "streaming"
    case "multi-turn":
      "multi-turn"
    case "requires-network":
      "network access"
    default:
      capability.replacingOccurrences(of: ".", with: " ")
    }
  }
}
