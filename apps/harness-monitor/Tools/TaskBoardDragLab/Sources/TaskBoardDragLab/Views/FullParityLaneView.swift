import SwiftUI
import SwiftUIIntrospect
import TaskBoardDragLabTransfer

struct FullParityLaneView<Payload: FullParityCardPayload>: View {
    let lane: LabLane
    let usesScrollLane: Bool
    let usesExplicitScrollDropTargets: Bool
    let usesStableExplicitScrollDropTargets: Bool
    let selectionModel: FullParitySelectionModel
    let dragRuntime: FullParityDragRuntime
    let dropHighlightState: FullParityLaneDropHighlightState
    let nativeListCoordinator: FullParityNativeListCoordinator
    let insertionState: FullParityLaneInsertionState
    let insertionIndicator: FullParityInsertionIndicatorCoordinator
    let onDrop: ([Payload], Int) -> Bool
    @State private var hoverTracking = LabLaneHoverTracking()

    private var coordinateSpaceName: String {
        "task-board-drag-lab.full-parity.\(lane.id)"
    }

    var body: some View {
        laneContent
            .frame(
                minWidth: lane.fullParityIsCollapsed ? 72 : 420,
                idealWidth: lane.fullParityIsCollapsed ? 72 : 420,
                maxWidth: lane.fullParityIsCollapsed ? 72 : .infinity,
                minHeight: 704,
                idealHeight: 704,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .background(.secondary.opacity(0.07), in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        .secondary.opacity(0.18),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .overlay {
                FullParityLaneDropHighlight(
                    state: dropHighlightState,
                    color: laneColor
                )
            }
            .overlay(alignment: .top) {
                UnevenRoundedRectangle(
                    topLeadingRadius: 10,
                    bottomLeadingRadius: 3,
                    bottomTrailingRadius: 3,
                    topTrailingRadius: 10
                )
                .fill(laneColor)
                .frame(height: 8)
                .allowsHitTesting(false)
            }
            .coordinateSpace(.named(coordinateSpaceName))
            .contentShape(.rect)
            .onDropSessionUpdated(handleDropSession)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("task-board-drag-lab.lane.\(lane.id)")
            .onAppear {
                LabTrace.emit(
                    "full-parity.lane.appear",
                    fields: [
                        "cards": String(lane.cards.count),
                        "collapsed": String(lane.fullParityIsCollapsed),
                        "lane": lane.id,
                        "umbrella": String(lane.fullParityIsUmbrella),
                    ]
                )
            }
            .task(id: lane.cards.map(\.id)) {
                nativeListCoordinator.revealPendingCard(
                    in: lane.id,
                    cardIDs: lane.cards.map(\.id),
                    leadingRowCount: lane.fullParityHasDecisionRows ? 1 : 0
                )
            }
    }

    @ViewBuilder private var laneContent: some View {
        if lane.fullParityIsCollapsed {
            collapsedLane
        } else {
            expandedLane
        }
    }

    @ViewBuilder private var collapsedLane: some View {
        let content = FullParityCollapsedLane(lane: lane)
        if lane.fullParityIsUmbrella {
            content
        } else {
            content.fullParityFallbackDropDestination(
                for: Payload.self,
                insertionOffset: lane.cards.count,
                action: onDrop
            )
        }
    }

    private var expandedLane: some View {
        VStack(alignment: .leading, spacing: 0) {
            FullParityLaneHeader(lane: lane)
            Group {
                if hasAnyContent {
                    laneListDropSurface
                } else {
                    FullParityEmptyLane(lane: lane)
                        .padding(12)
                        .fullParityFallbackDropDestination(
                            for: Payload.self,
                            insertionOffset: 0,
                            action: onDrop
                        )
                }
            }
            .background(.background.opacity(0.3))
        }
    }

    @ViewBuilder private var laneListDropSurface: some View {
        if !lane.fullParityIsUmbrella, lane.cards.isEmpty {
            styledLaneContent.fullParityFallbackDropDestination(
                for: Payload.self,
                insertionOffset: 0,
                action: onDrop
            )
        } else {
            styledLaneContent
        }
    }

    @ViewBuilder private var styledLaneContent: some View {
        if usesScrollLane {
            styledLaneScroll
        } else {
            styledLaneList
        }
    }

    @ViewBuilder private var styledLaneList: some View {
        if lane.fullParityIsUmbrella {
            style(
                List {
                    listRowsContent
                }
            )
        } else {
            style(
                List {
                    droppableListRowsContent
                }
            )
        }
    }

    private var styledLaneScroll: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(
                spacing: usesStableExplicitScrollDropTargets ? 0 : 8
            ) {
                decisionRows
                if lane.fullParityIsUmbrella {
                    apiRows
                } else if usesExplicitScrollDropTargets {
                    explicitDropRows
                } else {
                    droppableAPIRows
                }
                inboxRows
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onContinuousHover(coordinateSpace: .named(coordinateSpaceName)) { phase in
            hoverTracking.update(phase)
        }
    }

    private func style<Content: View>(_ content: Content) -> some View {
        content
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
            .contentMargins(.top, 8, for: .scrollContent)
            .contentMargins(.bottom, 8, for: .scrollContent)
            .scrollBounceBehavior(.basedOnSize)
            .introspect(.list, on: .macOS(.v26)) { tableView in
                nativeListCoordinator.register(tableView, laneID: lane.id)
            }
            .dropConfiguration { session in
                guard dragRuntime.accepts(laneID: lane.id) else {
                    return DropConfiguration(operation: .forbidden)
                }
                let operation: DropOperation =
                    session.suggestedOperations.contains(.move) ? .move : .copy
                return DropConfiguration(operation: operation)
            }
            .onContinuousHover(coordinateSpace: .named(coordinateSpaceName)) { phase in
                guard !dragRuntime.isActive else { return }
                hoverTracking.update(phase)
            }
    }

    private var apiRows: some DynamicViewContent {
        ForEach(lane.cards) { card in
            apiRow(card)
        }
    }

    private var listRowsContent: some DynamicViewContent {
        ForEach(fullParityListRows) { row in
            fullParityListRow(row)
            .listRowInsets(
                EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    private var droppableListRowsContent: some DynamicViewContent {
        listRowsContent.dropDestination(for: Payload.self) { payloads, rowOffset in
            let insertionOffset = fullParityListRows
                .prefix(rowOffset)
                .count(where: \.isCard)
            LabTrace.emit(
                "full-parity.indexed-destination",
                fields: [
                    "lane": lane.id,
                    "offset": String(insertionOffset),
                    "payloads": String(payloads.count),
                    "representation": String(describing: Payload.self),
                    "rowOffset": String(rowOffset),
                ]
            )
            _ = onDrop(payloads, insertionOffset)
        }
    }

    private var droppableAPIRows: some DynamicViewContent {
        apiRows.dropDestination(for: Payload.self) { payloads, insertionOffset in
            LabTrace.emit(
                "full-parity.indexed-destination",
                fields: [
                    "lane": lane.id,
                    "offset": String(insertionOffset),
                    "payloads": String(payloads.count),
                    "representation": String(describing: Payload.self),
                ]
            )
            _ = onDrop(payloads, insertionOffset)
        }
    }

    private var fullParityListRows: [FullParityListRow] {
        var rows: [FullParityListRow] = []
        if lane.fullParityHasDecisionRows {
            rows.append(.decision)
        }
        rows.append(contentsOf: lane.cards.map(FullParityListRow.card))
        if lane.fullParityHasInboxRows {
            rows.append(.inbox)
        }
        return rows
    }

    @ViewBuilder
    private func fullParityListRow(_ row: FullParityListRow) -> some View {
        switch row {
        case .decision:
            FullParityAuxiliaryRow(
                title: "Decision awaiting your input",
                detail: "Production decision-row sibling",
                systemImage: "person.crop.circle.badge.exclamationmark",
                usesListRowStyle: false
            )
        case .card(let card):
            apiRow(card, usesListRowStyle: false)
        case .inbox:
            FullParityAuxiliaryRow(
                title: "Live session work item",
                detail: "Production inbox-row sibling",
                systemImage: "bolt.horizontal.circle",
                usesListRowStyle: false
            )
        }
    }

    func apiRow(
        _ card: LabCard,
        usesListRowStyle: Bool? = nil
    ) -> some View {
        FullParityCardRow<Payload>(
            card: card,
            lane: lane,
            selectionModel: selectionModel,
            hoverTracking: hoverTracking,
            coordinateSpaceName: coordinateSpaceName,
            nativeListCoordinator: nativeListCoordinator,
            usesListRowStyle: usesListRowStyle ?? !usesScrollLane
        )
    }

    @ViewBuilder private var decisionRows: some View {
        if lane.fullParityHasDecisionRows {
            FullParityAuxiliaryRow(
                title: "Decision awaiting your input",
                detail: "Production decision-row sibling",
                systemImage: "person.crop.circle.badge.exclamationmark",
                usesListRowStyle: !usesScrollLane
            )
        }
    }

    @ViewBuilder private var inboxRows: some View {
        if lane.fullParityHasInboxRows {
            FullParityAuxiliaryRow(
                title: "Live session work item",
                detail: "Production inbox-row sibling",
                systemImage: "bolt.horizontal.circle",
                usesListRowStyle: !usesScrollLane
            )
        }
    }

    private var hasAnyContent: Bool {
        !lane.cards.isEmpty || lane.fullParityHasDecisionRows || lane.fullParityHasInboxRows
    }

    var laneColor: Color {
        switch lane.id {
        case "todo": .blue
        case "planning": .purple
        case "in_progress": .orange
        case "failed": .red
        case "human_required": .pink
        default: .teal
        }
    }

    private func handleDropSession(_ session: DropSession) {
        guard dragRuntime.accepts(laneID: lane.id) else {
            dragRuntime.setTargeted(false, laneID: lane.id)
            return
        }
        let targeted = switch session.phase {
        case .entering, .active:
            true
        case .exiting, .ended, .dataTransferCompleted:
            false
        @unknown default:
            false
        }
        dragRuntime.setTargeted(targeted, laneID: lane.id)
        switch session.phase {
        case .exiting:
            insertionIndicator.clear(
                laneID: lane.id,
                sessionID: session.id,
                reason: "lane-exited"
            )
        case .ended, .dataTransferCompleted:
            break
        case .entering, .active:
            break
        @unknown default:
            insertionIndicator.clear(
                laneID: lane.id,
                sessionID: session.id,
                reason: "lane-phase-unknown"
            )
        }
    }

}

private struct FullParityLaneDropHighlight: View {
    let state: FullParityLaneDropHighlightState
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(state.isTargeted ? color.opacity(0.16) : .clear)
            .strokeBorder(
                state.isTargeted ? color.opacity(0.7) : .clear,
                lineWidth: 2
            )
            .allowsHitTesting(false)
    }
}

private enum FullParityListRow: Identifiable {
    enum ID: Hashable {
        case decision
        case card(String)
        case inbox
    }

    case decision
    case card(LabCard)
    case inbox

    var id: ID {
        switch self {
        case .decision:
            .decision
        case .card(let card):
            .card(card.id)
        case .inbox:
            .inbox
        }
    }

    var isCard: Bool {
        if case .card = self {
            true
        } else {
            false
        }
    }
}

private struct FullParityFallbackDropDestination<Payload: FullParityCardPayload>: ViewModifier {
    let insertionOffset: Int
    let action: ([Payload], Int) -> Bool

    func body(content: Content) -> some View {
        content.dropDestination(for: Payload.self) { payloads, _ in
            LabTrace.emit(
                "full-parity.fallback-destination",
                fields: [
                    "offset": String(insertionOffset),
                    "payloads": String(payloads.count),
                    "representation": String(describing: Payload.self),
                ]
            )
            _ = action(payloads, insertionOffset)
        }
    }
}

private extension View {
    func fullParityFallbackDropDestination<Payload: FullParityCardPayload>(
        for _: Payload.Type,
        insertionOffset: Int,
        action: @escaping ([Payload], Int) -> Bool
    ) -> some View {
        modifier(
            FullParityFallbackDropDestination(
                insertionOffset: insertionOffset,
                action: action
            )
        )
    }
}

private struct FullParityLaneHeader: View {
    let lane: LabLane

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 18)
            Text(lane.title)
                .font(.headline)
            Spacer(minLength: 0)
            Text("\(lane.cards.count)")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.secondary.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var symbol: String {
        switch lane.id {
        case "todo": "tray.and.arrow.down"
        case "planning": "list.clipboard"
        case "in_progress": "arrow.triangle.2.circlepath"
        case "failed": "exclamationmark.triangle"
        default: "tray"
        }
    }
}

private struct FullParityCollapsedLane: View {
    let lane: LabLane

    var body: some View {
        VStack(spacing: 12) {
            Text("\(lane.cards.count)")
                .font(.headline)
                .frame(width: 34, height: 34)
                .background(.secondary.opacity(0.12), in: Circle())
            Text(lane.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .rotationEffect(.degrees(90))
                .frame(width: 28, height: 160)
        }
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityLabel("\(lane.title), \(lane.cards.count) cards, collapsed")
    }
}

private struct FullParityEmptyLane: View {
    let lane: LabLane

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
            Text("Nothing here")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 92)
        .accessibilityLabel("\(lane.title) lane empty")
    }
}

private struct FullParityAuxiliaryRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let usesListRowStyle: Bool

    @ViewBuilder
    var body: some View {
        let content = HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.06), in: .rect(cornerRadius: 10))

        if usesListRowStyle {
            content
                .listRowInsets(
                    EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        } else {
            content
        }
    }
}
