use crate::task_board::policy_graph::PolicyWaitCondition;

pub(crate) const REVIEWS_CHECKS_PASSED_EVENT: &str = "reviews.checks_passed";

#[must_use]
pub(crate) fn checks_passed_wait() -> PolicyWaitCondition {
    PolicyWaitCondition::Event {
        event_key: REVIEWS_CHECKS_PASSED_EVENT.to_owned(),
    }
}
