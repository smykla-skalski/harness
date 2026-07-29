import CoreTransferable
import Foundation
import OSLog
import UniformTypeIdentifiers

public enum FullParityCardID: Codable, Hashable, Sendable {
    case api(String)
    case inbox(sessionID: String, taskID: String)

    public var cardID: String {
        switch self {
        case .api(let cardID):
            cardID
        case .inbox(_, let taskID):
            taskID
        }
    }

    public var traceValue: String {
        switch self {
        case .api(let cardID):
            "api:\(cardID)"
        case .inbox(let sessionID, let taskID):
            "inbox:\(sessionID):\(taskID)"
        }
    }
}

public enum FullParityTaskBoardStatus: String, Codable, Hashable, Sendable {
    case inbox
    case todo
    case planning
    case inProgress = "in_progress"
    case agenticReview = "agentic_review"
    case testing
    case inReview = "in_review"
    case toReview = "to_review"
    case humanRequired = "human_required"
    case failed
    case done
    case new
    case planReview = "plan_review"
    case needsYou = "needs_you"
    case blocked
}

public enum FullParityTaskStatus: String, Codable, Hashable, Sendable {
    case open
    case inProgress = "in_progress"
    case awaitingReview = "awaiting_review"
    case inReview = "in_review"
    case done
    case blocked
}

public enum FullParityCardKind: String, Codable, Hashable, Sendable {
    case task
    case umbrella
}

public enum FullParityCardDragItem: Codable, Equatable, Sendable, Identifiable {
    case api(
        itemID: String,
        status: FullParityTaskBoardStatus,
        kind: FullParityCardKind = .task
    )
    case inbox(
        sessionID: String,
        taskID: String,
        status: FullParityTaskStatus,
        sourceLaneRawValue: String
    )

    public var id: FullParityCardID {
        switch self {
        case .api(let itemID, _, _):
            .api(itemID)
        case .inbox(let sessionID, let taskID, _, _):
            .inbox(sessionID: sessionID, taskID: taskID)
        }
    }

    public var sourceLaneID: String {
        switch self {
        case .api(_, let status, let kind):
            kind == .umbrella ? FullParityLaneID.umbrella : status.rawValue
        case .inbox(_, _, _, let sourceLaneRawValue):
            sourceLaneRawValue
        }
    }

    public func accepts(destinationLaneID: String) -> Bool {
        guard destinationLaneID != FullParityLaneID.umbrella else {
            return false
        }
        switch self {
        case .api(_, _, let kind):
            return kind == .task
        case .inbox:
            return sourceLaneID != destinationLaneID
                && FullParityLaneID.inboxDropDestinations.contains(destinationLaneID)
        }
    }
}

public protocol FullParityCardPayload:
    Codable,
    Transferable,
    Identifiable,
    Sendable
where ID == FullParityCardID {
    var items: [FullParityCardDragItem] { get }

    init(item: FullParityCardDragItem)
    init(primaryCardID: FullParityCardID, items: [FullParityCardDragItem])
}

public struct FullParityCustomPayload: FullParityCardPayload {
    public let id: FullParityCardID
    public let items: [FullParityCardDragItem]

    public init(item: FullParityCardDragItem) {
        id = item.id
        items = [item]
    }

    public init(
        primaryCardID: FullParityCardID,
        items: [FullParityCardDragItem]
    ) {
        id = primaryCardID
        self.items = items
    }

    public init(from decoder: any Decoder) throws {
        (id, items) = try FullParityPayloadCodec.decode(
            from: decoder,
            transferType: "custom"
        )
    }

    public func encode(to encoder: any Encoder) throws {
        try FullParityPayloadCodec.encode(
            id: id,
            items: items,
            to: encoder,
            transferType: "custom"
        )
    }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .fullParityTaskBoardCard)
    }
}

public struct FullParityJSONPayload: FullParityCardPayload {
    public let id: FullParityCardID
    public let items: [FullParityCardDragItem]

    public init(item: FullParityCardDragItem) {
        id = item.id
        items = [item]
    }

    public init(
        primaryCardID: FullParityCardID,
        items: [FullParityCardDragItem]
    ) {
        id = primaryCardID
        self.items = items
    }

    public init(from decoder: any Decoder) throws {
        (id, items) = try FullParityPayloadCodec.decode(
            from: decoder,
            transferType: "json"
        )
    }

    public func encode(to encoder: any Encoder) throws {
        try FullParityPayloadCodec.encode(
            id: id,
            items: items,
            to: encoder,
            transferType: "json"
        )
    }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

public extension UTType {
    static let fullParityTaskBoardCard = UTType(
        exportedAs: "io.harnessmonitor.task-board-card",
        conformingTo: .json
    )
}

private enum FullParityLaneID {
    static let umbrella = "umbrella_items"

    static let inboxDropDestinations: Set<String> = [
        "todo",
        "in_progress",
        "in_review",
        "to_review",
        "failed",
    ]
}

private enum FullParityPayloadCodec {
    private static let logger = Logger(
        subsystem: "io.harnessmonitor.task-board-drag-lab",
        category: "TaskBoardDrag"
    )

    static func decode(
        from decoder: any Decoder,
        transferType: String
    ) throws -> (FullParityCardID, [FullParityCardDragItem]) {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(FullParityCardID.self, forKey: .id)
        let items = try container.decode([FullParityCardDragItem].self, forKey: .items)
        logger.notice(
            "payload.decode transfer=\(transferType, privacy: .public) card=\(id.traceValue, privacy: .public) items=\(items.count)"
        )
        return (id, items)
    }

    static func encode(
        id: FullParityCardID,
        items: [FullParityCardDragItem],
        to encoder: any Encoder,
        transferType: String
    ) throws {
        logger.notice(
            "payload.encode transfer=\(transferType, privacy: .public) card=\(id.traceValue, privacy: .public) items=\(items.count)"
        )
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(items, forKey: .items)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case items
    }
}
