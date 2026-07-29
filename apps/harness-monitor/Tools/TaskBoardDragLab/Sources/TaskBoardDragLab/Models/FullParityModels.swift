import Foundation

enum LabBoardFixtures {
    static let seeded = [
        LabLane(
            id: "backlog",
            title: "Backlog",
            cards: cards(
                prefix: "backlog",
                title: "Backlog",
                detail: "Candidate work item",
                count: 8,
                startsAtOne: true,
                padsTitle: false
            )
        ),
        LabLane(
            id: "doing",
            title: "Doing",
            cards: cards(
                prefix: "doing",
                title: "Doing",
                detail: "Active work item",
                count: 5,
                startsAtOne: true,
                padsTitle: false
            )
        ),
        LabLane(
            id: "done",
            title: "Done",
            cards: cards(
                prefix: "done",
                title: "Done",
                detail: "Completed work item",
                count: 4,
                startsAtOne: true,
                padsTitle: false
            )
        ),
    ]

    static let dense = [
        LabLane(
            id: "backlog",
            title: "Backlog",
            cards: cards(
                prefix: "backlog",
                title: "Backlog",
                detail: "Dense production fixture",
                count: 25
            )
        ),
        LabLane(
            id: "todo",
            title: "Todo",
            cards: cards(
                prefix: "todo",
                title: "Todo",
                detail: "Move this card into Planning",
                count: 24,
                startsAtOne: true
            )
        ),
        LabLane(
            id: "planning",
            title: "Planning",
            cards: cards(
                prefix: "planning",
                title: "Planning",
                detail: "Exact-position destination",
                count: 4
            )
        ),
    ]

    static let fullProduction = [
        LabLane(
            id: "umbrella_items",
            title: "Umbrella",
            cards: cards(
                prefix: "umbrella",
                title: "Umbrella",
                detail: "Non-droppable hierarchy item",
                count: 1
            ),
            role: .umbrella,
            isCollapsed: true
        ),
        LabLane(
            id: "inbox",
            title: "Inbox",
            cards: []
        ),
        LabLane(
            id: "todo",
            title: "Todo",
            cards: cards(
                prefix: "todo",
                title: "Todo",
                detail: "Move this card into Planning",
                count: 24,
                startsAtOne: true
            )
        ),
        LabLane(
            id: "planning",
            title: "Planning",
            cards: cards(
                prefix: "planning",
                title: "Planning",
                detail: "Exact-position destination",
                count: 4
            )
        ),
        LabLane(
            id: "in_progress",
            title: "In Progress",
            cards: cards(
                prefix: "in-progress",
                title: "In Progress",
                detail: "Active work item",
                count: 3
            )
        ),
        LabLane(
            id: "agentic_review",
            title: "Agentic Review",
            cards: [],
            isCollapsed: true
        ),
        LabLane(
            id: "testing",
            title: "Testing",
            cards: cards(
                prefix: "testing",
                title: "Testing",
                detail: "Verification work item",
                count: 1
            )
        ),
        LabLane(
            id: "in_review",
            title: "In Review",
            cards: []
        ),
        LabLane(
            id: "to_review",
            title: "To Review",
            cards: cards(
                prefix: "to-review",
                title: "To Review",
                detail: "Waiting for review",
                count: 2
            ),
            isCollapsed: true
        ),
        LabLane(
            id: "human_required",
            title: "Human Required",
            cards: []
        ),
        LabLane(
            id: "failed",
            title: "Failed",
            cards: cards(
                prefix: "failed",
                title: "Failed",
                detail: "Blocked work item",
                count: 1
            )
        ),
    ]

    private static func cards(
        prefix: String,
        title: String,
        detail: String,
        count: Int,
        startsAtOne: Bool = false,
        padsTitle: Bool = true
    ) -> [LabCard] {
        let start = startsAtOne ? 1 : 0
        return (start ..< start + count).map { index in
            LabCard(
                id: String(format: "%@-%02d", prefix, index),
                title: padsTitle
                    ? String(format: "%@ %02d", title, index)
                    : "\(title) \(index)",
                detail: detail
            )
        }
    }
}
