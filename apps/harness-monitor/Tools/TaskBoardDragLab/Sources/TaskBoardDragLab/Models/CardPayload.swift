import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let taskBoardDragLabCard = UTType(
        exportedAs: "io.harnessmonitor.task-board-drag-lab.card",
        conformingTo: .json
    )
}

struct CardPayload: Codable, Hashable, Identifiable, Sendable, Transferable {
    let id: String
    let title: String
    let detail: String
    let sourceLaneID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .taskBoardDragLabCard)
    }

    init(card: LabCard, sourceLaneID: String) {
        id = card.id
        title = card.title
        detail = card.detail
        self.sourceLaneID = sourceLaneID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decode(String.self, forKey: .detail)
        sourceLaneID = try container.decode(String.self, forKey: .sourceLaneID)
        LabTrace.emit(
            "payload.decode",
            fields: [
                "card": id,
                "sourceLane": sourceLaneID,
            ]
        )
    }

    func encode(to encoder: any Encoder) throws {
        LabTrace.emit(
            "payload.encode",
            fields: [
                "card": id,
                "sourceLane": sourceLaneID,
            ]
        )
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(detail, forKey: .detail)
        try container.encode(sourceLaneID, forKey: .sourceLaneID)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case detail
        case sourceLaneID
    }
}

struct EnumIdentityCardPayload: Codable, Hashable, Identifiable, Sendable, Transferable {
    let id: LabCardDragID
    let title: String
    let detail: String
    let sourceLaneID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .taskBoardDragLabCard)
    }

    init(card: LabCard, sourceLaneID: String) {
        id = .api(card.id)
        title = card.title
        detail = card.detail
        self.sourceLaneID = sourceLaneID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(LabCardDragID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decode(String.self, forKey: .detail)
        sourceLaneID = try container.decode(String.self, forKey: .sourceLaneID)
        LabTrace.emit(
            "payload.decode",
            fields: [
                "card": id.traceValue,
                "sourceLane": sourceLaneID,
            ]
        )
    }

    func encode(to encoder: any Encoder) throws {
        LabTrace.emit(
            "payload.encode",
            fields: [
                "card": id.traceValue,
                "sourceLane": sourceLaneID,
            ]
        )
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(detail, forKey: .detail)
        try container.encode(sourceLaneID, forKey: .sourceLaneID)
    }

    var cardPayload: CardPayload {
        CardPayload(
            card: LabCard(id: id.cardID, title: title, detail: detail),
            sourceLaneID: sourceLaneID
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case detail
        case sourceLaneID
    }
}

enum LabProductionCardKind: String, Codable, Sendable {
    case task
}

enum ProductionShapeCardDragItem: Codable, Equatable, Sendable, Identifiable {
    case api(
        itemID: String,
        status: String,
        kind: LabProductionCardKind = .task
    )
    case inbox(
        sessionID: String,
        taskID: String,
        status: String,
        sourceLaneRawValue: String
    )

    var id: LabCardDragID {
        switch self {
        case .api(let itemID, _, _):
            .api(itemID)
        case .inbox(let sessionID, let taskID, _, _):
            .inbox(sessionID: sessionID, taskID: taskID)
        }
    }

    var sourceLaneID: String {
        switch self {
        case .api(_, let status, _):
            status
        case .inbox(_, _, _, let sourceLaneRawValue):
            sourceLaneRawValue
        }
    }
}

struct ProductionShapeCardPayload: Codable, Transferable, Identifiable, Sendable {
    let id: LabCardDragID
    let items: [ProductionShapeCardDragItem]

    private enum CodingKeys: String, CodingKey {
        case id
        case items
    }

    init(item: ProductionShapeCardDragItem) {
        id = item.id
        items = [item]
    }

    init(
        primaryCardID: LabCardDragID,
        items: [ProductionShapeCardDragItem]
    ) {
        id = primaryCardID
        self.items = items
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(LabCardDragID.self, forKey: .id)
        items = try container.decode([ProductionShapeCardDragItem].self, forKey: .items)
        LabTrace.emit(
            "payload.decode",
            fields: [
                "card": id.traceValue,
                "items": String(items.count),
                "shape": "production",
            ]
        )
    }

    func encode(to encoder: any Encoder) throws {
        LabTrace.emit(
            "payload.encode",
            fields: [
                "card": id.traceValue,
                "items": String(items.count),
                "shape": "production",
            ]
        )
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(items, forKey: .items)
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .taskBoardDragLabCard)
    }
}
