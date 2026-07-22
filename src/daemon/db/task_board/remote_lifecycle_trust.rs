use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::{Sqlite, Transaction, query_as};

use super::remote_assignment_model::{concurrent, nonblank};
use crate::daemon::db::{CliError, TaskBoardRemoteHostTrustFence, db_error};
use crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest;
use crate::task_board::{TaskBoardExecutionHostConfig, validate_execution_host_config};

const LIFECYCLE_TRUST_SCHEMA_VERSION: u32 = 1;
const MAX_LIFECYCLE_TRUST_JSON_BYTES: usize = 4_096;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct TaskBoardRemoteLifecycleTrustSnapshot {
    schema_version: u32,
    pub(crate) host_id: String,
    pub(crate) endpoint: String,
    pub(crate) certificate_spki_pin: String,
    pub(crate) credential_reference_sha256: String,
    pub(crate) configuration_revision: u64,
    pub(crate) enabled_at_capture: bool,
    pub(crate) observed_host_instance_id: String,
    pub(crate) advertisement_sha256: String,
    pub(crate) snapshot_sha256: String,
}

pub(super) async fn capture_lifecycle_trust_for_offer_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    request: &RemoteOfferRequest,
) -> Result<TaskBoardRemoteLifecycleTrustSnapshot, CliError> {
    let current = query_as::<_, LifecycleHostRow>(LifecycleHostRow::SELECT)
        .bind(&request.binding.host_id)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load remote offer lifecycle trust: {error}")))?
        .ok_or_else(|| concurrent("remote offer host trust is not configured"))?
        .into_trust_fence()?;
    let snapshot = TaskBoardRemoteLifecycleTrustSnapshot::capture(
        &current.host,
        &current.observed_host_instance_id,
        &current.advertisement_sha256,
    )?;
    if !current.host.config.enabled {
        return Err(concurrent("remote offer host is disabled"));
    }
    snapshot.require_generation_binding(
        &request.binding.host_id,
        Some(request.binding.configuration_revision),
        Some(&request.binding.host_instance_id),
    )?;
    Ok(snapshot)
}

pub(super) async fn load_generation_lifecycle_trust_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment_id: &str,
    fencing_epoch: u64,
) -> Result<TaskBoardRemoteLifecycleTrustSnapshot, CliError> {
    let row = query_as::<_, (Option<String>, Option<String>)>(
        "SELECT controller_lifecycle_trust_json, controller_lifecycle_trust_sha256
         FROM task_board_remote_assignments
         WHERE assignment_id = ?1 AND fencing_epoch = ?2 AND legacy_migrated = 0",
    )
    .bind(assignment_id)
    .bind(i64::try_from(fencing_epoch).map_err(|_| {
        db_error("remote lifecycle trust assignment epoch is out of range")
    })?)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load assignment lifecycle trust: {error}")))?
    .ok_or_else(|| concurrent("remote lifecycle trust assignment disappeared"))?;
    decode_lifecycle_trust(row.0, row.1)?
        .ok_or_else(|| concurrent("remote assignment has no frozen lifecycle trust"))
}

pub(super) async fn require_stable_configured_host_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected: &TaskBoardRemoteHostTrustFence,
) -> Result<TaskBoardRemoteHostTrustFence, CliError> {
    let current = query_as::<_, ConfiguredLifecycleHostRow>(ConfiguredLifecycleHostRow::SELECT)
        .bind(&expected.config.host_id)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load configured lifecycle host trust: {error}")))?
        .ok_or_else(|| concurrent("configured lifecycle host disappeared"))?
        .into_fence()?;
    let stable = current.config.host_id == expected.config.host_id
        && current.config.endpoint == expected.config.endpoint
        && current.config.certificate_fingerprint == expected.config.certificate_fingerprint
        && current.config.credential_reference == expected.config.credential_reference
        && current.configuration_revision >= expected.configuration_revision;
    if stable {
        Ok(current)
    } else {
        Err(concurrent(
            "configured lifecycle transport changed during replay",
        ))
    }
}

impl TaskBoardRemoteLifecycleTrustSnapshot {
    pub(crate) fn capture(
        host: &TaskBoardRemoteHostTrustFence,
        observed_host_instance_id: &str,
        advertisement_sha256: &str,
    ) -> Result<Self, CliError> {
        validate_execution_host_config(&host.config)?;
        nonblank(
            observed_host_instance_id,
            "remote lifecycle observed host instance",
        )?;
        require_sha256(
            advertisement_sha256,
            "remote lifecycle advertisement digest",
        )?;
        let mut snapshot = Self {
            schema_version: LIFECYCLE_TRUST_SCHEMA_VERSION,
            host_id: host.config.host_id.clone(),
            endpoint: host.config.endpoint.clone(),
            certificate_spki_pin: host.config.certificate_fingerprint.clone(),
            credential_reference_sha256: credential_reference_digest(
                &host.config.credential_reference,
            ),
            configuration_revision: host.configuration_revision,
            enabled_at_capture: host.config.enabled,
            observed_host_instance_id: observed_host_instance_id.to_owned(),
            advertisement_sha256: advertisement_sha256.to_owned(),
            snapshot_sha256: String::new(),
        };
        snapshot.snapshot_sha256 = snapshot.compute_digest();
        snapshot.validate()?;
        Ok(snapshot)
    }

    pub(crate) fn encoded(&self) -> Result<String, CliError> {
        self.validate()?;
        let json = serde_json::to_string(self)
            .map_err(|error| db_error(format!("serialize remote lifecycle trust: {error}")))?;
        if json.len() > MAX_LIFECYCLE_TRUST_JSON_BYTES {
            return Err(db_error("remote lifecycle trust evidence exceeds its bound"));
        }
        Ok(json)
    }

    pub(crate) fn require_generation_binding(
        &self,
        host_id: &str,
        configuration_revision: Option<u64>,
        target_host_instance_id: Option<&str>,
    ) -> Result<(), CliError> {
        if self.host_id == host_id
            && configuration_revision == Some(self.configuration_revision)
            && target_host_instance_id == Some(self.observed_host_instance_id.as_str())
        {
            Ok(())
        } else {
            Err(db_error(
                "remote lifecycle trust does not match its assignment generation",
            ))
        }
    }

    pub(crate) fn require_stable_transport(
        &self,
        current: &TaskBoardRemoteHostTrustFence,
    ) -> Result<(), CliError> {
        let exact = current.config.host_id == self.host_id
            && current.config.endpoint == self.endpoint
            && current.config.certificate_fingerprint == self.certificate_spki_pin
            && credential_reference_digest(&current.config.credential_reference)
                == self.credential_reference_sha256
            && current.configuration_revision >= self.configuration_revision;
        if exact {
            Ok(())
        } else {
            Err(concurrent(
                "remote lifecycle transport trust changed from the frozen generation",
            ))
        }
    }

    pub(crate) fn require_operation_binding(
        &self,
        generation: &Self,
        host_id: &str,
        configuration_revision: Option<u64>,
        target_host_instance_id: Option<&str>,
        fresh_generation: bool,
    ) -> Result<(), CliError> {
        generation.require_generation_binding(
            host_id,
            configuration_revision,
            target_host_instance_id,
        )?;
        let stable = self.host_id == generation.host_id
            && self.endpoint == generation.endpoint
            && self.certificate_spki_pin == generation.certificate_spki_pin
            && self.credential_reference_sha256 == generation.credential_reference_sha256
            && self.configuration_revision >= generation.configuration_revision;
        let exact_fresh = !fresh_generation
            || (self.enabled_at_capture
                && self.configuration_revision == generation.configuration_revision
                && self.observed_host_instance_id == generation.observed_host_instance_id);
        if stable && exact_fresh {
            Ok(())
        } else {
            Err(db_error(
                "remote operation lifecycle fence does not match its assignment generation",
            ))
        }
    }

    fn validate(&self) -> Result<(), CliError> {
        if self.schema_version != LIFECYCLE_TRUST_SCHEMA_VERSION
            || self.configuration_revision == 0
        {
            return Err(db_error("remote lifecycle trust version or revision is invalid"));
        }
        validate_execution_host_config(&TaskBoardExecutionHostConfig {
            host_id: self.host_id.clone(),
            endpoint: self.endpoint.clone(),
            certificate_fingerprint: self.certificate_spki_pin.clone(),
            credential_reference: "env://HARNESS_REMOTE_LIFECYCLE_TRUST_VALIDATION".into(),
            enabled: self.enabled_at_capture,
        })?;
        nonblank(
            &self.observed_host_instance_id,
            "remote lifecycle observed host instance",
        )?;
        require_sha256(
            &self.credential_reference_sha256,
            "remote lifecycle credential reference digest",
        )?;
        require_sha256(
            &self.advertisement_sha256,
            "remote lifecycle advertisement digest",
        )?;
        require_sha256(&self.snapshot_sha256, "remote lifecycle snapshot digest")?;
        if self.compute_digest() == self.snapshot_sha256 {
            Ok(())
        } else {
            Err(db_error("remote lifecycle trust digest does not match its evidence"))
        }
    }

    fn compute_digest(&self) -> String {
        digest_values(&[
            "harness.task-board.remote-lifecycle-trust.v1",
            self.host_id.as_str(),
            self.endpoint.as_str(),
            self.certificate_spki_pin.as_str(),
            self.credential_reference_sha256.as_str(),
            &self.configuration_revision.to_string(),
            if self.enabled_at_capture {
                "enabled"
            } else {
                "disabled"
            },
            self.observed_host_instance_id.as_str(),
            self.advertisement_sha256.as_str(),
        ])
    }
}

pub(super) fn decode_lifecycle_trust(
    json: Option<String>,
    sha256: Option<String>,
) -> Result<Option<TaskBoardRemoteLifecycleTrustSnapshot>, CliError> {
    match (json, sha256) {
        (None, None) => Ok(None),
        (Some(json), Some(sha256)) => {
            if json.len() > MAX_LIFECYCLE_TRUST_JSON_BYTES {
                return Err(db_error("remote lifecycle trust evidence exceeds its bound"));
            }
            let snapshot = serde_json::from_str::<TaskBoardRemoteLifecycleTrustSnapshot>(&json)
                .map_err(|error| db_error(format!("decode remote lifecycle trust: {error}")))?;
            if snapshot.encoded()? != json || snapshot.snapshot_sha256 != sha256 {
                return Err(db_error(
                    "remote lifecycle trust persistence is not canonical or digest-bound",
                ));
            }
            Ok(Some(snapshot))
        }
        _ => Err(db_error("remote lifecycle trust evidence is incomplete")),
    }
}

pub(super) fn credential_reference_digest(reference: &str) -> String {
    digest_values(&[
        "harness.task-board.remote-credential-reference.v1",
        reference,
    ])
}

pub(super) fn require_sha256(value: &str, context: &str) -> Result<(), CliError> {
    if value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        Ok(())
    } else {
        Err(db_error(format!("{context} is not canonical lowercase SHA-256")))
    }
}

pub(super) fn digest_values(values: &[&str]) -> String {
    let mut hasher = Sha256::new();
    for value in values {
        hasher.update(value.len().to_be_bytes());
        hasher.update(value.as_bytes());
    }
    hex::encode(hasher.finalize())
}

#[derive(sqlx::FromRow)]
struct LifecycleHostRow {
    host_id: String,
    configured_endpoint: String,
    configured_leaf_sha256: String,
    configured_credential_reference: String,
    configuration_revision: i64,
    enabled: bool,
    observed_host_instance_id: Option<String>,
    advertisement_sha256: Option<String>,
}

impl LifecycleHostRow {
    const SELECT: &'static str = "SELECT host_id, configured_endpoint,
        configured_leaf_sha256, configured_credential_reference, configuration_revision,
        enabled, observed_host_instance_id, advertisement_sha256
        FROM task_board_execution_hosts
        WHERE host_id = ?1 AND host_role = 'controller_remote'";

    fn into_trust_fence(self) -> Result<LifecycleHostTrustFence, CliError> {
        let configuration_revision = u64::try_from(self.configuration_revision)
            .ok()
            .filter(|revision| *revision > 0)
            .ok_or_else(|| db_error("remote lifecycle host revision is invalid"))?;
        let observed_host_instance_id = self
            .observed_host_instance_id
            .filter(|value| value.trim() == value && !value.is_empty())
            .ok_or_else(|| concurrent("remote lifecycle host has no observed instance"))?;
        let advertisement_sha256 = self
            .advertisement_sha256
            .ok_or_else(|| concurrent("remote lifecycle host has no advertisement digest"))?;
        require_sha256(
            &advertisement_sha256,
            "remote lifecycle advertisement digest",
        )?;
        let host = TaskBoardRemoteHostTrustFence {
            config: TaskBoardExecutionHostConfig {
                host_id: self.host_id,
                endpoint: self.configured_endpoint,
                certificate_fingerprint: self.configured_leaf_sha256,
                credential_reference: self.configured_credential_reference,
                enabled: self.enabled,
            },
            configuration_revision,
        };
        validate_execution_host_config(&host.config)?;
        Ok(LifecycleHostTrustFence {
            host,
            observed_host_instance_id,
            advertisement_sha256,
        })
    }
}

struct LifecycleHostTrustFence {
    host: TaskBoardRemoteHostTrustFence,
    observed_host_instance_id: String,
    advertisement_sha256: String,
}

#[derive(sqlx::FromRow)]
struct ConfiguredLifecycleHostRow {
    host_id: String,
    configured_endpoint: String,
    configured_leaf_sha256: String,
    configured_credential_reference: String,
    configuration_revision: i64,
    enabled: bool,
}

impl ConfiguredLifecycleHostRow {
    const SELECT: &'static str = "SELECT host_id, configured_endpoint,
        configured_leaf_sha256, configured_credential_reference, configuration_revision, enabled
        FROM task_board_execution_hosts
        WHERE host_id = ?1 AND host_role = 'controller_remote'";

    fn into_fence(self) -> Result<TaskBoardRemoteHostTrustFence, CliError> {
        let configuration_revision = u64::try_from(self.configuration_revision)
            .ok()
            .filter(|revision| *revision > 0)
            .ok_or_else(|| db_error("configured lifecycle host revision is invalid"))?;
        let config = TaskBoardExecutionHostConfig {
            host_id: self.host_id,
            endpoint: self.configured_endpoint,
            certificate_fingerprint: self.configured_leaf_sha256,
            credential_reference: self.configured_credential_reference,
            enabled: self.enabled,
        };
        validate_execution_host_config(&config)?;
        Ok(TaskBoardRemoteHostTrustFence {
            config,
            configuration_revision,
        })
    }
}
