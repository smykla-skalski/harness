import Foundation

public enum AgentNameGenerator {
  public enum Outcome: Equatable, Sendable {
    case generated(String)
    case exhausted(fallback: String, runtime: AgentTuiRuntime)

    public var name: String {
      switch self {
      case .generated(let value): value
      case .exhausted(let fallback, _): fallback
      }
    }
  }

  public static func generate(
    for runtime: AgentTuiRuntime,
    avoiding previous: String? = nil,
    excluding taken: [String] = [],
    using rng: inout some RandomNumberGenerator
  ) -> Outcome {
    let exclusions = ExclusionSet(taken: taken, previous: previous)
    let firsts = firstNames(for: runtime)
    for _ in 0..<32 {
      guard let first = firsts.randomElement(using: &rng) else { break }
      let last = surname(for: runtime, using: &rng)
      let candidate = "\(first) \(last)"
      if !exclusions.collides(full: candidate) {
        assert(validate(candidate, runtime: runtime))
        return .generated(candidate)
      }
    }
    return .exhausted(fallback: numberedFallback(for: runtime, taken: exclusions), runtime: runtime)
  }

  public static func generate(
    for runtime: AgentTuiRuntime,
    avoiding previous: String? = nil,
    excluding taken: [String] = []
  ) -> Outcome {
    var rng = SystemRandomNumberGenerator()
    return generate(for: runtime, avoiding: previous, excluding: taken, using: &rng)
  }

  static func numberedFallback(
    for runtime: AgentTuiRuntime,
    taken: ExclusionSet
  ) -> String {
    let title = runtime.title
    var index = taken.fullNames.count + 1
    while index < 10_000 {
      let candidate = "\(title) Agent \(index)"
      if !taken.collides(full: candidate) {
        return candidate
      }
      index += 1
    }
    return "\(title) Agent"
  }

  public static func validate(_ name: String, runtime: AgentTuiRuntime) -> Bool {
    let parts = name.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    guard parts.count == 2 else { return false }
    let first = String(parts[0])
    let last = String(parts[1])
    switch runtime {
    case .codex:
      return first.starts(with: "C") && last.lowercased().contains("x")
    case .claude:
      return first.starts(with: "C") && last.starts(with: "C")
    case .gemini:
      return first.starts(with: "G") && last.starts(with: "G")
    case .copilot:
      return first.starts(with: "P")
    case .vibe:
      return first.starts(with: "V")
    case .opencode:
      return first.starts(with: "O") && last.starts(with: "C")
    }
  }

  static func firstNames(for runtime: AgentTuiRuntime) -> [String] {
    switch runtime {
    case .codex, .claude: AgentNameFirsts.cNames
    case .gemini: AgentNameFirsts.gNames
    case .copilot: AgentNameFirsts.pNames
    case .vibe: AgentNameFirsts.vNames
    case .opencode: AgentNameFirsts.oNames
    }
  }

  static func surname(
    for runtime: AgentTuiRuntime,
    using rng: inout some RandomNumberGenerator
  ) -> String {
    switch runtime {
    case .codex: AgentNameSurnames.codex(&rng)
    case .claude: AgentNameSurnames.claude(&rng)
    case .gemini: AgentNameSurnames.gemini(&rng)
    case .copilot: AgentNameSurnames.robot(&rng)
    case .vibe: AgentNameSurnames.rasta(&rng)
    case .opencode: AgentNameSurnames.opencode(&rng)
    }
  }

  struct ExclusionSet {
    let fullNames: Set<String>

    init(taken: [String], previous: String?) {
      var fulls = Set<String>()
      for raw in taken + [previous].compactMap({ $0 }) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        fulls.insert(trimmed.lowercased())
      }
      self.fullNames = fulls
    }

    func collides(full: String) -> Bool {
      fullNames.contains(full.lowercased())
    }
  }
}
