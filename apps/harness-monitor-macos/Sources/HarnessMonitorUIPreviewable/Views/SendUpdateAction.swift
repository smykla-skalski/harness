import Foundation

enum SendUpdateAction: Hashable {
  case injectContext
  case custom

  var rawCommand: String {
    switch self {
    case .injectContext:
      "inject_context"
    case .custom:
      ""
    }
  }

  var humanLabel: String {
    switch self {
    case .injectContext:
      "Inject context"
    case .custom:
      "Other…"
    }
  }

  static let allLabeledCases: [Self] = [.injectContext, .custom]
}
