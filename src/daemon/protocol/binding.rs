use std::future::Future;

use serde_json::Value;

use crate::session::types::CONTROL_PLANE_ACTOR_ID;

use super::{
    AgentRemoveRequest, CodexRunRequest, ImproverApplyRequest, LeaderTransferRequest,
    ObserveSessionRequest, RoleChangeRequest, SessionArchiveRequest, SessionEndRequest,
    SignalCancelRequest, SignalSendRequest, TaskArbitrateRequest, TaskAssignRequest,
    TaskBoardDispatchRequest, TaskBoardEvaluateRequest, TaskBoardOrchestratorRunOnceRequest,
    TaskBoardPlanApproveRequest, TaskBoardPlanRevokeRequest, TaskCheckpointRequest,
    TaskClaimReviewRequest, TaskCreateRequest, TaskDeleteRequest, TaskDropRequest,
    TaskQueuePolicyRequest, TaskRespondReviewRequest, TaskSubmitForReviewRequest,
    TaskSubmitReviewRequest, TaskUpdateRequest, VoiceAudioChunkRequest, VoiceSessionFinishRequest,
    VoiceSessionStartRequest, VoiceTranscriptUpdateRequest,
};

/// Rebind actor-bearing daemon requests to the authenticated control-plane
/// principal.
pub trait ControlPlaneActorRequest {
    fn bind_control_plane_actor(&mut self);
}

tokio::task_local! {
    static CONTROL_PLANE_ACTOR_OVERRIDE: String;
}

pub async fn with_control_plane_actor<T>(actor: String, future: impl Future<Output = T>) -> T {
    CONTROL_PLANE_ACTOR_OVERRIDE.scope(actor, future).await
}

#[must_use]
pub fn current_control_plane_actor_id() -> String {
    CONTROL_PLANE_ACTOR_OVERRIDE
        .try_with(Clone::clone)
        .unwrap_or_else(|_| CONTROL_PLANE_ACTOR_ID.to_string())
}

pub fn bind_control_plane_actor_value(params: &mut Value) {
    let Some(object) = params.as_object_mut() else {
        return;
    };
    object.insert(
        "actor".into(),
        Value::String(current_control_plane_actor_id()),
    );
}

fn bind_required_control_plane_actor(actor: &mut String) {
    *actor = current_control_plane_actor_id();
}

fn bind_optional_control_plane_actor(actor: &mut Option<String>) {
    *actor = Some(current_control_plane_actor_id());
}

fn preserve_required_actor(actor: &mut String) {
    if let Ok(remote_actor) = CONTROL_PLANE_ACTOR_OVERRIDE.try_with(Clone::clone) {
        *actor = remote_actor;
    }
}

impl ControlPlaneActorRequest for CodexRunRequest {
    fn bind_control_plane_actor(&mut self) {
        bind_optional_control_plane_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for ObserveSessionRequest {
    fn bind_control_plane_actor(&mut self) {
        bind_optional_control_plane_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for RoleChangeRequest {
    fn bind_control_plane_actor(&mut self) {
        bind_required_control_plane_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for AgentRemoveRequest {
    fn bind_control_plane_actor(&mut self) {
        bind_required_control_plane_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for LeaderTransferRequest {
    fn bind_control_plane_actor(&mut self) {
        bind_required_control_plane_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for TaskCreateRequest {
    fn bind_control_plane_actor(&mut self) {
        bind_required_control_plane_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for TaskDeleteRequest {
    fn bind_control_plane_actor(&mut self) {
        bind_required_control_plane_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for TaskAssignRequest {
    fn bind_control_plane_actor(&mut self) {
        bind_required_control_plane_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for TaskDropRequest {
    fn bind_control_plane_actor(&mut self) {
        bind_required_control_plane_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for TaskQueuePolicyRequest {
    fn bind_control_plane_actor(&mut self) {
        bind_required_control_plane_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for TaskUpdateRequest {
    fn bind_control_plane_actor(&mut self) {
        bind_required_control_plane_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for TaskCheckpointRequest {
    fn bind_control_plane_actor(&mut self) {
        bind_required_control_plane_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for SessionEndRequest {
    fn bind_control_plane_actor(&mut self) {
        bind_required_control_plane_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for SessionArchiveRequest {
    fn bind_control_plane_actor(&mut self) {
        bind_required_control_plane_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for SignalSendRequest {
    fn bind_control_plane_actor(&mut self) {
        bind_required_control_plane_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for SignalCancelRequest {
    fn bind_control_plane_actor(&mut self) {
        bind_required_control_plane_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for VoiceSessionStartRequest {
    fn bind_control_plane_actor(&mut self) {
        bind_required_control_plane_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for VoiceAudioChunkRequest {
    fn bind_control_plane_actor(&mut self) {
        bind_required_control_plane_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for VoiceTranscriptUpdateRequest {
    fn bind_control_plane_actor(&mut self) {
        bind_required_control_plane_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for VoiceSessionFinishRequest {
    fn bind_control_plane_actor(&mut self) {
        bind_required_control_plane_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for TaskSubmitForReviewRequest {
    fn bind_control_plane_actor(&mut self) {
        preserve_required_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for TaskClaimReviewRequest {
    fn bind_control_plane_actor(&mut self) {
        preserve_required_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for TaskSubmitReviewRequest {
    fn bind_control_plane_actor(&mut self) {
        preserve_required_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for TaskRespondReviewRequest {
    fn bind_control_plane_actor(&mut self) {
        preserve_required_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for TaskArbitrateRequest {
    fn bind_control_plane_actor(&mut self) {
        preserve_required_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for ImproverApplyRequest {
    fn bind_control_plane_actor(&mut self) {
        bind_required_control_plane_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for TaskBoardDispatchRequest {
    fn bind_control_plane_actor(&mut self) {
        bind_optional_control_plane_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for TaskBoardOrchestratorRunOnceRequest {
    fn bind_control_plane_actor(&mut self) {
        bind_optional_control_plane_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for TaskBoardPlanApproveRequest {
    fn bind_control_plane_actor(&mut self) {
        bind_required_control_plane_actor(&mut self.approved_by);
    }
}

impl ControlPlaneActorRequest for TaskBoardPlanRevokeRequest {
    fn bind_control_plane_actor(&mut self) {
        bind_optional_control_plane_actor(&mut self.actor);
    }
}

impl ControlPlaneActorRequest for TaskBoardEvaluateRequest {
    fn bind_control_plane_actor(&mut self) {
        // Evaluate carries no actor; authorize via the trait for parity.
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn actor_binding_dispatch_clears_caller_supplied_actor() {
        let mut request = TaskBoardDispatchRequest {
            actor: Some("imposter".into()),
            ..Default::default()
        };
        request.bind_control_plane_actor();
        assert_eq!(request.actor.as_deref(), Some(CONTROL_PLANE_ACTOR_ID));
    }

    #[test]
    fn actor_binding_dispatch_fills_missing_actor() {
        let mut request = TaskBoardDispatchRequest::default();
        assert!(request.actor.is_none());
        request.bind_control_plane_actor();
        assert_eq!(request.actor.as_deref(), Some(CONTROL_PLANE_ACTOR_ID));
    }

    #[test]
    fn actor_binding_plan_approve_overwrites_approved_by() {
        let mut request = TaskBoardPlanApproveRequest {
            id: "item-1".into(),
            approved_by: "spoofed-reviewer".into(),
            approved_at: None,
        };
        request.bind_control_plane_actor();
        assert_eq!(request.approved_by, CONTROL_PLANE_ACTOR_ID);
    }

    #[test]
    fn actor_binding_run_once_clears_caller_supplied_actor() {
        let mut request = TaskBoardOrchestratorRunOnceRequest {
            actor: Some("imposter".into()),
            ..Default::default()
        };
        request.bind_control_plane_actor();
        assert_eq!(request.actor.as_deref(), Some(CONTROL_PLANE_ACTOR_ID));
    }

    #[test]
    fn actor_binding_plan_revoke_clears_caller_supplied_actor() {
        let mut request = TaskBoardPlanRevokeRequest {
            id: "item-1".into(),
            actor: Some("imposter".into()),
        };
        request.bind_control_plane_actor();
        assert_eq!(request.actor.as_deref(), Some(CONTROL_PLANE_ACTOR_ID));
    }

    #[tokio::test]
    async fn actor_binding_uses_scoped_remote_principal() {
        let principal = r#"{"client_id":"phone-1","platform":"ios","role":"operator","scopes":["read","write"]}"#;

        with_control_plane_actor(principal.to_string(), async {
            let mut request = TaskBoardDispatchRequest {
                actor: Some("imposter".into()),
                ..Default::default()
            };
            request.bind_control_plane_actor();

            assert_eq!(request.actor.as_deref(), Some(principal));
        })
        .await;
    }

    #[test]
    fn actor_binding_preserves_local_review_actor() {
        let mut request = TaskSubmitForReviewRequest {
            actor: "worker-1".into(),
            summary: None,
            suggested_persona: None,
        };

        request.bind_control_plane_actor();

        assert_eq!(request.actor, "worker-1");
    }

    #[tokio::test]
    async fn actor_binding_replaces_remote_review_actor() {
        let principal = r#"{"client_id":"phone-1","platform":"ios","role":"operator","scopes":["read","write"]}"#;

        with_control_plane_actor(principal.to_string(), async {
            let mut request = TaskSubmitForReviewRequest {
                actor: "spoofed-worker".into(),
                summary: None,
                suggested_persona: None,
            };
            request.bind_control_plane_actor();

            assert_eq!(request.actor, principal);
        })
        .await;
    }
}
