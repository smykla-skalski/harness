import Foundation
import Observation
import TaskBoardDragLabTransfer

@MainActor
@Observable
final class BoardStore {
    private(set) var parityStage = LabParityStage.baseline
    private(set) var lanes = LabBoardFixtures.seeded
    private(set) var reconcileState = LabReconcileState.idle
    private var reconcileGeneration = 0

    init(parityStage: LabParityStage = .baseline) {
        self.parityStage = parityStage
        lanes = Self.lanes(for: parityStage)
    }

    var orderSignature: String {
        lanes
            .map { lane in
                "\(lane.id):\(lane.cards.map(\.id).joined(separator: ","))"
            }
            .joined(separator: "|")
    }

    var fullParityOrderedCardIDs: [FullParityCardID] {
        lanes.flatMap { $0.cards.map { .api($0.id) } }
    }

    func lane(id: String) -> LabLane? {
        lanes.first { $0.id == id }
    }

    func reset() {
        cancelPendingReconcile()
        lanes = Self.lanes(for: parityStage)
        LabTrace.emit("store.reset", fields: ["stage": parityStage.title])
        traceRenderedOrder(reason: "reset")
    }

    func configure(for stage: LabParityStage) {
        guard parityStage != stage else { return }
        cancelPendingReconcile()
        parityStage = stage
        lanes = Self.lanes(for: stage)
        LabTrace.emit("store.configure", fields: ["stage": stage.title])
        traceRenderedOrder(reason: "parity-stage-change")
    }

    func finishFullParityReconciliation() async {
        guard case .scheduled(let generation) = reconcileState else { return }
        while reconcileState == .scheduled(generation: generation) {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    func dragPayloads(for cardIDs: [String]) -> [CardPayload] {
        let payloads: [CardPayload] = cardIDs.compactMap { cardID -> CardPayload? in
            guard
                let lane = lanes.first(where: { lane in
                    lane.cards.contains(where: { $0.id == cardID })
                }),
                let card = lane.cards.first(where: { $0.id == cardID })
            else {
                return nil
            }
            return CardPayload(card: card, sourceLaneID: lane.id)
        }
        LabTrace.emit(
            "container.payloads",
            fields: [
                "produced": String(payloads.count),
                "requested": String(cardIDs.count),
            ]
        )
        return payloads
    }

    func enumIdentityDragPayloads(
        for cardIDs: [LabCardDragID]
    ) -> [EnumIdentityCardPayload] {
        let payloads = cardIDs.compactMap { cardID -> EnumIdentityCardPayload? in
            guard
                case .api(let rawCardID) = cardID,
                let lane = lanes.first(where: { lane in
                    lane.cards.contains(where: { $0.id == rawCardID })
                }),
                let card = lane.cards.first(where: { $0.id == rawCardID })
            else {
                return nil
            }
            return EnumIdentityCardPayload(card: card, sourceLaneID: lane.id)
        }
        LabTrace.emit(
            "container.payloads",
            fields: [
                "identity": "enum",
                "produced": String(payloads.count),
                "requested": String(cardIDs.count),
            ]
        )
        return payloads
    }

    func productionShapeDragPayloads(
        for cardIDs: [LabCardDragID]
    ) -> [ProductionShapeCardPayload] {
        let payloads = cardIDs.compactMap { cardID -> ProductionShapeCardPayload? in
            guard
                case .api(let rawCardID) = cardID,
                let lane = lanes.first(where: { lane in
                    lane.cards.contains(where: { $0.id == rawCardID })
                })
            else {
                return nil
            }
            return ProductionShapeCardPayload(
                item: .api(
                    itemID: rawCardID,
                    status: lane.id,
                    kind: .task
                )
            )
        }
        LabTrace.emit(
            "container.payloads",
            fields: [
                "identity": "enum",
                "produced": String(payloads.count),
                "requested": String(cardIDs.count),
                "shape": "production",
            ]
        )
        return payloads
    }

    func fullParityDragPayloads<Payload: FullParityCardPayload>(
        for cardIDs: [FullParityCardID],
        as payloadType: Payload.Type
    ) -> [Payload] {
        let payloads = cardIDs.compactMap(fullParityDragItem).map {
            payloadType.init(item: $0)
        }
        LabTrace.emit(
            "container.payloads",
            fields: [
                "identity": "enum",
                "produced": String(payloads.count),
                "requested": String(cardIDs.count),
                "shape": "full-production",
                "transfer": String(describing: payloadType),
            ]
        )
        return payloads
    }

    func accepts(
        cardIDs: [FullParityCardID],
        destinationLaneID: String
    ) -> Bool {
        guard
            let destination = lane(id: destinationLaneID),
            destination.acceptsAPICardDrop
        else {
            traceCandidateAcceptance(
                accepted: false,
                cardIDs: cardIDs,
                destinationLaneID: destinationLaneID,
                reason: "non-droppable-destination"
            )
            return false
        }
        let items = uniqueFullParityItems(for: cardIDs)
        let accepted = !items.isEmpty
            && items.allSatisfy { $0.accepts(destinationLaneID: destinationLaneID) }
        traceCandidateAcceptance(
            accepted: accepted,
            cardIDs: cardIDs,
            destinationLaneID: destinationLaneID,
            reason: accepted ? "accepted" : "same-lane-or-invalid"
        )
        return accepted
    }

    func move<Payload: FullParityCardPayload>(
        payloads: [Payload],
        to targetLaneID: String,
        proposedOffset: Int,
        source: String
    ) {
        let items = uniqueFullParityItems(in: payloads)
        guard
            !items.isEmpty,
            items.allSatisfy({ $0.accepts(destinationLaneID: targetLaneID) })
        else {
            LabTrace.emit(
                "store.mutation.rejected",
                fields: [
                    "reason": "full-parity-drop-plan",
                    "targetLane": targetLaneID,
                ]
            )
            return
        }
        let cardPayloads = items.compactMap(cardPayload)
        let before = orderSignature
        move(
            payloads: cardPayloads,
            to: targetLaneID,
            proposedOffset: proposedOffset,
            source: source
        )
        guard orderSignature != before else { return }
        LabTrace.emit(
            "store.optimistic.applied",
            fields: [
                "cards": items.map(\.id.traceValue).joined(separator: ","),
                "targetLane": targetLaneID,
            ]
        )
        scheduleReconcile(
            cardIDs: items.map(\.id),
            targetLaneID: targetLaneID
        )
    }
    func move(
        payloads: [ProductionShapeCardPayload],
        to targetLaneID: String,
        proposedOffset: Int,
        source: String
    ) {
        let cardPayloads = payloads
            .flatMap(\.items)
            .compactMap { item -> CardPayload? in
                let rawCardID = item.id.cardID
                guard
                    let lane = lanes.first(where: { lane in
                        lane.cards.contains(where: { $0.id == rawCardID })
                    }),
                    let card = lane.cards.first(where: { $0.id == rawCardID })
                else {
                    return nil
                }
                return CardPayload(card: card, sourceLaneID: item.sourceLaneID)
            }
        move(
            payloads: cardPayloads,
            to: targetLaneID,
            proposedOffset: proposedOffset,
            source: source
        )
    }

    func move(
        payloads: [EnumIdentityCardPayload],
        to targetLaneID: String,
        proposedOffset: Int,
        source: String
    ) {
        move(
            payloads: payloads.map(\.cardPayload),
            to: targetLaneID,
            proposedOffset: proposedOffset,
            source: source
        )
    }

    func move(
        payloads: [CardPayload],
        to targetLaneID: String,
        proposedOffset: Int,
        source: String
    ) {
        let uniquePayloads = payloads.reduce(into: [CardPayload]()) { result, payload in
            guard !result.contains(where: { $0.id == payload.id }) else { return }
            result.append(payload)
        }
        guard !uniquePayloads.isEmpty else {
            LabTrace.emit(
                "store.mutation.rejected",
                fields: ["reason": "empty-payload", "targetLane": targetLaneID]
            )
            return
        }
        guard let targetIndex = lanes.firstIndex(where: { $0.id == targetLaneID }) else {
            LabTrace.emit(
                "store.mutation.rejected",
                fields: ["reason": "unknown-target-lane", "targetLane": targetLaneID]
            )
            return
        }

        let draggedIDs = Set(uniquePayloads.map(\.id))
        let targetCardsBeforeRemoval = lanes[targetIndex].cards
        let clampedProposedOffset = min(max(0, proposedOffset), targetCardsBeforeRemoval.count)
        let removedBeforeOffset = targetCardsBeforeRemoval
            .prefix(clampedProposedOffset)
            .count(where: { draggedIDs.contains($0.id) })
        let before = orderSignature

        var cardsByID: [String: LabCard] = [:]
        for laneIndex in lanes.indices {
            for card in lanes[laneIndex].cards where draggedIDs.contains(card.id) {
                cardsByID[card.id] = card
            }
            lanes[laneIndex].cards.removeAll { draggedIDs.contains($0.id) }
        }

        let movedCards = uniquePayloads.map { payload in
            cardsByID[payload.id] ?? LabCard(
                id: payload.id,
                title: payload.title,
                detail: payload.detail
            )
        }
        let insertionOffset = min(
            max(0, clampedProposedOffset - removedBeforeOffset),
            lanes[targetIndex].cards.count
        )
        lanes[targetIndex].cards.insert(contentsOf: movedCards, at: insertionOffset)

        LabTrace.emit(
            "store.mutation",
            fields: [
                "after": orderSignature,
                "before": before,
                "cards": uniquePayloads.map(\.id).joined(separator: ","),
                "proposedOffset": String(proposedOffset),
                "resolvedOffset": String(insertionOffset),
                "source": source,
                "sourceLanes": uniquePayloads.map(\.sourceLaneID).joined(separator: ","),
                "targetLane": targetLaneID,
            ]
        )
    }

    func traceRenderedOrder(reason: String) {
        LabTrace.emit(
            "render.order",
            fields: [
                "reason": reason,
                "value": orderSignature,
            ]
        )
    }

    private static func lanes(for stage: LabParityStage) -> [LabLane] {
        if stage.usesFullProductionParity {
            LabBoardFixtures.fullProduction
        } else if stage.usesDenseBoard {
            LabBoardFixtures.dense
        } else {
            LabBoardFixtures.seeded
        }
    }

    private func fullParityDragItem(
        for cardID: FullParityCardID
    ) -> FullParityCardDragItem? {
        guard
            case .api(let rawCardID) = cardID,
            let sourceLane = lanes.first(where: { lane in
                lane.cards.contains(where: { $0.id == rawCardID })
            })
        else {
            return nil
        }
        if sourceLane.role == .umbrella {
            return .api(itemID: rawCardID, status: .inbox, kind: .umbrella)
        }
        guard let status = FullParityTaskBoardStatus(rawValue: sourceLane.id) else {
            return nil
        }
        return .api(itemID: rawCardID, status: status, kind: .task)
    }

    private func uniqueFullParityItems(
        for cardIDs: [FullParityCardID]
    ) -> [FullParityCardDragItem] {
        var seenIDs: Set<FullParityCardID> = []
        return cardIDs
            .compactMap(fullParityDragItem)
            .filter { seenIDs.insert($0.id).inserted }
    }

    private func uniqueFullParityItems<Payload: FullParityCardPayload>(
        in payloads: [Payload]
    ) -> [FullParityCardDragItem] {
        var seenIDs: Set<FullParityCardID> = []
        return payloads
            .flatMap(\.items)
            .filter { seenIDs.insert($0.id).inserted }
    }

    private func cardPayload(
        for item: FullParityCardDragItem
    ) -> CardPayload? {
        let rawCardID = item.id.cardID
        guard
            let lane = lanes.first(where: { lane in
                lane.cards.contains(where: { $0.id == rawCardID })
            }),
            let card = lane.cards.first(where: { $0.id == rawCardID })
        else {
            return nil
        }
        return CardPayload(card: card, sourceLaneID: item.sourceLaneID)
    }

    private func traceCandidateAcceptance(
        accepted: Bool,
        cardIDs: [FullParityCardID],
        destinationLaneID: String,
        reason: String
    ) {
        LabTrace.emit(
            "store.candidate",
            fields: [
                "accepted": String(accepted),
                "cards": cardIDs.map(\.traceValue).joined(separator: ","),
                "reason": reason,
                "targetLane": destinationLaneID,
            ]
        )
    }

    private func scheduleReconcile(
        cardIDs: [FullParityCardID],
        targetLaneID: String
    ) {
        reconcileGeneration += 1
        let generation = reconcileGeneration
        reconcileState = .scheduled(generation: generation)
        LabTrace.emit(
            "store.reconcile.scheduled",
            fields: [
                "cards": cardIDs.map(\.traceValue).joined(separator: ","),
                "generation": String(generation),
                "targetLane": targetLaneID,
            ]
        )
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard let self, self.reconcileGeneration == generation else { return }
            self.reconcileState = .idle
            LabTrace.emit(
                "store.reconcile.completed",
                fields: [
                    "generation": String(generation),
                    "targetLane": targetLaneID,
                ]
            )
            self.traceRenderedOrder(reason: "delayed-reconcile")
        }
    }

    private func cancelPendingReconcile() {
        reconcileGeneration += 1
        reconcileState = .idle
    }
}
