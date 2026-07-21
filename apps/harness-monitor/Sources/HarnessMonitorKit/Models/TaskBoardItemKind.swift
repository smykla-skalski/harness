import Foundation

/// Hand-written, not codegen: the Rust `TaskBoardItemKind::Unknown(String)`
/// carries the original wire value (so an older daemon does not corrupt a
/// newer kind on write-back), and the codegen string-enum emitter only
/// supports fieldless variants. The shape mirrors what that emitter would
/// have produced for a plain open enum.
public enum TaskBoardItemKind: TaskBoardOpenEnum, CaseIterable, Identifiable {
  case task
  case umbrella
  case unknown(String)

  public static let allCases: [Self] = [.task, .umbrella]

  public var rawValue: String {
    switch self {
    case .task: "task"
    case .umbrella: "umbrella"
    case .unknown(let raw): raw
    }
  }

  public init(rawValue: String) {
    switch rawValue {
    case "task": self = .task
    case "umbrella": self = .umbrella
    default: self = .unknown(rawValue)
    }
  }

  public var id: String { rawValue }
}
