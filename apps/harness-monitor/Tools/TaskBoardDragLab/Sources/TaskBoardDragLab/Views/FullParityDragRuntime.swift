import Observation
import TaskBoardDragLabTransfer

@MainActor
@Observable
final class FullParityLaneDropHighlightState {
    fileprivate(set) var isTargeted = false
}

@MainActor
final class FullParityDragRuntime {
    private(set) var cardIDs: [FullParityCardID] = []
    private(set) var candidateLaneIDs: Set<String> = []
    private var activeTargetLaneID: String?
    private var highlightStates: [String: FullParityLaneDropHighlightState] = [:]

    var isActive: Bool {
        !cardIDs.isEmpty
    }

    func begin(cardIDs: [FullParityCardID], lanes: [LabLane]) {
        self.cardIDs = cardIDs
        candidateLaneIDs = Set(
            lanes.lazy
                .filter { !$0.fullParityIsUmbrella }
                .map(\.id)
        )
        LabTrace.emit(
            "full-parity.drag-runtime.begin",
            fields: [
                "candidates": candidateLaneIDs.sorted().joined(separator: ","),
                "cards": cardIDs.map(\.traceValue).joined(separator: ","),
            ]
        )
    }

    func accepts(laneID: String) -> Bool {
        candidateLaneIDs.contains(laneID)
    }

    func highlightState(for laneID: String) -> FullParityLaneDropHighlightState {
        if let state = highlightStates[laneID] {
            return state
        }
        let state = FullParityLaneDropHighlightState()
        highlightStates[laneID] = state
        return state
    }

    func setTargeted(_ targeted: Bool, laneID: String) {
        if targeted {
            guard accepts(laneID: laneID) else {
                clearTarget(laneID: laneID)
                return
            }
            if activeTargetLaneID != laneID {
                clearActiveTarget()
                activeTargetLaneID = laneID
            }
            let state = highlightState(for: laneID)
            guard !state.isTargeted else { return }
            state.isTargeted = true
            LabTrace.emit(
                "full-parity.drop-highlight.entered",
                fields: ["lane": laneID]
            )
        } else {
            clearTarget(laneID: laneID)
        }
    }

    func clear(reason: String) {
        clearActiveTarget()
        cardIDs = []
        candidateLaneIDs = []
        LabTrace.emit(
            "full-parity.drag-runtime.cleared",
            fields: ["reason": reason]
        )
    }

    private func clearTarget(laneID: String) {
        guard activeTargetLaneID == laneID else { return }
        clearActiveTarget()
    }

    private func clearActiveTarget() {
        guard let activeTargetLaneID else { return }
        highlightStates[activeTargetLaneID]?.isTargeted = false
        self.activeTargetLaneID = nil
        LabTrace.emit(
            "full-parity.drop-highlight.exited",
            fields: ["lane": activeTargetLaneID]
        )
    }
}
