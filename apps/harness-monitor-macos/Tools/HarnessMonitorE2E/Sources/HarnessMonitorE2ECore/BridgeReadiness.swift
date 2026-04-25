import Foundation

public enum BridgeReadiness {
    public static let requiredCapabilities = ["codex", "agent-tui"]

    /// Mirror of the python helper: bridge is ready iff `running` is true and every required capability reports `healthy=true`.
    public static func isReady(fromJSON data: Data, requiredCapabilities: [String] = requiredCapabilities) -> Bool {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            (root["running"] as? Bool) == true
        else { return false }

        let capabilities = root["capabilities"] as? [String: Any] ?? [:]
        for name in requiredCapabilities {
            guard let entry = capabilities[name] as? [String: Any],
                  (entry["healthy"] as? Bool) == true else { return false }
        }
        return true
    }
}
