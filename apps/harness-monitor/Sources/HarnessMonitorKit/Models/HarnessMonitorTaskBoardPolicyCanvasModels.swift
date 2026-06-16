import Foundation
import HarnessMonitorPolicyModels

public struct TaskBoardPolicyPipelinePort: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var title: String

  public init(id: String, title: String) {
    self.id = id
    self.title = title
  }
}

public struct TaskBoardPolicyPipelineEdge: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var fromNode: String
  public var fromPort: String
  public var toNode: String
  public var toPort: String
  public var condition: TaskBoardPolicyPipelineEdgeCondition
  public var label: String?

  public var fromNodeId: String { fromNode }
  public var toNodeId: String { toNode }

  public init(
    id: String,
    fromNodeId: String,
    fromPort: String,
    toNodeId: String,
    toPort: String,
    label: String? = nil,
    condition: TaskBoardPolicyPipelineEdgeCondition = .always
  ) {
    self.id = id
    self.fromNode = fromNodeId
    self.fromPort = fromPort
    self.toNode = toNodeId
    self.toPort = toPort
    self.condition = condition
    self.label = label
  }

  enum CodingKeys: String, CodingKey {
    case id
    case fromNode = "from_node"
    case fromPort = "from_port"
    case toNode = "to_node"
    case toPort = "to_port"
    case condition
    case label
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    fromNode = try container.decode(String.self, forKey: .fromNode)
    fromPort = try container.decode(String.self, forKey: .fromPort)
    toNode = try container.decode(String.self, forKey: .toNode)
    toPort = try container.decode(String.self, forKey: .toPort)
    condition =
      try container.decodeIfPresent(TaskBoardPolicyPipelineEdgeCondition.self, forKey: .condition)
      ?? .always
    label = try container.decodeIfPresent(String.self, forKey: .label)
  }
}

public struct TaskBoardPolicyPipelineEdgeCondition: Codable, Equatable, Sendable {
  public static let always = Self(condition: "always")

  public var condition: String
  public var actions: [PolicyAction]
  public var reasonCode: String?

  public init(
    condition: String,
    actions: [PolicyAction] = [],
    reasonCode: String? = nil
  ) {
    self.condition = condition
    self.actions = actions
    self.reasonCode = reasonCode
  }

  enum CodingKeys: String, CodingKey {
    case condition
    case actions
    case reasonCode = "reason_code"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    condition = try container.decode(String.self, forKey: .condition)
    actions = try container.decodeIfPresent([PolicyAction].self, forKey: .actions) ?? []
    reasonCode = try container.decodeIfPresent(String.self, forKey: .reasonCode)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(condition, forKey: .condition)
    if !actions.isEmpty {
      try container.encode(actions, forKey: .actions)
    }
    try container.encodeIfPresent(reasonCode, forKey: .reasonCode)
  }
}

public struct TaskBoardPolicyPipelineGroup: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var label: String
  public var nodeIds: [String]
  public var color: String
  public var frame: TaskBoardPolicyCanvasRect

  public var title: String {
    get { label }
    set { label = newValue }
  }

  public init(
    id: String,
    title: String,
    color: String = "#6aa8ff",
    frame: TaskBoardPolicyCanvasRect = .zero,
    nodeIds: [String] = []
  ) {
    self.id = id
    self.label = title
    self.nodeIds = nodeIds
    self.color = color
    self.frame = frame
  }

  enum CodingKeys: String, CodingKey {
    case id
    case label
    case color
    case frame
    case nodeIds = "node_ids"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    label = try container.decode(String.self, forKey: .label)
    color = try container.decodeIfPresent(String.self, forKey: .color) ?? "#6aa8ff"
    frame =
      try container.decodeIfPresent(TaskBoardPolicyCanvasRect.self, forKey: .frame)
      ?? .zero
    nodeIds = try container.decodeIfPresent([String].self, forKey: .nodeIds) ?? []
  }
}

public struct TaskBoardPolicyPipelineLayout: Codable, Equatable, Sendable {
  public var zoom: Double
  public var offset: TaskBoardPolicyCanvasPoint
  public var nodes: [TaskBoardPolicyPipelineNodeLayout]
  public var routingHints: [TaskBoardPolicyPipelineEdgeRoutingHint]

  public init(
    zoom: Double = 1,
    offset: TaskBoardPolicyCanvasPoint = .zero,
    nodes: [TaskBoardPolicyPipelineNodeLayout] = [],
    routingHints: [TaskBoardPolicyPipelineEdgeRoutingHint] = []
  ) {
    self.zoom = zoom
    self.offset = offset
    self.nodes = nodes
    self.routingHints = routingHints
  }

  enum CodingKeys: String, CodingKey {
    case zoom
    case offset
    case nodes
    case routingHints = "routing_hints"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    zoom = try container.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
    offset =
      try container.decodeIfPresent(TaskBoardPolicyCanvasPoint.self, forKey: .offset)
      ?? .zero
    nodes =
      try container.decodeIfPresent([TaskBoardPolicyPipelineNodeLayout].self, forKey: .nodes) ?? []
    routingHints =
      try container.decodeIfPresent(
        [TaskBoardPolicyPipelineEdgeRoutingHint].self,
        forKey: .routingHints
      ) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(zoom, forKey: .zoom)
    try container.encode(offset, forKey: .offset)
    try container.encode(nodes, forKey: .nodes)
    if !routingHints.isEmpty {
      try container.encode(routingHints, forKey: .routingHints)
    }
  }
}

public struct TaskBoardPolicyPipelineNodeLayout: Codable, Equatable, Sendable {
  public var nodeId: String
  public var x: Int
  public var y: Int
  public var source: PolicyGraphNodeLayoutSource?

  public init(
    nodeId: String,
    x: Int,
    y: Int,
    source: PolicyGraphNodeLayoutSource? = nil
  ) {
    self.nodeId = nodeId
    self.x = x
    self.y = y
    self.source = source
  }

  enum CodingKeys: String, CodingKey {
    case nodeId = "node_id"
    case x
    case y
    case source
  }
}

public struct TaskBoardPolicyPipelineEdgeRoutingHint: Codable, Equatable, Sendable {
  public var edgeId: String
  public var sourceScopeId: String
  public var targetScopeId: String
  public var targetNodeId: String
  public var label: String
  public var laneIndex: Int
  public var horizontalLaneY: Double
  public var verticalLaneX: Double?
  public var bundleOrdinal: Int
  public var bundleSize: Int

  public init(
    edgeId: String,
    sourceScopeId: String,
    targetScopeId: String,
    targetNodeId: String,
    label: String,
    laneIndex: Int,
    horizontalLaneY: Double,
    verticalLaneX: Double? = nil,
    bundleOrdinal: Int = 0,
    bundleSize: Int = 1
  ) {
    self.edgeId = edgeId
    self.sourceScopeId = sourceScopeId
    self.targetScopeId = targetScopeId
    self.targetNodeId = targetNodeId
    self.label = label
    self.laneIndex = laneIndex
    self.horizontalLaneY = horizontalLaneY
    self.verticalLaneX = verticalLaneX
    self.bundleOrdinal = bundleOrdinal
    self.bundleSize = bundleSize
  }

  enum CodingKeys: String, CodingKey {
    case edgeId = "edge_id"
    case sourceScopeId = "source_scope_id"
    case targetScopeId = "target_scope_id"
    case targetNodeId = "target_node_id"
    case label
    case laneIndex = "lane_index"
    case horizontalLaneY = "horizontal_lane_y"
    case verticalLaneX = "vertical_lane_x"
    case bundleOrdinal = "bundle_ordinal"
    case bundleSize = "bundle_size"
  }
}

public struct TaskBoardPolicyExportRequest: Codable, Equatable, Sendable {
  public var canvasId: String?

  public init(canvasId: String? = nil) {
    self.canvasId = canvasId
  }
}

public struct TaskBoardPolicyExportResponse: Codable, Equatable, Sendable {
  public var canvasId: String
  public var title: String
  public var document: TaskBoardPolicyPipelineDocument

  public init(canvasId: String, title: String, document: TaskBoardPolicyPipelineDocument) {
    self.canvasId = canvasId
    self.title = title
    self.document = document
  }

  enum CodingKeys: String, CodingKey {
    case canvasId = "canvas_id"
    case title
    case document
  }
}

public struct TaskBoardPolicyImportRequest: Codable, Equatable, Sendable {
  public var document: TaskBoardPolicyPipelineDocument
  public var title: String?

  public init(document: TaskBoardPolicyPipelineDocument, title: String? = nil) {
    self.document = document
    self.title = title
  }
}

public struct TaskBoardPolicyCanvasPoint: Codable, Equatable, Sendable {
  public static let zero = Self(x: 0, y: 0)

  public var x: Double
  public var y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }

  enum CodingKeys: String, CodingKey {
    case x
    case y
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    x = try container.decode(Double.self, forKey: .x)
    y = try container.decode(Double.self, forKey: .y)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Int(x.rounded()), forKey: .x)
    try container.encode(Int(y.rounded()), forKey: .y)
  }
}

public struct TaskBoardPolicyCanvasRect: Codable, Equatable, Sendable {
  public static let zero = Self(x: 0, y: 0, width: 0, height: 0)

  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  enum CodingKeys: String, CodingKey {
    case x
    case y
    case width
    case height
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    x = try container.decode(Double.self, forKey: .x)
    y = try container.decode(Double.self, forKey: .y)
    width = try container.decode(Double.self, forKey: .width)
    height = try container.decode(Double.self, forKey: .height)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Int(x.rounded()), forKey: .x)
    try container.encode(Int(y.rounded()), forKey: .y)
    try container.encode(Int(width.rounded()), forKey: .width)
    try container.encode(Int(height.rounded()), forKey: .height)
  }
}
