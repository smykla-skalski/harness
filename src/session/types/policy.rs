use serde::{Deserialize, Serialize};

use super::SessionRole;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionPolicy {
    pub leader_join: LeaderJoinPolicy,
    pub auto_promotion: AutoPromotionPolicy,
    pub degraded_recovery: LeaderRecoveryPolicy,
}

impl Default for SessionPolicy {
    fn default() -> Self {
        Self {
            leader_join: LeaderJoinPolicy {
                require_explicit_fallback_role: true,
            },
            auto_promotion: AutoPromotionPolicy {
                role_order: vec![
                    SessionRole::Improver,
                    SessionRole::Reviewer,
                    SessionRole::Observer,
                    SessionRole::Worker,
                ],
                priority_preset_id: "swarm-default".into(),
            },
            degraded_recovery: LeaderRecoveryPolicy {
                preset_id: Some("swarm-default".into()),
                manual_recovery_allowed: true,
            },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LeaderJoinPolicy {
    pub require_explicit_fallback_role: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AutoPromotionPolicy {
    pub role_order: Vec<SessionRole>,
    pub priority_preset_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LeaderRecoveryPolicy {
    pub preset_id: Option<String>,
    pub manual_recovery_allowed: bool,
}
