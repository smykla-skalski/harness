use serde_json::Value;

use crate::session::types::CONTROL_PLANE_ACTOR_ID;

use super::{
    AgentRemoveRequest, CodexRunRequest, LeaderTransferRequest, ObserveSessionRequest,
    RoleChangeRequest, SessionEndRequest, SignalCancelRequest, SignalSendRequest,
    TaskAssignRequest, TaskCheckpointRequest, TaskCreateRequest, TaskDropRequest,
    TaskQueuePolicyRequest, TaskUpdateRequest, VoiceAudioChunkRequest, VoiceSessionFinishRequest,
    VoiceSessionStartRequest, VoiceTranscriptUpdateRequest,
};

/// Rebind actor-bearing daemon requests to the authenticated control-plane
/// principal.
pub trait ControlPlaneActorRequest {
    fn bind_control_plane_actor(&mut self);
}

pub fn bind_control_plane_actor_value(params: &mut Value) {
    let Some(object) = params.as_object_mut() else {
        return;
    };
    object.insert(
        "actor".into(),
        Value::String(CONTROL_PLANE_ACTOR_ID.to_string()),
    );
}

fn bind_required_control_plane_actor(actor: &mut String) {
    *actor = CONTROL_PLANE_ACTOR_ID.to_string();
}

fn bind_optional_control_plane_actor(actor: &mut Option<String>) {
    *actor = Some(CONTROL_PLANE_ACTOR_ID.to_string());
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
