use std::error::Error;
use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Dns01ChangeOperation {
    Present,
    Cleanup,
}

impl Dns01ChangeOperation {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Present => "present",
            Self::Cleanup => "cleanup",
        }
    }

    const fn route53_action(self) -> &'static str {
        match self {
            Self::Present => "UPSERT",
            Self::Cleanup => "DELETE",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CloudflareDns01ChangeRequest {
    operation: Dns01ChangeOperation,
    zone_id: String,
    name: String,
    content: String,
}

impl CloudflareDns01ChangeRequest {
    pub(crate) fn new(
        zone_id: &str,
        name: &str,
        content: &str,
        operation: Dns01ChangeOperation,
    ) -> Result<Self, Dns01ProviderChangeError> {
        let zone_id = zone_id.trim();
        if zone_id.is_empty() {
            return Err(Dns01ProviderChangeError::MissingCloudflareZoneId);
        }
        let name = dns01_record_name(name)?;
        let content = dns01_record_content(content)?;
        Ok(Self {
            operation,
            zone_id: zone_id.to_string(),
            name: name.to_string(),
            content: content.to_string(),
        })
    }

    #[must_use]
    pub fn operation(&self) -> Dns01ChangeOperation {
        self.operation
    }

    #[must_use]
    pub fn zone_id(&self) -> &str {
        &self.zone_id
    }

    #[must_use]
    pub const fn record_type(&self) -> &'static str {
        "TXT"
    }

    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
    }

    #[must_use]
    pub fn content(&self) -> &str {
        &self.content
    }

    #[must_use]
    pub const fn ttl_seconds(&self) -> u32 {
        120
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Route53Dns01ChangeBatch {
    operation: Dns01ChangeOperation,
    hosted_zone_id: String,
    name: String,
    quoted_value: String,
}

impl Route53Dns01ChangeBatch {
    pub(crate) fn new(
        hosted_zone_id: &str,
        name: &str,
        content: &str,
        operation: Dns01ChangeOperation,
    ) -> Result<Self, Dns01ProviderChangeError> {
        let hosted_zone_id = hosted_zone_id.trim();
        if hosted_zone_id.is_empty() {
            return Err(Dns01ProviderChangeError::MissingRoute53HostedZoneId);
        }
        Ok(Self {
            operation,
            hosted_zone_id: hosted_zone_id.to_string(),
            name: route53_record_name(name)?,
            quoted_value: route53_txt_value(dns01_record_content(content)?),
        })
    }

    #[must_use]
    pub fn hosted_zone_id(&self) -> &str {
        &self.hosted_zone_id
    }

    #[must_use]
    pub const fn record_type(&self) -> &'static str {
        "TXT"
    }

    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
    }

    #[must_use]
    pub fn quoted_value(&self) -> &str {
        &self.quoted_value
    }

    #[must_use]
    pub const fn ttl_seconds(&self) -> u32 {
        60
    }

    #[must_use]
    pub fn action(&self) -> &'static str {
        self.operation.route53_action()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Dns01ProviderChangeError {
    WrongProvider(&'static str),
    MissingCloudflareZoneId,
    MissingRoute53HostedZoneId,
    MissingRecordName,
    MissingRecordContent,
}

impl Dns01ProviderChangeError {
    #[must_use]
    pub(crate) const fn wrong_provider(provider: &'static str) -> Self {
        Self::WrongProvider(provider)
    }
}

impl fmt::Display for Dns01ProviderChangeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::WrongProvider(provider) => {
                write!(
                    f,
                    "DNS-01 provider change requires the {provider} DNS provider"
                )
            }
            Self::MissingCloudflareZoneId => write!(f, "cloudflare DNS zone id is required"),
            Self::MissingRoute53HostedZoneId => {
                write!(f, "route53 hosted zone id is required")
            }
            Self::MissingRecordName => write!(f, "DNS-01 TXT record name is required"),
            Self::MissingRecordContent => write!(f, "DNS-01 TXT record content is required"),
        }
    }
}

impl Error for Dns01ProviderChangeError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Dns01ExecHookOperation {
    Present,
    Cleanup,
}

impl Dns01ExecHookOperation {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Present => "present",
            Self::Cleanup => "cleanup",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Dns01ExecHookInvocation {
    program: String,
    args: Vec<String>,
}

impl Dns01ExecHookInvocation {
    pub(crate) fn new<const N: usize>(program: &str, args: [&str; N]) -> Self {
        Self {
            program: program.to_string(),
            args: args.into_iter().map(ToOwned::to_owned).collect(),
        }
    }

    #[must_use]
    pub fn program(&self) -> &str {
        &self.program
    }

    #[must_use]
    pub fn args(&self) -> &[String] {
        &self.args
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Dns01ExecHookError {
    WrongProvider,
    MissingCommand,
    RunnerFailed(String),
}

impl Dns01ExecHookError {
    pub(crate) const fn runner_failed(detail: String) -> Self {
        Self::RunnerFailed(detail)
    }
}

impl fmt::Display for Dns01ExecHookError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::WrongProvider => write!(f, "DNS-01 exec hook requires the exec DNS provider"),
            Self::MissingCommand => write!(f, "DNS-01 exec hook command is required"),
            Self::RunnerFailed(detail) => write!(f, "DNS-01 exec hook failed: {detail}"),
        }
    }
}

impl Error for Dns01ExecHookError {}

fn dns01_record_name(name: &str) -> Result<&str, Dns01ProviderChangeError> {
    let name = name.trim();
    if name.is_empty() {
        return Err(Dns01ProviderChangeError::MissingRecordName);
    }
    Ok(name)
}

fn dns01_record_content(content: &str) -> Result<&str, Dns01ProviderChangeError> {
    let content = content.trim();
    if content.is_empty() {
        return Err(Dns01ProviderChangeError::MissingRecordContent);
    }
    Ok(content)
}

fn route53_record_name(name: &str) -> Result<String, Dns01ProviderChangeError> {
    let name = dns01_record_name(name)?;
    if name.ends_with('.') {
        Ok(name.to_string())
    } else {
        Ok(format!("{name}."))
    }
}

fn route53_txt_value(content: &str) -> String {
    format!("\"{}\"", content.replace('\\', "\\\\").replace('"', "\\\""))
}
