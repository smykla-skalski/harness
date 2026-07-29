import SwiftUI
import TaskBoardDragLabTransfer

struct FullParityCardRow<Payload: FullParityCardPayload>: View {
    let card: LabCard
    let lane: LabLane
    let selectionModel: FullParitySelectionModel
    let hoverTracking: LabLaneHoverTracking
    let coordinateSpaceName: String
    let nativeListCoordinator: FullParityNativeListCoordinator
    let usesListRowStyle: Bool
    @Environment(BoardStore.self)
    private var store

    private var cardID: FullParityCardID {
        .api(card.id)
    }

    private var isSelected: Bool {
        selectionModel.selectedIDs.contains(cardID)
    }

    private var isHovered: Bool {
        hoverTracking.hoveredCardID == card.id
    }

    @ViewBuilder
    var body: some View {
        let content = Button {
            selectionModel.select(cardID)
        } label: {
            cardLabel
        }
        .buttonStyle(.plain)
        .fullParityCardSurface(
            tint: projectColor,
            isHovered: isHovered,
            isSelected: isSelected
        )
        .contentShape(.rect)
        .draggable(containerItemID: cardID)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("Click to select. Drag to move.")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("task-board-drag-lab.card.\(card.id)")
        .accessibilityAction(named: Text("Move to Top")) {
            move(to: 0, source: "Accessibility.move-top")
        }
        .accessibilityAction(named: Text("Move to Bottom")) {
            move(to: lane.cards.count, source: "Accessibility.move-bottom")
        }
        .background {
            FullParityAppKitContextMenu(
                isFirst: isFirst,
                isLast: isLast,
                moveToTop: {
                    move(to: 0, source: "ContextMenu.move-top")
                },
                moveToBottom: {
                    move(
                        to: lane.cards.count,
                        source: "ContextMenu.move-bottom"
                    )
                },
                primeSelection: {
                    selectionModel.select(cardID)
                }
            )
        }
        .labTrackedCardFrame(
            cardID: card.id,
            coordinateSpace: coordinateSpaceName,
            isEnabled: true,
            tracking: hoverTracking
        )
        .id(cardID)

        if usesListRowStyle {
            content
                .listRowInsets(
                    EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        } else {
            content
                .frame(maxWidth: .infinity)
        }
    }

    private var cardLabel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: cardGlyph)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(projectColor)
                    .frame(width: 28, height: 28)
                    .background(projectColor.opacity(0.16), in: Circle())

                Text(card.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 6) {
                projectMark
                Text("harness")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                FullParityPill(label: priorityLabel, tint: .orange)
                FullParityPill(label: "Approved", tint: .green)

                Spacer(minLength: 0)

                Text("now")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
    }

    private var projectMark: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(projectColor)
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)
    }

    private var priorityLabel: String {
        card.id.hasSuffix("01") ? "P1" : "P2"
    }

    private var cardGlyph: String {
        card.id.hasSuffix("01") ? "smallcircle.filled.circle" : "circle.fill"
    }

    private var projectColor: Color {
        let seed = card.id.unicodeScalars.reduce(0) {
            ($0 + Int($1.value)) % 5
        }
        return [.blue, .purple, .green, .orange, .pink][seed]
    }

    private var isFirst: Bool {
        lane.cards.first?.id == card.id
    }

    private var isLast: Bool {
        lane.cards.last?.id == card.id
    }

    private func move(to offset: Int, source: String) {
        let before = store.orderSignature
        nativeListCoordinator.requestReveal(cardID: card.id, in: lane.id)
        store.move(
            payloads: [CardPayload(card: card, sourceLaneID: lane.id)],
            to: lane.id,
            proposedOffset: offset,
            source: source
        )
        if store.orderSignature == before {
            nativeListCoordinator.cancelReveal(cardID: card.id, in: lane.id)
        }
    }
}

private struct FullParityPill: View {
    let label: String
    let tint: Color

    var body: some View {
        Text(label)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

private extension View {
    func fullParityCardSurface(
        tint: Color,
        isHovered: Bool,
        isSelected: Bool
    ) -> some View {
        background(
            isHovered ? tint.opacity(0.11) : Color.secondary.opacity(0.07),
            in: .rect(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isSelected ? tint : Color.secondary.opacity(0.12),
                    lineWidth: isSelected ? 2 : 1
                )
                .allowsHitTesting(false)
        }
    }
}
