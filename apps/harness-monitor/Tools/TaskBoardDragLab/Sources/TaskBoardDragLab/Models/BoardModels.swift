import Foundation

enum BoardMode: String, CaseIterable, Identifiable {
    case list = "List"
    case lazyVStack = "LazyVStack"

    var id: Self { self }
}

enum ListContentRoute: String, CaseIterable, Identifiable {
    case direct = "Direct child"
    case conditionalHelper = "Conditional helper"
    case productionSiblings = "Production siblings"

    var id: Self { self }
}

enum LabParityStage: Int, CaseIterable, Identifiable {
    case baseline
    case denseBoard
    case buttonCards
    case containerSelection
    case dragStateMutation
    case hoverGeometry
    case customLaneLayout
    case clippedDestination
    case fullProductionShape
    case noOuterDropConfiguration
    case exactProductionDestination
    case dashboardVerticalScroll
    case partiallyVisiblePlanning
    case noPerCardDragObserver
    case noOuterDropWrapper
    case enumDragIdentity
    case productionPayloadShape
    case initialOnlyDragLifecycle
    case fullProductionParity
    case builtInJSONTransfer
    case fullProductionScrollView
    case explicitScrollDropTargets
    case stableExplicitScrollDropTargets

    var id: Self { self }

    var title: String {
        switch self {
        case .baseline: "0 · Proven baseline"
        case .denseBoard: "1 · Production data"
        case .buttonCards: "2 · Button cards"
        case .containerSelection: "3 · Container selection"
        case .dragStateMutation: "4 · Drag-start state"
        case .hoverGeometry: "5 · Hover geometry"
        case .customLaneLayout: "6 · Custom lane Layout"
        case .clippedDestination: "7 · Clipped Planning"
        case .fullProductionShape: "8 · Full production shape"
        case .noOuterDropConfiguration: "9 · No outer drop configuration"
        case .exactProductionDestination: "10 · Exact production destination"
        case .dashboardVerticalScroll: "11 · Dashboard vertical ScrollView"
        case .partiallyVisiblePlanning: "12 · Planning clipped 44 pt"
        case .noPerCardDragObserver: "13 · No per-card drag observer"
        case .noOuterDropWrapper: "14 · No outer drop wrapper"
        case .enumDragIdentity: "15 · Enum drag identity"
        case .productionPayloadShape: "16 · Production payload shape"
        case .initialOnlyDragLifecycle: "17 · Initial-only drag lifecycle"
        case .fullProductionParity: "18 · Full production parity"
        case .builtInJSONTransfer: "19 · Built-in JSON transfer"
        case .fullProductionScrollView: "20 · Full production ScrollView"
        case .explicitScrollDropTargets: "21 · Explicit ScrollView targets"
        case .stableExplicitScrollDropTargets: "22 · Stable ScrollView targets"
        }
    }

    var usesDenseBoard: Bool { self >= .denseBoard }
    var usesButtonCards: Bool { self >= .buttonCards }
    var usesContainerSelection: Bool { self >= .containerSelection }
    var mutatesStateAtDragStart: Bool { self >= .dragStateMutation }
    var usesHoverGeometry: Bool { self >= .hoverGeometry }
    var usesCustomLaneLayout: Bool { self >= .customLaneLayout }
    var clipsDestinationLane: Bool { self >= .clippedDestination }
    var usesProductionSiblings: Bool { self >= .fullProductionShape }
    var usesExplicitDropConfiguration: Bool { self < .noOuterDropConfiguration }
    var usesDropSessionObserver: Bool { self < .exactProductionDestination }
    var usesDashboardVerticalScroll: Bool { self >= .dashboardVerticalScroll }
    var clipsPlanningByProductionAmount: Bool { self >= .partiallyVisiblePlanning }
    var usesPerCardDragObserver: Bool { self < .noPerCardDragObserver }
    var usesOuterDropWrapper: Bool { self < .noOuterDropWrapper }
    var usesEnumDragIdentity: Bool { self >= .enumDragIdentity }
    var usesProductionPayloadShape: Bool { self >= .productionPayloadShape }
    var usesInitialOnlyDragLifecycle: Bool { self >= .initialOnlyDragLifecycle }
    var usesFullProductionParity: Bool { self >= .fullProductionParity }
    var usesBuiltInJSONTransfer: Bool { self == .builtInJSONTransfer }
    var usesFullProductionScrollView: Bool { self >= .fullProductionScrollView }
    var usesExplicitScrollDropTargets: Bool { self >= .explicitScrollDropTargets }
    var usesStableExplicitScrollDropTargets: Bool {
        self == .stableExplicitScrollDropTargets
    }

    var dragInstruction: String {
        if usesStableExplicitScrollDropTargets {
            "Stable marker slots: drag several Todo cards into Planning."
        } else if usesExplicitScrollDropTargets {
            "Pure SwiftUI row targets: drag Todo 01 below Planning 01."
        } else if usesFullProductionScrollView {
            "ScrollView + LazyVStack: drag Todo 01 below Planning 01."
        } else if usesBuiltInJSONTransfer {
            "Repeat stage 18 using the built-in JSON representation."
        } else if usesFullProductionParity {
            "Drag Todo 01 into Planning, below Planning 01."
        } else if usesInitialOnlyDragLifecycle {
            "List + Drag container: repeat the stage 16 Todo 01 drop."
        } else if usesProductionPayloadShape {
            "List + Drag container: repeat the stage 15 Todo 01 drop."
        } else if usesEnumDragIdentity {
            "List + Drag container: compare the same Todo 01 drop with stage 14."
        } else if usesDenseBoard {
            "Drag Todo 01 into Planning, below Planning 01."
        } else {
            "Drag Doing 1 into Done, below Done 2."
        }
    }
}

extension LabParityStage: Comparable {
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum DragSourceMode: String, CaseIterable, Identifiable {
    case transferable = "Transferable"
    case typedProvider = "Typed provider"
    case container = "Drag container"

    var id: Self { self }
}

struct LabCard: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
}

enum LabCardDragID: Codable, Hashable, Sendable {
    case api(String)
    case inbox(sessionID: String, taskID: String)

    var cardID: String {
        switch self {
        case .api(let cardID):
            cardID
        case .inbox(_, let taskID):
            taskID
        }
    }

    var traceValue: String {
        switch self {
        case .api(let cardID):
            "api:\(cardID)"
        case .inbox(let sessionID, let taskID):
            "inbox:\(sessionID):\(taskID)"
        }
    }
}

enum LabLaneRole: String, Equatable, Sendable {
    case workflow
    case umbrella
}

enum LabReconcileState: Equatable, Sendable {
    case idle
    case scheduled(generation: Int)
}

struct LabLane: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let role: LabLaneRole
    var isCollapsed: Bool
    var cards: [LabCard]

    init(
        id: String,
        title: String,
        cards: [LabCard],
        role: LabLaneRole = .workflow,
        isCollapsed: Bool = false
    ) {
        self.id = id
        self.title = title
        self.role = role
        self.isCollapsed = isCollapsed
        self.cards = cards
    }

    var acceptsAPICardDrop: Bool {
        role != .umbrella
    }
}
