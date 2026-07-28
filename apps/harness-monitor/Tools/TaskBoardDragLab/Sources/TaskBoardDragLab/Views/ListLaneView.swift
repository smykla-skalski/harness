import SwiftUI

struct ListLaneView: View {
    let laneID: String
    let route: ListContentRoute
    let dragSourceMode: DragSourceMode
    let parityStage: LabParityStage
    let isDropCandidate: Bool
    let selectedCardIDs: Set<String>
    let onSelect: (String) -> Void
    let store: BoardStore

    var body: some View {
        switch route {
        case .direct:
            DirectListLaneView(
                laneID: laneID,
                dragSourceMode: dragSourceMode,
                parityStage: parityStage,
                isDropCandidate: isDropCandidate,
                selectedCardIDs: selectedCardIDs,
                onSelect: onSelect,
                store: store
            )
        case .conditionalHelper:
            ConditionalHelperListLaneView(
                laneID: laneID,
                dragSourceMode: dragSourceMode,
                parityStage: parityStage,
                isDropCandidate: isDropCandidate,
                selectedCardIDs: selectedCardIDs,
                onSelect: onSelect,
                store: store
            )
        case .productionSiblings:
            if parityStage.usesProductionPayloadShape {
                ProductionPayloadShapeListLaneView(
                    laneID: laneID,
                    dragSourceMode: dragSourceMode,
                    parityStage: parityStage,
                    isDropCandidate: isDropCandidate,
                    selectedCardIDs: selectedCardIDs,
                    onSelect: onSelect,
                    store: store
                )
            } else if parityStage.usesEnumDragIdentity {
                EnumIdentityProductionSiblingsListLaneView(
                    laneID: laneID,
                    dragSourceMode: dragSourceMode,
                    parityStage: parityStage,
                    isDropCandidate: isDropCandidate,
                    selectedCardIDs: selectedCardIDs,
                    onSelect: onSelect,
                    store: store
                )
            } else {
                ProductionSiblingsListLaneView(
                    laneID: laneID,
                    dragSourceMode: dragSourceMode,
                    parityStage: parityStage,
                    isDropCandidate: isDropCandidate,
                    selectedCardIDs: selectedCardIDs,
                    onSelect: onSelect,
                    store: store
                )
            }
        }
    }
}

private struct DirectListLaneView: View {
    let laneID: String
    let dragSourceMode: DragSourceMode
    let parityStage: LabParityStage
    let isDropCandidate: Bool
    let selectedCardIDs: Set<String>
    let onSelect: (String) -> Void
    let store: BoardStore

    private var lane: LabLane {
        store.lane(id: laneID) ?? LabLane(id: laneID, title: laneID, cards: [])
    }

    var body: some View {
        ListLaneChrome(
            lane: lane,
            route: .direct,
            parityStage: parityStage,
            isDropCandidate: isDropCandidate
        ) {
            List {
                dynamicRows
                    .dropDestination(for: CardPayload.self) { payloads, offset in
                        handleInsertion(payloads, offset: offset)
                    }

                if lane.cards.isEmpty {
                    EmptyListLaneRow(laneID: laneID, store: store)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .tracedDropTarget(
                mode: .list,
                laneID: laneID,
                target: "List/direct-DynamicViewContent",
                observesSessions: parityStage.usesDropSessionObserver,
                configuresMove: parityStage.usesExplicitDropConfiguration
            )
        }
        .onAppear {
            LabTrace.emit("list.route.appear", fields: ["lane": laneID, "route": "direct"])
            store.traceRenderedOrder(reason: "List direct lane \(laneID) appeared")
        }
    }

    private var dynamicRows: some DynamicViewContent {
        ForEach(lane.cards) { card in
            ListCardRow(
                card: card,
                laneID: laneID,
                dragSourceMode: dragSourceMode,
                parityStage: parityStage,
                isSelected: selectedCardIDs.contains(card.id),
                onSelect: onSelect
            )
        }
    }

    private func handleInsertion(_ payloads: [CardPayload], offset: Int) {
        LabTrace.emit(
            "list.direct.insertion",
            fields: [
                "cards": payloads.map(\.id).joined(separator: ","),
                "lane": laneID,
                "offset": String(offset),
            ]
        )
        store.move(
            payloads: payloads,
            to: laneID,
            proposedOffset: offset,
            source: "List.direct.DynamicViewContent"
        )
    }
}

private struct ConditionalHelperListLaneView: View {
    let laneID: String
    let dragSourceMode: DragSourceMode
    let parityStage: LabParityStage
    let isDropCandidate: Bool
    let selectedCardIDs: Set<String>
    let onSelect: (String) -> Void
    let store: BoardStore

    private var lane: LabLane {
        store.lane(id: laneID) ?? LabLane(id: laneID, title: laneID, cards: [])
    }

    var body: some View {
        ListLaneChrome(
            lane: lane,
            route: .conditionalHelper,
            parityStage: parityStage,
            isDropCandidate: isDropCandidate
        ) {
            List {
                conditionalRows
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .tracedDropTarget(
                mode: .list,
                laneID: laneID,
                target: "List/conditional-helper",
                observesSessions: parityStage.usesDropSessionObserver,
                configuresMove: parityStage.usesExplicitDropConfiguration
            )
        }
        .onAppear {
            LabTrace.emit(
                "list.route.appear",
                fields: ["lane": laneID, "route": "conditional-helper"]
            )
            store.traceRenderedOrder(reason: "List conditional-helper lane \(laneID) appeared")
        }
    }

    @ViewBuilder private var conditionalRows: some View {
        if laneID == "__non_insertable_control_lane__" {
            dynamicRows
        } else {
            dynamicRows
                .dropDestination(for: CardPayload.self) { payloads, offset in
                    handleInsertion(payloads, offset: offset)
                }
        }

        if lane.cards.isEmpty {
            EmptyListLaneRow(laneID: laneID, store: store)
        }
    }

    private var dynamicRows: some DynamicViewContent {
        ForEach(lane.cards) { card in
            ListCardRow(
                card: card,
                laneID: laneID,
                dragSourceMode: dragSourceMode,
                parityStage: parityStage,
                isSelected: selectedCardIDs.contains(card.id),
                onSelect: onSelect
            )
        }
    }

    private func handleInsertion(_ payloads: [CardPayload], offset: Int) {
        LabTrace.emit(
            "list.helper.insertion",
            fields: [
                "cards": payloads.map(\.id).joined(separator: ","),
                "lane": laneID,
                "offset": String(offset),
            ]
        )
        store.move(
            payloads: payloads,
            to: laneID,
            proposedOffset: offset,
            source: "List.conditional-helper.DynamicViewContent"
        )
    }
}

private struct ProductionSiblingsListLaneView: View {
    let laneID: String
    let dragSourceMode: DragSourceMode
    let parityStage: LabParityStage
    let isDropCandidate: Bool
    let selectedCardIDs: Set<String>
    let onSelect: (String) -> Void
    let store: BoardStore

    private var lane: LabLane {
        store.lane(id: laneID) ?? LabLane(id: laneID, title: laneID, cards: [])
    }

    var body: some View {
        ListLaneChrome(
            lane: lane,
            route: .productionSiblings,
            parityStage: parityStage,
            isDropCandidate: isDropCandidate
        ) {
            styleList(
                List {
                    decisionRows
                    droppableRows
                    inboxRows
                }
            )
        }
        .onAppear {
            LabTrace.emit(
                "list.route.appear",
                fields: ["lane": laneID, "route": "production-siblings"]
            )
            store.traceRenderedOrder(reason: "List production-siblings lane \(laneID) appeared")
        }
    }

    @ViewBuilder private var decisionRows: some View {
        ForEach([String](), id: \.self) { value in
            Text(value)
        }
    }

    private var droppableRows: some DynamicViewContent {
        apiRows
            .dropDestination(for: CardPayload.self) { payloads, offset in
                LabTrace.emit(
                    "list.production-siblings.insertion",
                    fields: [
                        "cards": payloads.map(\.id).joined(separator: ","),
                        "lane": laneID,
                        "offset": String(offset),
                    ]
                )
                store.move(
                    payloads: payloads,
                    to: laneID,
                    proposedOffset: offset,
                    source: "List.production-siblings.DynamicViewContent"
                )
            }
    }

    private var apiRows: some DynamicViewContent {
        ForEach(lane.cards) { card in
            ListCardRow(
                card: card,
                laneID: laneID,
                dragSourceMode: dragSourceMode,
                parityStage: parityStage,
                isSelected: selectedCardIDs.contains(card.id),
                onSelect: onSelect
            )
        }
    }

    @ViewBuilder private var inboxRows: some View {
        ForEach([String](), id: \.self) { value in
            Text(value)
        }
    }

    private func styleList<Content: View>(_ content: Content) -> some View {
        let styled = content
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
            .scrollBounceBehavior(.basedOnSize)

        return outerDropTarget(styled)
    }

    @ViewBuilder
    private func outerDropTarget<Content: View>(_ content: Content) -> some View {
        if parityStage.usesOuterDropWrapper {
            content.tracedDropTarget(
                mode: .list,
                laneID: laneID,
                target: "List/production-siblings",
                observesSessions: parityStage.usesDropSessionObserver,
                configuresMove: parityStage.usesExplicitDropConfiguration
            )
        } else {
            content
        }
    }
}

private struct EnumIdentityProductionSiblingsListLaneView: View {
    let laneID: String
    let dragSourceMode: DragSourceMode
    let parityStage: LabParityStage
    let isDropCandidate: Bool
    let selectedCardIDs: Set<String>
    let onSelect: (String) -> Void
    let store: BoardStore

    private var lane: LabLane {
        store.lane(id: laneID) ?? LabLane(id: laneID, title: laneID, cards: [])
    }

    var body: some View {
        ListLaneChrome(
            lane: lane,
            route: .productionSiblings,
            parityStage: parityStage,
            isDropCandidate: isDropCandidate
        ) {
            styleList(
                List {
                    decisionRows
                    droppableRows
                    inboxRows
                }
            )
        }
        .onAppear {
            LabTrace.emit(
                "list.route.appear",
                fields: [
                    "identity": "enum",
                    "lane": laneID,
                    "route": "production-siblings",
                ]
            )
            store.traceRenderedOrder(
                reason: "List enum-identity production-siblings lane \(laneID) appeared"
            )
        }
    }

    @ViewBuilder private var decisionRows: some View {
        ForEach([String](), id: \.self) { value in
            Text(value)
        }
    }

    private var droppableRows: some DynamicViewContent {
        apiRows
            .dropDestination(for: EnumIdentityCardPayload.self) { payloads, offset in
                LabTrace.emit(
                    "list.production-siblings.insertion",
                    fields: [
                        "cards": payloads.map(\.id.traceValue).joined(separator: ","),
                        "identity": "enum",
                        "lane": laneID,
                        "offset": String(offset),
                    ]
                )
                store.move(
                    payloads: payloads,
                    to: laneID,
                    proposedOffset: offset,
                    source: "List.production-siblings.DynamicViewContent.enum-identity"
                )
            }
    }

    private var apiRows: some DynamicViewContent {
        ForEach(lane.cards) { card in
            ListCardRow(
                card: card,
                laneID: laneID,
                dragSourceMode: dragSourceMode,
                parityStage: parityStage,
                isSelected: selectedCardIDs.contains(card.id),
                onSelect: onSelect
            )
        }
    }

    @ViewBuilder private var inboxRows: some View {
        ForEach([String](), id: \.self) { value in
            Text(value)
        }
    }

    private func styleList<Content: View>(_ content: Content) -> some View {
        let styled = content
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
            .scrollBounceBehavior(.basedOnSize)

        return outerDropTarget(styled)
    }

    @ViewBuilder
    private func outerDropTarget<Content: View>(_ content: Content) -> some View {
        if parityStage.usesOuterDropWrapper {
            content.tracedDropTarget(
                mode: .list,
                laneID: laneID,
                target: "List/production-siblings",
                observesSessions: parityStage.usesDropSessionObserver,
                configuresMove: parityStage.usesExplicitDropConfiguration
            )
        } else {
            content
        }
    }
}

private struct ProductionPayloadShapeListLaneView: View {
    let laneID: String
    let dragSourceMode: DragSourceMode
    let parityStage: LabParityStage
    let isDropCandidate: Bool
    let selectedCardIDs: Set<String>
    let onSelect: (String) -> Void
    let store: BoardStore

    private var lane: LabLane {
        store.lane(id: laneID) ?? LabLane(id: laneID, title: laneID, cards: [])
    }

    var body: some View {
        ListLaneChrome(
            lane: lane,
            route: .productionSiblings,
            parityStage: parityStage,
            isDropCandidate: isDropCandidate
        ) {
            styleList(
                List {
                    decisionRows
                    droppableRows
                    inboxRows
                }
            )
        }
        .onAppear {
            LabTrace.emit(
                "list.route.appear",
                fields: [
                    "identity": "enum",
                    "lane": laneID,
                    "payload": "production-shape",
                    "route": "production-siblings",
                ]
            )
            store.traceRenderedOrder(
                reason: "List production-payload production-siblings lane \(laneID) appeared"
            )
        }
    }

    @ViewBuilder private var decisionRows: some View {
        ForEach([String](), id: \.self) { value in
            Text(value)
        }
    }

    private var droppableRows: some DynamicViewContent {
        apiRows
            .dropDestination(for: ProductionShapeCardPayload.self) { payloads, offset in
                LabTrace.emit(
                    "list.production-siblings.insertion",
                    fields: [
                        "cards": payloads.map(\.id.traceValue).joined(separator: ","),
                        "identity": "enum",
                        "lane": laneID,
                        "offset": String(offset),
                        "payload": "production-shape",
                    ]
                )
                store.move(
                    payloads: payloads,
                    to: laneID,
                    proposedOffset: offset,
                    source: "List.production-siblings.DynamicViewContent.production-payload"
                )
            }
    }

    private var apiRows: some DynamicViewContent {
        ForEach(lane.cards) { card in
            ListCardRow(
                card: card,
                laneID: laneID,
                dragSourceMode: dragSourceMode,
                parityStage: parityStage,
                isSelected: selectedCardIDs.contains(card.id),
                onSelect: onSelect
            )
        }
    }

    @ViewBuilder private var inboxRows: some View {
        ForEach([String](), id: \.self) { value in
            Text(value)
        }
    }

    private func styleList<Content: View>(_ content: Content) -> some View {
        let styled = content
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
            .scrollBounceBehavior(.basedOnSize)

        return outerDropTarget(styled)
    }

    @ViewBuilder
    private func outerDropTarget<Content: View>(_ content: Content) -> some View {
        if parityStage.usesOuterDropWrapper {
            content.tracedDropTarget(
                mode: .list,
                laneID: laneID,
                target: "List/production-siblings",
                observesSessions: parityStage.usesDropSessionObserver,
                configuresMove: parityStage.usesExplicitDropConfiguration
            )
        } else {
            content
        }
    }
}

private struct ListLaneChrome<Content: View>: View {
    let lane: LabLane
    let route: ListContentRoute
    let parityStage: LabParityStage
    let isDropCandidate: Bool
    @ViewBuilder let content: Content
    @State private var hoverTracking = LabLaneHoverTracking()

    private var hoverCoordinateSpace: String {
        "task-board-drag-lab.lane.\(lane.id)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LaneHeaderView(lane: lane, mode: .list)

            Text(route.rawValue)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            content
                .environment(hoverTracking)
                .coordinateSpace(.named(hoverCoordinateSpace))
                .onContinuousHover(coordinateSpace: .named(hoverCoordinateSpace)) { phase in
                    guard parityStage.usesHoverGeometry else { return }
                    hoverTracking.update(phase)
                }
        }
        .padding(12)
        .frame(width: parityStage.usesCustomLaneLayout ? 420 : 320)
        .frame(maxHeight: .infinity)
        .background(
            isDropCandidate ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08),
            in: .rect(cornerRadius: 14)
        )
        .animation(.easeOut(duration: 0.14), value: isDropCandidate)
    }
}

private struct ListCardRow: View {
    let card: LabCard
    let laneID: String
    let dragSourceMode: DragSourceMode
    let parityStage: LabParityStage
    let isSelected: Bool
    let onSelect: (String) -> Void
    @Environment(LabLaneHoverTracking.self)
    private var hoverTracking

    private var hoverCoordinateSpace: String {
        "task-board-drag-lab.lane.\(laneID)"
    }

    var body: some View {
        DraggableCardView(
            card: card,
            laneID: laneID,
            dragSourceMode: dragSourceMode,
            parityStage: parityStage,
            isSelected: isSelected,
            isHovered: parityStage.usesHoverGeometry
                && hoverTracking.hoveredCardID == card.id,
            onSelect: onSelect
        )
            .labTrackedCardFrame(
                cardID: card.id,
                coordinateSpace: hoverCoordinateSpace,
                isEnabled: parityStage.usesHoverGeometry,
                tracking: hoverTracking
            )
            .listRowInsets(
                EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

private struct EmptyListLaneRow: View {
    let laneID: String
    let store: BoardStore

    var body: some View {
        EmptyLaneDropTarget(mode: .list, laneID: laneID, store: store)
            .listRowInsets(
                EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
