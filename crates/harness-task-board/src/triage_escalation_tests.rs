use super::TaskBoardTriageEscalationRejectReason;

#[test]
fn reject_reason_wire_codes_are_stable() {
    let expected = [
        (
            TaskBoardTriageEscalationRejectReason::UnknownRunningEscalation,
            "unknown_running_escalation",
        ),
        (
            TaskBoardTriageEscalationRejectReason::ItemIneligible,
            "item_ineligible",
        ),
        (
            TaskBoardTriageEscalationRejectReason::OverrideActive,
            "override_active",
        ),
        (
            TaskBoardTriageEscalationRejectReason::ReservationHeld,
            "reservation_held",
        ),
        (
            TaskBoardTriageEscalationRejectReason::StaleEvidence,
            "stale_evidence",
        ),
    ];
    for (reason, code) in expected {
        assert_eq!(reason.wire_code(), code);
    }
}
