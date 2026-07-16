use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeModelTier {
    Fast,
    Balanced,
    Max,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EffortKind {
    None,
    ThinkingBudget,
    ReasoningEffort,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RuntimeModel {
    pub id: String,
    pub display_name: String,
    pub tier: RuntimeModelTier,
    #[serde(default = "effort_kind_none")]
    pub effort_kind: EffortKind,
    #[serde(default)]
    pub effort_values: Vec<String>,
}

impl RuntimeModel {
    #[must_use]
    pub fn supports_effort(&self) -> bool {
        !matches!(self.effort_kind, EffortKind::None)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RuntimeModelCatalog {
    pub runtime: String,
    pub models: Vec<RuntimeModel>,
    pub default: String,
    pub cheapest_fastest: String,
}

const fn effort_kind_none() -> EffortKind {
    EffortKind::None
}
