import SwiftUI
import TaskBoardDragLabTransfer

extension FullParityLaneView {
    @ViewBuilder var explicitDropRows: some View {
        ForEach(Array(lane.cards.enumerated()), id: \.element.id) { offset, card in
            if usesStableExplicitScrollDropTargets {
                explicitInsertionMarker(
                    at: offset,
                    isVisible: insertionState.offset == offset
                )
            } else if insertionState.offset == offset {
                explicitInsertionMarker(at: offset, isVisible: true)
            }
            explicitDropRow(card, at: offset)
        }
        if usesStableExplicitScrollDropTargets {
            explicitInsertionMarker(
                at: lane.cards.count,
                isVisible: insertionState.offset == lane.cards.count
            )
        } else if insertionState.offset == lane.cards.count {
            explicitInsertionMarker(at: lane.cards.count, isVisible: true)
        }
    }

    private func explicitDropRow(_ card: LabCard, at rowOffset: Int) -> some View {
        apiRow(card)
            .dropDestination(
                for: Payload.self,
                isEnabled: true
            ) { payloads, session in
                guard dragRuntime.accepts(laneID: lane.id) else { return }
                let offset = insertionOffset(for: session, rowOffset: rowOffset)
                LabTrace.emit(
                    "full-parity.explicit-row-destination",
                    fields: [
                        "lane": lane.id,
                        "offset": String(offset),
                        "payloads": String(payloads.count),
                        "row": card.id,
                    ]
                )
                performExplicitDrop(
                    payloads,
                    at: offset,
                    sessionID: session.id
                )
            }
            .dropConfiguration(explicitDropConfiguration)
            .onDropSessionUpdated { session in
                updateExplicitRowTarget(session, rowOffset: rowOffset)
            }
    }

    private func explicitInsertionMarker(
        at offset: Int,
        isVisible: Bool
    ) -> some View {
        Capsule()
            .fill(laneColor.opacity(0.72))
            .frame(maxWidth: .infinity)
            .frame(height: 1.5)
            .opacity(isVisible ? 1 : 0)
            .frame(
                maxWidth: .infinity,
                minHeight: markerHeight(isVisible: isVisible),
                maxHeight: markerHeight(isVisible: isVisible)
            )
            .contentShape(.rect)
            .accessibilityHidden(true)
            .dropDestination(
                for: Payload.self,
                isEnabled: true
            ) { payloads, session in
                guard dragRuntime.accepts(laneID: lane.id) else { return }
                LabTrace.emit(
                    "full-parity.explicit-marker-destination",
                    fields: [
                        "lane": lane.id,
                        "offset": String(offset),
                        "payloads": String(payloads.count),
                    ]
                )
                performExplicitDrop(
                    payloads,
                    at: offset,
                    sessionID: session.id
                )
            }
            .dropConfiguration(explicitDropConfiguration)
            .onDropSessionUpdated { session in
                updateExplicitMarkerTarget(session, offset: offset)
            }
            .transaction { transaction in
                transaction.animation = nil
            }
    }

    private func markerHeight(isVisible: Bool) -> CGFloat {
        if isVisible { return 18 }
        return usesStableExplicitScrollDropTargets ? 8 : 0
    }

    private func explicitDropConfiguration(_ session: DropSession) -> DropConfiguration {
        guard dragRuntime.accepts(laneID: lane.id) else {
            return DropConfiguration(operation: .forbidden)
        }
        let operation: DropOperation =
            session.suggestedOperations.contains(.move) ? .move : .copy
        return DropConfiguration(operation: operation)
    }

    private func performExplicitDrop<SessionID: Hashable>(
        _ payloads: [Payload],
        at offset: Int,
        sessionID: SessionID
    ) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            _ = onDrop(payloads, offset)
            insertionIndicator.clear(
                laneID: lane.id,
                sessionID: sessionID,
                reason: "drop-action"
            )
        }
    }

    private func updateExplicitRowTarget(
        _ session: DropSession,
        rowOffset: Int
    ) {
        guard dragRuntime.accepts(laneID: lane.id) else { return }
        switch session.phase {
        case .entering, .active:
            updateInsertionOffset(
                insertionOffset(for: session, rowOffset: rowOffset),
                sessionID: session.id
            )
        case .exiting, .ended, .dataTransferCompleted:
            break
        @unknown default:
            break
        }
    }

    private func updateExplicitMarkerTarget(
        _ session: DropSession,
        offset: Int
    ) {
        guard dragRuntime.accepts(laneID: lane.id) else { return }
        switch session.phase {
        case .entering, .active:
            updateInsertionOffset(offset, sessionID: session.id)
        case .exiting, .ended, .dataTransferCompleted:
            break
        @unknown default:
            break
        }
    }

    private func insertionOffset(
        for session: DropSession,
        rowOffset: Int
    ) -> Int {
        guard session.size.height > 0 else { return rowOffset }
        return session.location.y < session.size.height / 2
            ? rowOffset
            : rowOffset + 1
    }

    private func updateInsertionOffset<SessionID: Hashable>(
        _ offset: Int,
        sessionID: SessionID
    ) {
        insertionIndicator.update(
            laneID: lane.id,
            sessionID: sessionID,
            offset: offset
        )
    }
}
