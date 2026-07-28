import SwiftUI

struct LazyLaneView: View {
    let laneID: String
    let dragSourceMode: DragSourceMode
    let store: BoardStore

    private var lane: LabLane {
        store.lane(id: laneID) ?? LabLane(id: laneID, title: laneID, cards: [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LaneHeaderView(lane: lane, mode: .lazyVStack)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(lane.cards.enumerated()), id: \.element.id) { offset, card in
                        lazyDropCard(card: card, offset: offset)
                    }

                    LaneEndDropTarget(laneID: laneID, store: store)
                }
                .padding(8)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(12)
        .frame(width: 320)
        .frame(maxHeight: .infinity)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 14))
        .onAppear {
            store.traceRenderedOrder(reason: "LazyVStack lane \(laneID) appeared")
        }
    }

    private func lazyDropCard(card: LabCard, offset: Int) -> some View {
        DraggableCardView(
            card: card,
            laneID: laneID,
            dragSourceMode: dragSourceMode
        )
            .dropDestination(for: CardPayload.self) { payloads, session in
                let upperHalf = session.size.height <= 0
                    || session.location.y <= session.size.height / 2
                let insertionOffset = upperHalf ? offset : offset + 1
                LabTrace.dropSession(
                    session,
                    mode: .lazyVStack,
                    laneID: laneID,
                    target: "row:\(card.id)",
                    event: "lazy.insertion.session"
                )
                LabTrace.emit(
                    "lazy.insertion",
                    fields: [
                        "cards": payloads.map(\.id).joined(separator: ","),
                        "half": upperHalf ? "upper" : "lower",
                        "lane": laneID,
                        "offset": String(insertionOffset),
                        "row": card.id,
                    ]
                )
                store.move(
                    payloads: payloads,
                    to: laneID,
                    proposedOffset: insertionOffset,
                    source: "LazyVStack.row"
                )
            }
            .tracedDropTarget(
                mode: .lazyVStack,
                laneID: laneID,
                target: "row:\(card.id)"
            )
    }
}

private struct LaneEndDropTarget: View {
    let laneID: String
    let store: BoardStore

    var body: some View {
        Label("Drop at end", systemImage: "arrow.down.to.line")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(.quinary, in: .rect(cornerRadius: 8))
            .dropDestination(for: CardPayload.self) { payloads, session in
                LabTrace.dropSession(
                    session,
                    mode: .lazyVStack,
                    laneID: laneID,
                    target: "lane-end",
                    event: "lazy.end.session"
                )
                let offset = store.lane(id: laneID)?.cards.count ?? 0
                LabTrace.emit(
                    "lazy.end.insertion",
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
                    source: "LazyVStack.end"
                )
            }
            .tracedDropTarget(
                mode: .lazyVStack,
                laneID: laneID,
                target: "lane-end"
            )
    }
}

struct EmptyLaneDropTarget: View {
    let mode: BoardMode
    let laneID: String
    let store: BoardStore

    var body: some View {
        ContentUnavailableView(
            "Empty lane",
            systemImage: "tray",
            description: Text("Drop a card here")
        )
        .frame(maxWidth: .infinity, minHeight: 120)
        .dropDestination(for: CardPayload.self) { payloads, session in
            LabTrace.dropSession(
                session,
                mode: mode,
                laneID: laneID,
                target: "empty-lane",
                event: "empty.insertion.session"
            )
            LabTrace.emit(
                "empty.insertion",
                fields: [
                    "cards": payloads.map(\.id).joined(separator: ","),
                    "lane": laneID,
                ]
            )
            store.move(
                payloads: payloads,
                to: laneID,
                proposedOffset: 0,
                source: "\(mode.rawValue).empty"
            )
        }
        .tracedDropTarget(
            mode: mode,
            laneID: laneID,
            target: "empty-lane"
        )
    }
}
