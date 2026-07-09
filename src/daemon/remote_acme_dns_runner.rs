use std::error::Error;
use std::fmt;

use super::remote::RemoteDnsProvider;
use super::remote_acme_dns::{
    CloudflareDns01ChangeRequest, Dns01ChangeOperation, Dns01ExecHookError,
    Dns01ExecHookInvocation, Dns01ExecHookOperation, Dns01ProviderChangeError,
    Route53Dns01ChangeBatch,
};
use super::remote_redaction::redact_secret_detail;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Dns01ProviderExecutionConfig {
    Cloudflare { zone_id: String },
    Route53 { hosted_zone_id: String },
    Exec { hook_program: String },
}

impl Dns01ProviderExecutionConfig {
    #[must_use]
    pub fn cloudflare(zone_id: impl Into<String>) -> Self {
        Self::Cloudflare {
            zone_id: zone_id.into(),
        }
    }

    #[must_use]
    pub fn route53(hosted_zone_id: impl Into<String>) -> Self {
        Self::Route53 {
            hosted_zone_id: hosted_zone_id.into(),
        }
    }

    #[must_use]
    pub fn exec(hook_program: impl Into<String>) -> Self {
        Self::Exec {
            hook_program: hook_program.into(),
        }
    }
}

pub trait Dns01ProviderChangeRunner {
    /// Apply a Cloudflare DNS-01 TXT record change.
    ///
    /// # Errors
    /// Returns a redaction-ready provider detail when the change fails.
    fn apply_cloudflare_change(
        &mut self,
        request: &CloudflareDns01ChangeRequest,
    ) -> Result<(), String>;

    /// Apply a Route53 DNS-01 TXT record change.
    ///
    /// # Errors
    /// Returns a redaction-ready provider detail when the change fails.
    fn apply_route53_change(&mut self, batch: &Route53Dns01ChangeBatch) -> Result<(), String>;

    /// Run a generic DNS-01 exec-hook invocation.
    ///
    /// # Errors
    /// Returns a redaction-ready provider detail when the hook fails.
    fn run_exec_hook(&mut self, invocation: &Dns01ExecHookInvocation) -> Result<(), String>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Dns01ProviderExecutionError {
    WrongProviderConfig(&'static str),
    ProviderChange(Dns01ProviderChangeError),
    ExecHook(Dns01ExecHookError),
    RunnerFailed(String),
}

impl Dns01ProviderExecutionError {
    fn runner_failed(detail: &str) -> Self {
        Self::RunnerFailed(redact_secret_detail(detail))
    }
}

impl fmt::Display for Dns01ProviderExecutionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::WrongProviderConfig(provider) => {
                write!(
                    f,
                    "DNS-01 {provider} action requires {provider} DNS provider configuration"
                )
            }
            Self::ProviderChange(error) => write!(f, "{error}"),
            Self::ExecHook(error) => write!(f, "{error}"),
            Self::RunnerFailed(detail) => write!(f, "DNS-01 provider change failed: {detail}"),
        }
    }
}

impl Error for Dns01ProviderExecutionError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::ProviderChange(error) => Some(error),
            Self::ExecHook(error) => Some(error),
            Self::WrongProviderConfig(_) | Self::RunnerFailed(_) => None,
        }
    }
}

impl From<Dns01ProviderChangeError> for Dns01ProviderExecutionError {
    fn from(value: Dns01ProviderChangeError) -> Self {
        Self::ProviderChange(value)
    }
}

impl From<Dns01ExecHookError> for Dns01ProviderExecutionError {
    fn from(value: Dns01ExecHookError) -> Self {
        Self::ExecHook(value)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Dns01ProviderAction {
    provider: RemoteDnsProvider,
    fqdn: String,
    digest: String,
}

impl Dns01ProviderAction {
    #[must_use]
    pub fn for_provider(
        provider: RemoteDnsProvider,
        fqdn: impl Into<String>,
        digest: impl Into<String>,
    ) -> Self {
        Self {
            provider,
            fqdn: fqdn.into(),
            digest: digest.into(),
        }
    }

    #[must_use]
    pub const fn required_secret_names(&self) -> &'static [&'static str] {
        match self.provider {
            RemoteDnsProvider::Cloudflare => &["CLOUDFLARE_API_TOKEN"],
            RemoteDnsProvider::Route53 => &["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"],
            RemoteDnsProvider::Exec => &["HARNESS_REMOTE_ACME_DNS_EXEC"],
        }
    }

    #[must_use]
    pub fn command_preview(&self) -> String {
        match self.provider {
            RemoteDnsProvider::Cloudflare => {
                format!("cloudflare TXT {} {}", self.fqdn, self.digest)
            }
            RemoteDnsProvider::Route53 => format!("route53 TXT {} {}", self.fqdn, self.digest),
            RemoteDnsProvider::Exec => {
                format!(
                    "$HARNESS_REMOTE_ACME_DNS_EXEC present {} {}",
                    self.fqdn, self.digest
                )
            }
        }
    }

    /// Build the Cloudflare DNS-01 change request for this provider action.
    ///
    /// # Errors
    /// Returns [`Dns01ProviderChangeError`] when this action is not for the
    /// Cloudflare provider or the request fields are invalid.
    pub fn cloudflare_change_request(
        &self,
        zone_id: &str,
        operation: Dns01ChangeOperation,
    ) -> Result<CloudflareDns01ChangeRequest, Dns01ProviderChangeError> {
        if self.provider != RemoteDnsProvider::Cloudflare {
            return Err(Dns01ProviderChangeError::wrong_provider("cloudflare"));
        }
        CloudflareDns01ChangeRequest::new(
            zone_id,
            self.fqdn.as_str(),
            self.digest.as_str(),
            operation,
        )
    }

    /// Build the Route53 DNS-01 change batch for this provider action.
    ///
    /// # Errors
    /// Returns [`Dns01ProviderChangeError`] when this action is not for the
    /// Route53 provider or the request fields are invalid.
    pub fn route53_change_batch(
        &self,
        hosted_zone_id: &str,
        operation: Dns01ChangeOperation,
    ) -> Result<Route53Dns01ChangeBatch, Dns01ProviderChangeError> {
        if self.provider != RemoteDnsProvider::Route53 {
            return Err(Dns01ProviderChangeError::wrong_provider("route53"));
        }
        Route53Dns01ChangeBatch::new(
            hosted_zone_id,
            self.fqdn.as_str(),
            self.digest.as_str(),
            operation,
        )
    }

    /// Run one DNS-01 provider change with provider-specific configuration.
    ///
    /// # Errors
    /// Returns [`Dns01ProviderExecutionError`] when the configuration does not
    /// match the action provider, request validation fails, or the runner
    /// rejects the provider operation.
    pub fn run_change_with<Runner>(
        &self,
        config: &Dns01ProviderExecutionConfig,
        operation: Dns01ChangeOperation,
        runner: &mut Runner,
    ) -> Result<(), Dns01ProviderExecutionError>
    where
        Runner: Dns01ProviderChangeRunner,
    {
        match self.provider {
            RemoteDnsProvider::Cloudflare => {
                let Dns01ProviderExecutionConfig::Cloudflare { zone_id } = config else {
                    return Err(Dns01ProviderExecutionError::WrongProviderConfig(
                        "cloudflare",
                    ));
                };
                let request = self.cloudflare_change_request(zone_id, operation)?;
                runner
                    .apply_cloudflare_change(&request)
                    .map_err(|detail| Dns01ProviderExecutionError::runner_failed(&detail))
            }
            RemoteDnsProvider::Route53 => {
                let Dns01ProviderExecutionConfig::Route53 { hosted_zone_id } = config else {
                    return Err(Dns01ProviderExecutionError::WrongProviderConfig("route53"));
                };
                let batch = self.route53_change_batch(hosted_zone_id, operation)?;
                runner
                    .apply_route53_change(&batch)
                    .map_err(|detail| Dns01ProviderExecutionError::runner_failed(&detail))
            }
            RemoteDnsProvider::Exec => {
                let Dns01ProviderExecutionConfig::Exec { hook_program } = config else {
                    return Err(Dns01ProviderExecutionError::WrongProviderConfig("exec"));
                };
                self.run_exec_hook_with(
                    hook_program,
                    Dns01ExecHookOperation::from(operation),
                    |invocation| runner.run_exec_hook(invocation),
                )
                .map_err(Dns01ProviderExecutionError::from)
            }
        }
    }

    /// Run the generic DNS-01 exec hook for this provider action.
    ///
    /// # Errors
    /// Returns [`Dns01ExecHookError`] when this action is not for the exec
    /// provider, the hook program is blank, or the injected runner fails.
    pub fn run_exec_hook_with<Run>(
        &self,
        hook_program: &str,
        operation: Dns01ExecHookOperation,
        runner: Run,
    ) -> Result<(), Dns01ExecHookError>
    where
        Run: FnOnce(&Dns01ExecHookInvocation) -> Result<(), String>,
    {
        if self.provider != RemoteDnsProvider::Exec {
            return Err(Dns01ExecHookError::WrongProvider);
        }
        let program = hook_program.trim();
        if program.is_empty() {
            return Err(Dns01ExecHookError::MissingCommand);
        }
        let invocation = Dns01ExecHookInvocation::new(
            program,
            [operation.as_str(), self.fqdn.as_str(), self.digest.as_str()],
        );
        runner(&invocation)
            .map_err(|detail| Dns01ExecHookError::runner_failed(redact_secret_detail(&detail)))
    }
}
