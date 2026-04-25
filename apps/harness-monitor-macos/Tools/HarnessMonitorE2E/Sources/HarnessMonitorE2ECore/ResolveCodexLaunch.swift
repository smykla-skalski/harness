import Foundation

public enum CodexLaunchResolver {
    public static let preferredSlugs: [String] = [
        "gpt-5.3-codex-spark",
        "gpt-5.4-mini",
        "gpt-5.3-codex",
        "gpt-5.2",
        "gpt-5.4",
        "gpt-5.5",
    ]

    public static let effortPreference: [String] = ["low", "medium", "high", "xhigh"]

    public struct Resolution: Equatable {
        public let slug: String
        public let effort: String
    }

    /// Parse `codex debug models` JSON and pick the first preferred slug whose model exposes a known reasoning effort.
    /// Returns nil when no eligible model is present (matching the python helper, which exits 0 on absence).
    public static func resolve(fromJSON data: Data) -> Resolution? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = root["models"] as? [[String: Any]]
        else { return nil }

        var bySlug: [String: [String: Any]] = [:]
        for model in models {
            if let slug = model["slug"] as? String, !slug.isEmpty {
                bySlug[slug] = model
            }
        }

        if let resolution = pick(from: preferredSlugs.compactMap { bySlug[$0] }) {
            return resolution
        }
        return pick(from: models)
    }

    private static func pick(from candidates: [[String: Any]]) -> Resolution? {
        for model in candidates {
            guard
                let slug = model["slug"] as? String,
                !slug.isEmpty,
                let effort = effort(in: model)
            else { continue }
            return Resolution(slug: slug, effort: effort)
        }
        return nil
    }

    private static func effort(in model: [String: Any]) -> String? {
        let levels = (model["supported_reasoning_levels"] as? [[String: Any]] ?? [])
            .compactMap { $0["effort"] as? String }
        return effortPreference.first(where: { levels.contains($0) })
    }
}
