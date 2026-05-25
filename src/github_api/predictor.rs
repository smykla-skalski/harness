use std::collections::{HashMap, VecDeque};

use super::budget::GitHubRateResource;

const SAMPLE_LIMIT: usize = 64;
const EWMA_ALPHA: f64 = 0.30;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct OperationKey {
    resource: GitHubRateResource,
    operation: String,
}

#[derive(Debug, Default)]
pub(crate) struct GitHubCostPredictor {
    operations: HashMap<OperationKey, OperationCostStats>,
}

impl GitHubCostPredictor {
    pub(crate) fn predicted_cost(
        &self,
        resource: GitHubRateResource,
        operation: &str,
        static_cost: u32,
    ) -> u32 {
        self.operations
            .get(&OperationKey::new(resource, operation))
            .map_or(static_cost, |stats| stats.predicted_cost(static_cost))
            .max(1)
    }

    pub(crate) fn observe(&mut self, resource: GitHubRateResource, operation: &str, cost: u32) {
        self.operations
            .entry(OperationKey::new(resource, operation))
            .or_default()
            .observe(cost);
    }
}

impl OperationKey {
    fn new(resource: GitHubRateResource, operation: &str) -> Self {
        Self {
            resource,
            operation: operation.to_string(),
        }
    }
}

#[derive(Debug, Default)]
struct OperationCostStats {
    samples: VecDeque<u32>,
    ewma: Option<f64>,
}

impl OperationCostStats {
    fn observe(&mut self, cost: u32) {
        if self.samples.len() == SAMPLE_LIMIT {
            self.samples.pop_front();
        }
        self.samples.push_back(cost);
        self.ewma = Some(match self.ewma {
            Some(previous) => previous.mul_add(1.0 - EWMA_ALPHA, f64::from(cost) * EWMA_ALPHA),
            None => f64::from(cost),
        });
    }

    fn predicted_cost(&self, static_cost: u32) -> u32 {
        static_cost
            .max(self.p95())
            .max(self.ewma.map_or(0, ceil_to_u32))
    }

    fn p95(&self) -> u32 {
        if self.samples.is_empty() {
            return 0;
        }
        let mut values: Vec<u32> = self.samples.iter().copied().collect();
        values.sort_unstable();
        let index = (values.len() * 95).div_ceil(100).saturating_sub(1);
        values[index]
    }
}

fn ceil_to_u32(value: f64) -> u32 {
    if value.is_finite() && value > 0.0 {
        value.ceil().min(f64::from(u32::MAX)) as u32
    } else {
        0
    }
}
