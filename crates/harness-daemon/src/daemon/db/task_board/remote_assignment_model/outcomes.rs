use super::TaskBoardRemoteAssignmentRecord;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum TaskBoardRemoteOfferOutcome {
    Created(TaskBoardRemoteAssignmentRecord),
    AcceptedReplay(super::super::remote_offer_receipts::TaskBoardRemoteOfferReceipt),
    Rejected(super::super::remote_offer_receipts::TaskBoardRemoteOfferReceipt),
    Replayed(TaskBoardRemoteAssignmentRecord),
    Stale,
    Unavailable,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum TaskBoardRemoteMutationOutcome {
    Updated(TaskBoardRemoteAssignmentRecord),
    Replayed(TaskBoardRemoteAssignmentRecord),
    Stale(TaskBoardRemoteAssignmentRecord),
}
