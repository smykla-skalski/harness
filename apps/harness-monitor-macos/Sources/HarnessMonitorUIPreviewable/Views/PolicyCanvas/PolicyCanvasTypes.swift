import HarnessMonitorKit
import SwiftUI

enum PolicyCanvasTab: String, CaseIterable, Identifiable {
  case draft
  case simulation
  case promotion

  var id: String { rawValue }

  var title: String {
    switch self {
    case .draft:
      "Draft"
    case .simulation:
      "Simulation"
    case .promotion:
      "Promotion"
    }
  }
}

enum PolicyCanvasNodeKind: String, CaseIterable, Identifiable {
  case source
  case condition
  case review
  case transform
  case decision

  var id: String { rawValue }

  var title: String {
    switch self {
    case .source:
      "Source"
    case .condition:
      "Condition"
    case .review:
      "Review"
    case .transform:
      "Transform"
    case .decision:
      "Decision"
    }
  }

  var subtitle: String {
    switch self {
    case .source:
      "Event intake"
    case .condition:
      "Policy rule"
    case .review:
      "Human gate"
    case .transform:
      "Context map"
    case .decision:
      "Outcome"
    }
  }

  var symbolName: String {
    switch self {
    case .source:
      "tray.and.arrow.down"
    case .condition:
      "line.3.horizontal.decrease.circle"
    case .review:
      "person.badge.shield.checkmark"
    case .transform:
      "arrow.triangle.branch"
    case .decision:
      "checkmark.seal"
    }
  }

  var accentColor: Color {
    switch self {
    case .source:
      Color.cyan
    case .condition:
      Color.indigo
    case .review:
      Color.orange
    case .transform:
      Color.mint
    case .decision:
      Color.green
    }
  }

  var inputPortTitles: [String] {
    switch self {
    case .source:
      []
    case .condition:
      ["event"]
    case .review:
      ["policy"]
    case .transform:
      ["context"]
    case .decision:
      ["result"]
    }
  }

  var outputPortTitles: [String] {
    switch self {
    case .source:
      ["event"]
    case .condition:
      ["pass", "fail"]
    case .review:
      ["approved", "denied"]
    case .transform:
      ["mapped"]
    case .decision:
      ["promote"]
    }
  }
}

enum PolicyCanvasPortKind: String {
  case input
  case output
}

struct PolicyCanvasPort: Identifiable, Hashable {
  let id: String
  let title: String
  let kind: PolicyCanvasPortKind
}

struct PolicyCanvasNode: Identifiable {
  let id: String
  var title: String
  var subtitle: String
  var kind: PolicyCanvasNodeKind
  var position: CGPoint
  var groupID: String?
  var policyKind: TaskBoardPolicyPipelineNodeKind?
  var inputPorts: [PolicyCanvasPort]
  var outputPorts: [PolicyCanvasPort]

  init(id: String, title: String, kind: PolicyCanvasNodeKind, position: CGPoint) {
    self.id = id
    self.title = title
    self.subtitle = kind.subtitle
    self.kind = kind
    self.position = position
    self.groupID = nil
    self.policyKind = nil
    self.inputPorts = kind.inputPortTitles.map { title in
      PolicyCanvasPort(
        id: "\(PolicyCanvasPortKind.input.rawValue)-\(title)",
        title: title,
        kind: .input
      )
    }
    self.outputPorts = kind.outputPortTitles.map { title in
      PolicyCanvasPort(
        id: "\(PolicyCanvasPortKind.output.rawValue)-\(title)",
        title: title,
        kind: .output
      )
    }
  }
}

enum PolicyCanvasGroupTone: String, CaseIterable {
  case intake
  case evaluation
  case release

  var color: Color {
    switch self {
    case .intake:
      Color.cyan
    case .evaluation:
      Color.purple
    case .release:
      Color.green
    }
  }

  var hexColor: String {
    switch self {
    case .intake:
      "#58d7f2"
    case .evaluation:
      "#bb7bff"
    case .release:
      "#72d989"
    }
  }
}

struct PolicyCanvasGroup: Identifiable {
  let id: String
  var title: String
  var frame: CGRect
  var tone: PolicyCanvasGroupTone
}

struct PolicyCanvasPortEndpoint: Hashable {
  let nodeID: String
  let portID: String
  let kind: PolicyCanvasPortKind
}

struct PolicyCanvasEdge: Identifiable, Hashable {
  let id: String
  var source: PolicyCanvasPortEndpoint
  var target: PolicyCanvasPortEndpoint
  var label: String
}

enum PolicyCanvasSelection: Hashable {
  case node(String)
  case group(String)
  case edge(String)
}

enum PolicyCanvasLayout {
  static let gridSize: CGFloat = 20
  static let nodeSize = CGSize(width: 168, height: 96)
  static let portDiameter: CGFloat = 12
  static let groupCornerRadius: CGFloat = 8
  static let initialContentOrigin = CGPoint(x: 36, y: 72)
  static let groupHorizontalPadding: CGFloat = 44
  static let groupVerticalPadding: CGFloat = 52
  static let minimumGroupSize = CGSize(width: 220, height: 180)

  static func portY(index: Int, count: Int) -> CGFloat {
    guard count > 1 else {
      return nodeSize.height / 2
    }
    let step = min(CGFloat(24), nodeSize.height / CGFloat(count + 1))
    let top = (nodeSize.height - (step * CGFloat(count - 1))) / 2
    return top + (CGFloat(index) * step)
  }
}
