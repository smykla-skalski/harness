use crate::task_board::policy::{
    BuiltInPolicyGate, DEFAULT_AUTO_MERGE_RISK_THRESHOLD, PolicyGate, PolicyInput,
    TASK_BOARD_POLICY_VERSION,
};

use super::{
    POLICY_GRAPH_INITIAL_REVISION, POLICY_GRAPH_SCHEMA_VERSION, PolicyGraph, PolicyGraphMode,
    PolicyGraphNodeKind, PolicyGraphSimulation, PolicyGraphValidationReport, PolicySimulationTrace,
    seed, validation,
};

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

impl Default for PolicyGraph {
    fn default() -> Self {
        Self::seeded_v2()
    }
}

impl PolicyGraph {
    #[must_use]
    pub fn seeded_v2() -> Self {
        let nodes = seed::seeded_nodes();
        Self {
            schema_version: POLICY_GRAPH_SCHEMA_VERSION,
            revision: POLICY_GRAPH_INITIAL_REVISION,
            mode: PolicyGraphMode::Draft,
            edges: seed::seeded_edges(),
            groups: seed::seeded_groups(),
            layout: seed::layout_for(&nodes),
            nodes,
            policy_trace_ids: vec![
                TASK_BOARD_POLICY_VERSION.to_string(),
                "task-board-policy-graph-v2".to_string(),
            ],
        }
    }

    #[must_use]
    pub fn review_text_paste_dry_run_seeded_v2() -> Self {
        seed::review_text_paste_dry_run_document()
    }

    #[must_use]
    pub fn manual_ocr_paste_seeded_v2() -> Self {
        seed::manual_ocr_paste_document()
    }

    #[must_use]
    pub fn review_screenshot_extraction_seeded_v2() -> Self {
        seed::review_screenshot_extraction_document()
    }

    #[must_use]
    pub fn with_mode(mut self, mode: PolicyGraphMode) -> Self {
        self.mode = mode;
        self
    }

    #[must_use]
    pub fn validate(&self) -> PolicyGraphValidationReport {
        validation::validate(self)
    }

    #[must_use]
    pub fn simulate(&self, input: &PolicyInput) -> PolicyGraphSimulation {
        let (decision, visited_node_ids, boundaries) =
            self.evaluate_graph(input).unwrap_or_else(|| {
                let decision =
                    BuiltInPolicyGate::new(self.auto_merge_risk_threshold()).evaluate(input);
                let visited_node_ids = seed::trace_for(self, input, &decision);
                (decision, visited_node_ids, Vec::new())
            });
        PolicyGraphSimulation {
            mode: self.mode,
            trace: PolicySimulationTrace {
                entry_node_id: visited_node_ids.first().cloned(),
                visited_node_ids: visited_node_ids.clone(),
            },
            visited_node_ids,
            policy_trace_ids: self.policy_trace_ids.clone(),
            boundaries,
            decision,
        }
    }

    /// Validate and move this graph to a target mode and revision.
    ///
    /// # Errors
    /// Returns validation issues when the graph is not safe to promote.
    pub fn promoted(
        mut self,
        mode: PolicyGraphMode,
        revision: u64,
    ) -> Result<Self, PolicyGraphValidationReport> {
        let report = self.validate();
        if !report.is_valid() {
            return Err(report);
        }
        self.mode = mode;
        self.revision = revision;
        Ok(self)
    }
}
