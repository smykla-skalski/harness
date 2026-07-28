import Observation

@MainActor
@Observable
final class FullParityLaneInsertionState {
    fileprivate(set) var offset: Int?
}

@MainActor
final class FullParityInsertionIndicatorCoordinator {
    private struct ActiveTarget: Equatable {
        let sessionID: AnyHashable
        let laneID: String
    }

    private var activeTarget: ActiveTarget?
    private var states: [String: FullParityLaneInsertionState] = [:]

    func state(for laneID: String) -> FullParityLaneInsertionState {
        if let state = states[laneID] {
            return state
        }
        let state = FullParityLaneInsertionState()
        states[laneID] = state
        return state
    }

    func update<SessionID: Hashable>(
        laneID: String,
        sessionID: SessionID,
        offset: Int
    ) {
        let target = ActiveTarget(
            sessionID: AnyHashable(sessionID),
            laneID: laneID
        )
        if activeTarget != target {
            clearActive(reason: "destination-lane-changed")
            activeTarget = target
        }
        let state = state(for: laneID)
        guard state.offset != offset else { return }
        state.offset = offset
        LabTrace.emit(
            "full-parity.insertion-indicator.updated",
            fields: ["lane": laneID, "offset": String(offset)]
        )
    }

    func clear<SessionID: Hashable>(
        laneID: String,
        sessionID: SessionID,
        reason: String
    ) {
        let target = ActiveTarget(
            sessionID: AnyHashable(sessionID),
            laneID: laneID
        )
        guard activeTarget == target else { return }
        clearActive(reason: reason)
    }

    func clear(reason: String) {
        clearActive(reason: reason)
    }

    private func clearActive(reason: String) {
        guard let activeTarget else { return }
        states[activeTarget.laneID]?.offset = nil
        self.activeTarget = nil
        LabTrace.emit(
            "full-parity.insertion-indicator.cleared",
            fields: ["lane": activeTarget.laneID, "reason": reason]
        )
    }
}
