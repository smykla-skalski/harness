use std::fmt;

use async_trait::async_trait;
use tokio::process::Command;

use crate::daemon::remote_redaction::redact_secret_detail;

#[async_trait]
pub(crate) trait RemoteDnsCommandRunner: Send + Sync {
    async fn run(&self, program: &str, args: &[String]) -> Result<(), String>;
}

#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct TokioRemoteDnsCommandRunner;

#[async_trait]
impl RemoteDnsCommandRunner for TokioRemoteDnsCommandRunner {
    async fn run(&self, program: &str, args: &[String]) -> Result<(), String> {
        let output = Command::new(program)
            .args(args)
            .kill_on_drop(true)
            .output()
            .await
            .map_err(|error| format!("run remote ACME DNS exec hook: {error}"))?;
        if output.status.success() {
            return Ok(());
        }
        let detail = String::from_utf8_lossy(&output.stderr);
        Err(format!(
            "remote ACME DNS exec hook exited with {}: {}",
            output.status,
            redact_secret_detail(detail.trim())
        ))
    }
}

pub(crate) struct ExecDns01Provider<R> {
    runner: R,
    program: String,
}

impl<R> fmt::Debug for ExecDns01Provider<R> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ExecDns01Provider")
            .field("program", &self.program)
            .finish_non_exhaustive()
    }
}

impl<R> ExecDns01Provider<R>
where
    R: RemoteDnsCommandRunner,
{
    pub(crate) fn new(runner: R, program: &str) -> Result<Self, String> {
        let program = program.trim();
        if program.is_empty() {
            return Err("remote ACME DNS exec hook program is required".to_string());
        }
        Ok(Self {
            runner,
            program: program.to_string(),
        })
    }

    pub(crate) async fn present(
        &self,
        record_name: &str,
        record_value: &str,
    ) -> Result<ExecDns01Lease, String> {
        let lease = ExecDns01Lease::new(record_name, record_value)?;
        self.run("present", &lease).await?;
        Ok(lease)
    }

    pub(crate) async fn cleanup(&self, lease: ExecDns01Lease) -> Result<(), String> {
        self.run("cleanup", &lease).await
    }

    async fn run(&self, operation: &str, lease: &ExecDns01Lease) -> Result<(), String> {
        self.runner
            .run(
                &self.program,
                &[
                    operation.to_string(),
                    lease.record_name.clone(),
                    lease.record_value.clone(),
                ],
            )
            .await
    }
}

pub(crate) struct ExecDns01Lease {
    record_name: String,
    record_value: String,
}

impl ExecDns01Lease {
    fn new(record_name: &str, record_value: &str) -> Result<Self, String> {
        let record_name = record_name.trim();
        let record_value = record_value.trim();
        if record_name.is_empty() || record_value.is_empty() {
            return Err("remote ACME DNS exec hook record is incomplete".to_string());
        }
        Ok(Self {
            record_name: record_name.to_string(),
            record_value: record_value.to_string(),
        })
    }
}
