import AppKit

@MainActor
final class FullParityNativeListCoordinator {
    private final class WeakTable {
        weak var value: NSTableView?

        init(_ value: NSTableView) {
            self.value = value
        }
    }

    private struct PendingReveal: Equatable {
        let cardID: String
        let laneID: String
    }

    private var feedbackStyle: NSTableView.DraggingDestinationFeedbackStyle = .regular
    private var pendingReveal: PendingReveal?
    private var tablesByLaneID: [String: WeakTable] = [:]

    func register(_ tableView: NSTableView, laneID: String) {
        pruneTables()
        tablesByLaneID[laneID] = WeakTable(tableView)
        tableView.draggingDestinationFeedbackStyle = feedbackStyle
        tableView.selectionHighlightStyle = .none
        tableView.focusRingType = .none
    }

    func beginDrag() {
        setFeedbackStyle(.gap, reason: "drag-started")
    }

    func prepareForModelMutation() {
        setFeedbackStyle(.regular, reason: "before-model-mutation")
    }

    func finishDrag(reason: String) {
        setFeedbackStyle(.regular, reason: reason)
    }

    func requestReveal(cardID: String, in laneID: String) {
        pendingReveal = PendingReveal(cardID: cardID, laneID: laneID)
    }

    func cancelReveal(cardID: String, in laneID: String) {
        let request = PendingReveal(cardID: cardID, laneID: laneID)
        if pendingReveal == request {
            pendingReveal = nil
        }
    }

    func revealPendingCard(
        in laneID: String,
        cardIDs: [String],
        leadingRowCount: Int
    ) {
        guard
            let request = pendingReveal,
            request.laneID == laneID,
            let cardOffset = cardIDs.firstIndex(of: request.cardID),
            let tableView = tablesByLaneID[laneID]?.value
        else {
            return
        }
        pendingReveal = nil
        scrollRowToVisible(
            cardOffset + leadingRowCount,
            in: tableView,
            remainingAttempts: 3
        )
    }

    private func setFeedbackStyle(
        _ style: NSTableView.DraggingDestinationFeedbackStyle,
        reason: String
    ) {
        guard feedbackStyle != style else { return }
        feedbackStyle = style
        pruneTables()
        for table in tablesByLaneID.values.compactMap(\.value) {
            table.draggingDestinationFeedbackStyle = style
        }
        LabTrace.emit(
            "full-parity.native-list.feedback",
            fields: [
                "reason": reason,
                "style": style == .gap ? "gap" : "regular",
                "tables": String(tablesByLaneID.count),
            ]
        )
    }

    private func scrollRowToVisible(
        _ row: Int,
        in tableView: NSTableView,
        remainingAttempts: Int
    ) {
        DispatchQueue.main.async { [weak self, weak tableView] in
            guard let self, let tableView else { return }
            if row < tableView.numberOfRows {
                tableView.scrollRowToVisible(row)
            } else if remainingAttempts > 1 {
                scrollRowToVisible(
                    row,
                    in: tableView,
                    remainingAttempts: remainingAttempts - 1
                )
            }
        }
    }

    private func pruneTables() {
        tablesByLaneID = tablesByLaneID.filter { $0.value.value != nil }
    }
}
