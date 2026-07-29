import Observation
import SwiftUI
import TaskBoardDragLabTransfer

struct FullParityBoardView<Payload: FullParityCardPayload>: View {
    let store: BoardStore
    let usesScrollLanes: Bool
    let usesExplicitScrollDropTargets: Bool
    let usesStableExplicitScrollDropTargets: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectionModel = FullParitySelectionModel()
    @State private var insertionIndicator = FullParityInsertionIndicatorCoordinator()
    @State private var dragRuntime = FullParityDragRuntime()
    @State private var nativeListCoordinator = FullParityNativeListCoordinator()

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            FullParityLaneStripLayout(spacing: 16) {
                laneColumns
            }
            .padding(.vertical, 4)
        }
        .scrollClipDisabled()
        .dragContainer(for: Payload.self, itemID: \.id) { cardIDs in
            store.fullParityDragPayloads(for: cardIDs, as: Payload.self)
        }
        .dragContainerSelection(selectionModel.orderedSelectedIDs)
        .dragConfiguration(.init(allowMove: true))
        .dragPreviewsFormation(.pile)
        .onDragSessionUpdated(updateDragSession)
        .task(id: store.orderSignature) {
            selectionModel.updateVisibleIDs(
                store.lanes.flatMap { lane in
                    lane.cards.map { FullParityCardID.api($0.id) }
                }
            )
        }
        .onDisappear {
            finishDrag(reason: "board-disappeared")
        }
        .onChange(of: scenePhase) {
            if scenePhase != .active {
                finishDrag(reason: "scene-inactive")
            }
        }
        .accessibilityIdentifier("task-board-drag-lab.full-parity-board")
    }

    @ViewBuilder private var laneColumns: some View {
        ForEach(store.lanes) { lane in
            FullParityLaneView<Payload>(
                lane: lane,
                usesScrollLane: usesScrollLanes,
                usesExplicitScrollDropTargets: usesExplicitScrollDropTargets,
                usesStableExplicitScrollDropTargets:
                    usesStableExplicitScrollDropTargets,
                selectionModel: selectionModel,
                dragRuntime: dragRuntime,
                dropHighlightState: dragRuntime.highlightState(for: lane.id),
                nativeListCoordinator: nativeListCoordinator,
                insertionState: insertionIndicator.state(for: lane.id),
                insertionIndicator: insertionIndicator,
                onDrop: { payloads, insertionOffset in
                    handleDrop(
                        payloads,
                        laneID: lane.id,
                        insertionOffset: insertionOffset
                    )
                }
            )
            .environment(store)
            .layoutValue(
                key: FullParityLanePreferredWidthKey.self,
                value: lane.fullParityIsCollapsed ? 72 : 420
            )
            .layoutValue(
                key: FullParityLaneCanExpandKey.self,
                value: !lane.fullParityIsCollapsed
            )
        }
    }

    private func updateDragSession(_ session: DragSession) {
        LabTrace.emit(
            "full-parity.drag.session",
            fields: [
                "phase": phaseName(session.phase),
                "session": String(session.id.hashValue, radix: 16),
            ]
        )
        switch session.phase {
        case .initial:
            insertionIndicator.clear(reason: "drag-started")
            beginDrag(session)
            nativeListCoordinator.beginDrag()
        case .active:
            break
        case .ended(let operation):
            if operation == .cancel || operation == .forbidden {
                finishDrag(reason: "drag-ended-\(String(describing: operation))")
            }
        case .dataTransferCompleted:
            break
        @unknown default:
            finishDrag(reason: "drag-ended-unknown")
        }
    }

    private func beginDrag(_ session: DragSession) {
        let cardIDs = session.draggedItemIDs(for: FullParityCardID.self)
        guard !cardIDs.isEmpty else {
            LabTrace.emit("full-parity.drag.initial.empty")
            return
        }
        dragRuntime.begin(cardIDs: cardIDs, lanes: store.lanes)
        LabTrace.emit(
            "full-parity.drag.initial",
            fields: [
                "candidates": dragRuntime.candidateLaneIDs.sorted().joined(separator: ","),
                "cards": cardIDs.map(\.traceValue).joined(separator: ","),
                "laneChecks": String(store.lanes.count),
            ]
        )
    }

    private func handleDrop(
        _ payloads: [Payload],
        laneID: String,
        insertionOffset: Int
    ) -> Bool {
        guard !payloads.isEmpty else {
            return false
        }
        nativeListCoordinator.prepareForModelMutation()
        let revealCardID: String? =
            if let firstPayload = payloads.first,
               case .api(let cardID) = firstPayload.id
            {
                cardID
            } else {
                nil
            }
        let before = store.orderSignature
        if let revealCardID {
            nativeListCoordinator.requestReveal(cardID: revealCardID, in: laneID)
        }
        LabTrace.emit(
            "full-parity.drop",
            fields: [
                "cards": payloads.map(\.id.traceValue).joined(separator: ","),
                "lane": laneID,
                "offset": String(insertionOffset),
                "representation": String(describing: Payload.self),
            ]
        )
        store.move(
            payloads: payloads,
            to: laneID,
            proposedOffset: insertionOffset,
            source: "FullParity.DynamicViewContent"
        )
        if let revealCardID, store.orderSignature == before {
            nativeListCoordinator.cancelReveal(cardID: revealCardID, in: laneID)
        }
        finishDrag(reason: "drop-delivered")
        return true
    }

    private func finishDrag(reason: String) {
        nativeListCoordinator.finishDrag(reason: reason)
        insertionIndicator.clear(reason: reason)
        dragRuntime.clear(reason: reason)
    }

    private func phaseName(_ phase: DragSession.Phase) -> String {
        switch phase {
        case .initial: "initial"
        case .active: "active"
        case .ended(let operation): "ended-\(String(describing: operation))"
        case .dataTransferCompleted: "data-transfer-completed"
        @unknown default: "unknown"
        }
    }
}

extension LabLane {
    var fullParityIsUmbrella: Bool {
        role == .umbrella
    }

    var fullParityIsCollapsed: Bool {
        isCollapsed
    }

    var fullParityHasDecisionRows: Bool {
        id == "human_required"
    }

    var fullParityHasInboxRows: Bool {
        id == "in_progress"
    }
}

@MainActor
@Observable
final class FullParitySelectionModel {
    private(set) var selectedIDs: Set<FullParityCardID> = []
    private(set) var orderedVisibleIDs: [FullParityCardID] = []

    var orderedSelectedIDs: [FullParityCardID] {
        orderedVisibleIDs.filter(selectedIDs.contains)
    }

    func select(_ cardID: FullParityCardID) {
        selectedIDs = [cardID]
    }

    func selectForDrag(_ cardIDs: [FullParityCardID]) {
        selectedIDs = Set(cardIDs)
    }

    func updateVisibleIDs(_ cardIDs: [FullParityCardID]) {
        guard orderedVisibleIDs != cardIDs else {
            return
        }
        orderedVisibleIDs = cardIDs
        selectedIDs.formIntersection(cardIDs)
    }
}

private struct FullParityLanePreferredWidthKey: LayoutValueKey {
    static let defaultValue: CGFloat? = nil
}

private struct FullParityLaneCanExpandKey: LayoutValueKey {
    static let defaultValue = true
}

private struct FullParityLaneStripLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        let widths = preferredWidths(for: subviews)
        let height = zip(subviews, widths).map { subview, width in
            subview.sizeThatFits(
                ProposedViewSize(width: width, height: nil)
            ).height
        }.max() ?? 0
        return CGSize(
            width: widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1)),
            height: max(height, proposal.height ?? 0)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, preferredWidths(for: subviews)) {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width + spacing
        }
    }

    private func preferredWidths(for subviews: Subviews) -> [CGFloat] {
        subviews.map { subview in
            subview[FullParityLanePreferredWidthKey.self] ?? 420
        }
    }
}
