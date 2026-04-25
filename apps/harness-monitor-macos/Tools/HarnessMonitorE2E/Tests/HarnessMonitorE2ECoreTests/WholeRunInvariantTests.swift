import Foundation
@testable import HarnessMonitorE2ECore
import XCTest

/// Coverage for `RecordingTriage.assertWholeRunInvariants(perActHierarchies:taskReviewID:)`.
/// The function walks every act snapshot once and emits the cross-act
/// findings called out in `references/act-marker-matrix.md` (badge progression
/// for `task_review`, daemon-health proxy via the connection badge, etc.).
final class WholeRunInvariantTests: XCTestCase {
    private func parse(_ text: String) -> [RecordingTriage.AccessibilityIdentifier] {
        RecordingTriage.parseAccessibilityIdentifiers(from: text)
    }

    private func hierarchy(_ act: String, _ text: String) -> RecordingTriage.ActHierarchy {
        RecordingTriage.ActHierarchy(act: act, identifiers: parse(text))
    }

    private func verdict(_ findings: [RecordingTriage.ChecklistFinding], for id: String) -> RecordingTriage.ChecklistFinding.Verdict? {
        findings.first { $0.id == id }?.verdict
    }

    func testTaskReviewProgressionFoundWhenBothBadgesSeen() {
        let hierarchies = [
            hierarchy("act8", "Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'awaitingReviewBadge.task-1'"),
            hierarchy("act9", "Other, 0x2, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'inReviewBadge.task-1'"),
        ]
        let findings = RecordingTriage.assertWholeRunInvariants(
            perActHierarchies: hierarchies,
            taskReviewID: "task-1"
        )
        XCTAssertEqual(verdict(findings, for: "swarm.invariant.taskReviewProgression"), .found)
    }

    func testTaskReviewProgressionFlagsMissingInReview() {
        let hierarchies = [
            hierarchy("act8", "Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'awaitingReviewBadge.task-1'"),
            hierarchy("act9", "Other, 0x2, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'unrelated'"),
        ]
        let findings = RecordingTriage.assertWholeRunInvariants(
            perActHierarchies: hierarchies,
            taskReviewID: "task-1"
        )
        XCTAssertEqual(verdict(findings, for: "swarm.invariant.taskReviewProgression"), .notFound)
    }

    func testTaskReviewProgressionFlagsMissingAwaitingReview() {
        let hierarchies = [
            hierarchy("act9", "Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'inReviewBadge.task-1'"),
        ]
        let findings = RecordingTriage.assertWholeRunInvariants(
            perActHierarchies: hierarchies,
            taskReviewID: "task-1"
        )
        XCTAssertEqual(verdict(findings, for: "swarm.invariant.taskReviewProgression"), .notFound)
    }

    func testTaskReviewProgressionNeedsVerificationWithoutTaskID() {
        let findings = RecordingTriage.assertWholeRunInvariants(
            perActHierarchies: [],
            taskReviewID: nil
        )
        XCTAssertEqual(verdict(findings, for: "swarm.invariant.taskReviewProgression"), .needsVerification)
    }

    func testDaemonHealthFoundWhenAllActsCarryConnectionBadge() {
        let hierarchies = [
            hierarchy("act1", "Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.toolbar.connection-badge', label: 'Connection: WS, latency 0 milliseconds'"),
            hierarchy("act2", "Other, 0x2, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.toolbar.connection-badge', label: 'Connection: WS, latency 8 milliseconds'"),
        ]
        let findings = RecordingTriage.assertWholeRunInvariants(
            perActHierarchies: hierarchies,
            taskReviewID: nil
        )
        XCTAssertEqual(verdict(findings, for: "swarm.invariant.daemonHealth"), .found)
    }

    func testDaemonHealthFlagsMissingConnectionBadge() {
        let hierarchies = [
            hierarchy("act1", "Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.toolbar.connection-badge', label: 'Connection: WS, latency 0 milliseconds'"),
            hierarchy("act2", "Other, 0x2, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'unrelated'"),
        ]
        let findings = RecordingTriage.assertWholeRunInvariants(
            perActHierarchies: hierarchies,
            taskReviewID: nil
        )
        XCTAssertEqual(verdict(findings, for: "swarm.invariant.daemonHealth"), .notFound)
    }

    func testDaemonHealthFlagsLostConnection() {
        let hierarchies = [
            hierarchy("act1", "Other, 0x1, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.toolbar.connection-badge', label: 'Connection: WS, latency 0 milliseconds'"),
            hierarchy("act2", "Other, 0x2, {{0.0, 0.0}, {1.0, 1.0}}, identifier: 'harness.toolbar.connection-badge', label: 'Connection: lost'"),
        ]
        let findings = RecordingTriage.assertWholeRunInvariants(
            perActHierarchies: hierarchies,
            taskReviewID: nil
        )
        XCTAssertEqual(verdict(findings, for: "swarm.invariant.daemonHealth"), .notFound)
    }

    func testOpaqueInvariantsDeferredToHumanVerification() {
        let findings = RecordingTriage.assertWholeRunInvariants(
            perActHierarchies: [],
            taskReviewID: nil
        )
        XCTAssertEqual(verdict(findings, for: "swarm.invariant.toastQueueAppendOnly"), .needsVerification)
        XCTAssertEqual(verdict(findings, for: "swarm.invariant.taskInspectorMatches"), .needsVerification)
        XCTAssertEqual(verdict(findings, for: "swarm.invariant.heuristicCodesPersist"), .needsVerification)
    }
}
