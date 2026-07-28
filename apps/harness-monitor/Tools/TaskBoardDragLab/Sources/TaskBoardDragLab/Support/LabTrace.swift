import Foundation
import OSLog
import SwiftUI

enum LabTrace {
    private static let logger = Logger(
        subsystem: "io.harnessmonitor.task-board-drag-lab",
        category: "DragDrop"
    )

    static func emit(_ event: String, fields: [String: String] = [:]) {
        let details = fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let line = details.isEmpty ? event : "\(event) \(details)"
        logger.notice("\(line, privacy: .public)")
        print("[TaskBoardDragLab] \(line)")
    }

    @MainActor
    static func dragSession(_ session: DragSession, cardID: String, laneID: String) {
        emit(
            "drag.session",
            fields: [
                "card": cardID,
                "draggedIDs": session.draggedItemIDs(for: String.self).joined(separator: ","),
                "itemIndex": String(session.draggedItemIndex),
                "lane": laneID,
                "location": point(session.location),
                "phase": session.phase.description,
                "session": String(session.id.hashValue, radix: 16),
            ]
        )
    }

    @MainActor
    static func boardDragSession(
        _ session: DragSession,
        usesEnumDragIdentity: Bool = false,
        readsIDsOnlyInitially: Bool = false
    ) {
        let draggedIDs =
            if readsIDsOnlyInitially, case .initial = session.phase {
                session
                    .draggedItemIDs(for: LabCardDragID.self)
                    .map(\.traceValue)
                    .joined(separator: ",")
            } else if readsIDsOnlyInitially {
                "<not-read>"
            } else if usesEnumDragIdentity {
                session
                    .draggedItemIDs(for: LabCardDragID.self)
                    .map(\.traceValue)
                    .joined(separator: ",")
            } else {
                session.draggedItemIDs(for: String.self).joined(separator: ",")
            }
        emit(
            "board.drag.session",
            fields: [
                "draggedIDs": draggedIDs,
                "phase": session.phase.description,
                "session": String(session.id.hashValue, radix: 16),
            ]
        )
    }

    @MainActor
    static func dropSession(
        _ session: DropSession,
        mode: BoardMode,
        laneID: String,
        target: String,
        event: String
    ) {
        emit(
            event,
            fields: [
                "draggedIDs": session.localSession?
                    .draggedItemIDs(for: String.self)
                    .joined(separator: ",") ?? "<external>",
                "items": String(session.itemsCount),
                "lane": laneID,
                "location": point(session.location),
                "mode": mode.rawValue,
                "phase": session.phase.description,
                "session": session.id.description,
                "size": size(session.size),
                "suggested": operations(session.suggestedOperations),
                "target": target,
            ]
        )
    }

    private static func point(_ point: CGPoint) -> String {
        String(format: "%.1f,%.1f", point.x, point.y)
    }

    private static func size(_ size: CGSize) -> String {
        String(format: "%.1fx%.1f", size.width, size.height)
    }

    private static func operations(_ operations: DropOperation.Set) -> String {
        var names: [String] = []
        if operations.contains(.cancel) { names.append("cancel") }
        if operations.contains(.copy) { names.append("copy") }
        if operations.contains(.move) { names.append("move") }
        if operations.contains(.forbidden) { names.append("forbidden") }
        if operations.contains(.delete) { names.append("delete") }
        if operations.contains(.alias) { names.append("alias") }
        return names.isEmpty ? "<none>" : names.joined(separator: ",")
    }
}
