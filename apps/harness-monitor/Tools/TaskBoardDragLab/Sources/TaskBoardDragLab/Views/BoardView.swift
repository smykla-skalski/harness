import SwiftUI
import TaskBoardDragLabTransfer

struct BoardView: View {
    let mode: BoardMode
    let listContentRoute: ListContentRoute
    let dragSourceMode: DragSourceMode
    let parityStage: LabParityStage
    let store: BoardStore
    @State private var selectedCardIDs: [String] = []
    @State private var selectedEnumCardIDs: [LabCardDragID] = []
    @State private var draggedCardIDs: [String] = []
    @State private var candidateLaneIDs: Set<String> = []

    @ViewBuilder
    var body: some View {
        if parityStage.usesFullProductionParity {
            FullParityHost {
                if parityStage.usesBuiltInJSONTransfer {
                    FullParityBoardView<FullParityJSONPayload>(
                        store: store,
                        usesScrollLanes: parityStage.usesFullProductionScrollView,
                        usesExplicitScrollDropTargets:
                            parityStage.usesExplicitScrollDropTargets,
                        usesStableExplicitScrollDropTargets:
                            parityStage.usesStableExplicitScrollDropTargets
                    )
                } else {
                    FullParityBoardView<FullParityCustomPayload>(
                        store: store,
                        usesScrollLanes: parityStage.usesFullProductionScrollView,
                        usesExplicitScrollDropTargets:
                            parityStage.usesExplicitScrollDropTargets,
                        usesStableExplicitScrollDropTargets:
                            parityStage.usesStableExplicitScrollDropTargets
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if parityStage.usesDashboardVerticalScroll {
            ScrollView(.vertical) {
                configuredBoard
                    .frame(height: 704)
                    .padding(.vertical, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        } else {
            configuredBoard
        }
    }

    private var configuredBoard: some View {
        dragContainerBoard
            .dragConfiguration(DragConfiguration(allowMove: true))
            .dragPreviewsFormation(.pile)
            .onDragSessionUpdated { session in
                LabTrace.boardDragSession(
                    session,
                    usesEnumDragIdentity: parityStage.usesEnumDragIdentity,
                    readsIDsOnlyInitially: parityStage.usesInitialOnlyDragLifecycle
                )
                updateProductionDragState(session)
            }
            .onChange(of: parityStage) {
                selectedCardIDs = []
                selectedEnumCardIDs = []
                draggedCardIDs = []
                candidateLaneIDs = []
            }
    }

    @ViewBuilder private var dragContainerBoard: some View {
        if dragSourceMode == .container {
            if parityStage.usesProductionPayloadShape {
                laneStrip
                    .dragContainer(
                        for: ProductionShapeCardPayload.self,
                        itemID: \.id
                    ) { cardIDs in
                        store.productionShapeDragPayloads(for: cardIDs)
                    }
                    .dragContainerSelection(selectedEnumCardIDs)
            } else if parityStage.usesEnumDragIdentity {
                laneStrip
                    .dragContainer(
                        for: EnumIdentityCardPayload.self,
                        itemID: \.id
                    ) { cardIDs in
                        store.enumIdentityDragPayloads(for: cardIDs)
                    }
                    .dragContainerSelection(selectedEnumCardIDs)
            } else if parityStage.usesContainerSelection {
                laneStrip
                    .dragContainer(for: CardPayload.self, itemID: \.id) { cardIDs in
                        store.dragPayloads(for: cardIDs)
                    }
                    .dragContainerSelection(selectedCardIDs)
            } else {
                laneStrip
                    .dragContainer(for: CardPayload.self, itemID: \.id) { cardIDs in
                        store.dragPayloads(for: cardIDs)
                    }
            }
        } else {
            laneStrip
        }
    }

    private var laneStrip: some View {
        ScrollView(.horizontal) {
            laneCollection
                .padding()
        }
        .scrollClipDisabled(parityStage.clipsDestinationLane)
        .frame(
            maxWidth: parityStage.clipsDestinationLane
                ? (parityStage.clipsPlanningByProductionAmount ? 1_280 : 1_324)
                : .infinity
        )
    }

    @ViewBuilder private var laneCollection: some View {
        if parityStage.usesCustomLaneLayout {
            LabLaneStripLayout(spacing: 16) {
                laneViews
            }
        } else {
            HStack(alignment: .top, spacing: 16) {
                laneViews
            }
        }
    }

    @ViewBuilder private var laneViews: some View {
        ForEach(store.lanes) { lane in
            switch mode {
            case .list:
                ListLaneView(
                    laneID: lane.id,
                    route: parityStage.usesProductionSiblings
                        ? .productionSiblings
                        : listContentRoute,
                    dragSourceMode: dragSourceMode,
                    parityStage: parityStage,
                    isDropCandidate: candidateLaneIDs.contains(lane.id),
                    selectedCardIDs: visibleSelectedCardIDs,
                    onSelect: selectCard,
                    store: store
                )
            case .lazyVStack:
                LazyLaneView(
                    laneID: lane.id,
                    dragSourceMode: dragSourceMode,
                    store: store
                )
            }
        }
    }

    private func selectCard(_ cardID: String) {
        guard parityStage.usesContainerSelection else { return }
        if parityStage.usesEnumDragIdentity {
            selectedEnumCardIDs = [.api(cardID)]
        } else {
            selectedCardIDs = [cardID]
        }
    }

    private func updateProductionDragState(_ session: DragSession) {
        guard parityStage.mutatesStateAtDragStart else { return }
        if parityStage.usesInitialOnlyDragLifecycle {
            updateInitialOnlyDragState(session)
            return
        }
        switch session.phase {
        case .initial, .active:
            let cardIDs =
                if parityStage.usesEnumDragIdentity {
                    session
                        .draggedItemIDs(for: LabCardDragID.self)
                        .map(\.cardID)
                } else {
                    session.draggedItemIDs(for: String.self)
                }
            guard !cardIDs.isEmpty else { return }
            if draggedCardIDs != cardIDs {
                draggedCardIDs = cardIDs
                candidateLaneIDs = Set(store.lanes.map(\.id))
                LabTrace.emit(
                    "production.drag-state",
                    fields: [
                        "candidates": candidateLaneIDs.sorted().joined(separator: ","),
                        "cards": cardIDs.joined(separator: ","),
                        "phase": session.phase.description,
                    ]
                )
            }
            if case .initial = session.phase {
                if parityStage.usesEnumDragIdentity {
                    selectedEnumCardIDs = cardIDs.map(LabCardDragID.api)
                } else {
                    selectedCardIDs = cardIDs
                }
            }
        case .ended, .dataTransferCompleted:
            draggedCardIDs = []
            candidateLaneIDs = []
        @unknown default:
            draggedCardIDs = []
            candidateLaneIDs = []
        }
    }

    private func updateInitialOnlyDragState(_ session: DragSession) {
        switch session.phase {
        case .initial:
            let enumCardIDs = session.draggedItemIDs(for: LabCardDragID.self)
            let cardIDs = enumCardIDs.map(\.cardID)
            guard !cardIDs.isEmpty else { return }
            draggedCardIDs = cardIDs
            selectedEnumCardIDs = enumCardIDs
            candidateLaneIDs = Set(store.lanes.map(\.id))
            LabTrace.emit(
                "production.drag-state",
                fields: [
                    "candidates": candidateLaneIDs.sorted().joined(separator: ","),
                    "cards": cardIDs.joined(separator: ","),
                    "lifecycle": "initial-only",
                    "phase": session.phase.description,
                ]
            )
        case .active:
            break
        case .ended, .dataTransferCompleted:
            draggedCardIDs = []
            candidateLaneIDs = []
        @unknown default:
            draggedCardIDs = []
            candidateLaneIDs = []
        }
    }

    private var visibleSelectedCardIDs: Set<String> {
        if parityStage.usesEnumDragIdentity {
            Set(selectedEnumCardIDs.map(\.cardID))
        } else {
            Set(selectedCardIDs)
        }
    }
}

private struct LabLaneStripLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return CGSize(
            width: sizes.map(\.width).reduce(0, +)
                + spacing * CGFloat(max(0, sizes.count - 1)),
            height: max(proposal.height ?? 0, sizes.map(\.height).max() ?? 0)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        var x = bounds.minX
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: bounds.height)
            )
            x += size.width + spacing
        }
    }
}
