use crate::task_board::policy::DEFAULT_AUTO_MERGE_RISK_THRESHOLD;

use super::{PolicyGraph, PolicyGraphNodeKind, PolicyGraphValidationReport};

impl PolicyGraph {
    pub(super) fn auto_merge_risk_threshold(&self) -> u8 {
        self.nodes
            .iter()
            .find_map(|node| match node.kind {
                PolicyGraphNodeKind::RiskClassifier { threshold, .. } => Some(threshold),
                _ => None,
            })
            .unwrap_or(DEFAULT_AUTO_MERGE_RISK_THRESHOLD)
    }
}

impl PolicyGraphValidationReport {
    #[must_use]
    pub fn is_valid(&self) -> bool {
        self.issues.is_empty()
    }
}
