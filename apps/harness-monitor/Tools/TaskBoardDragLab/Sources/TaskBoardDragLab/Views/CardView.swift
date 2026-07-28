import SwiftUI

struct DraggableCardView: View {
    let card: LabCard
    let laneID: String
    let dragSourceMode: DragSourceMode
    let parityStage: LabParityStage
    let isSelected: Bool
    let isHovered: Bool
    let onSelect: (String) -> Void

    init(
        card: LabCard,
        laneID: String,
        dragSourceMode: DragSourceMode,
        parityStage: LabParityStage = .baseline,
        isSelected: Bool = false,
        isHovered: Bool = false,
        onSelect: @escaping (String) -> Void = { _ in }
    ) {
        self.card = card
        self.laneID = laneID
        self.dragSourceMode = dragSourceMode
        self.parityStage = parityStage
        self.isSelected = isSelected
        self.isHovered = isHovered
        self.onSelect = onSelect
    }

    @ViewBuilder
    var body: some View {
        if parityStage.usesPerCardDragObserver {
            accessibleDragSource
                .onDragSessionUpdated { session in
                    LabTrace.dragSession(session, cardID: card.id, laneID: laneID)
                }
        } else {
            accessibleDragSource
        }
    }

    private var accessibleDragSource: some View {
        dragSource
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(card.title), \(card.detail)")
            .accessibilityIdentifier("task-board-drag-lab.card.\(card.id)")
    }

    @ViewBuilder private var dragSource: some View {
        switch dragSourceMode {
        case .transferable:
            cardContent
                .draggable(makePayload())
        case .typedProvider:
            cardContent
                .draggable(CardPayload.self) {
                    makePayload()
                }
        case .container:
            if parityStage.usesEnumDragIdentity {
                cardContent
                    .draggable(containerItemID: LabCardDragID.api(card.id))
            } else {
                cardContent
                    .draggable(containerItemID: card.id)
            }
        }
    }

    @ViewBuilder private var cardContent: some View {
        if parityStage.usesButtonCards {
            Button {
                onSelect(card.id)
            } label: {
                cardLabel
            }
            .buttonStyle(.plain)
            .cardSurface(isSelected: isSelected, isHovered: isHovered)
        } else {
            cardLabel
                .cardSurface(isSelected: false, isHovered: false)
        }
    }

    private var cardLabel: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle.fill")
                .font(.caption)
                .foregroundStyle(.tint)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 3) {
                Text(card.title)
                    .font(.headline)
                Text(card.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private func makePayload() -> CardPayload {
        LabTrace.emit(
            "source.payload",
            fields: [
                "card": card.id,
                "lane": laneID,
                "mode": dragSourceMode.rawValue,
            ]
        )
        return CardPayload(card: card, sourceLaneID: laneID)
    }
}

private extension View {
    func cardSurface(isSelected: Bool, isHovered: Bool) -> some View {
        self
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isHovered ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.08),
                in: .rect(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.clear,
                        lineWidth: isSelected ? 2 : 0
                    )
            }
            .contentShape(.rect)
    }
}

struct LaneHeaderView: View {
    let lane: LabLane
    let mode: BoardMode

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(lane.title)
                    .font(.title3.bold())
                Text("\(lane.cards.count) cards · \(mode.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}
