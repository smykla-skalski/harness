use super::{
    CloudflareDns01ChangeRequest, Dns01ChangeOperation, Dns01ExecHookInvocation,
    Dns01ProviderAction, Dns01ProviderChangeRunner, Dns01ProviderExecutionConfig,
    Route53Dns01ChangeBatch,
};
use crate::daemon::remote::RemoteDnsProvider;

#[test]
fn remote_dns01_provider_runner_dispatches_native_and_exec_operations() {
    let mut runner = RecordingDns01Runner::default();
    let cloudflare = Dns01ProviderAction::for_provider(
        RemoteDnsProvider::Cloudflare,
        "_acme-challenge.daemon.example.com",
        "cloudflare-digest",
    );
    let route53 = Dns01ProviderAction::for_provider(
        RemoteDnsProvider::Route53,
        "_acme-challenge.daemon.example.com",
        "route53-digest",
    );
    let exec = Dns01ProviderAction::for_provider(
        RemoteDnsProvider::Exec,
        "_acme-challenge.daemon.example.com",
        "exec-digest",
    );

    cloudflare
        .run_change_with(
            &Dns01ProviderExecutionConfig::cloudflare("zone-123"),
            Dns01ChangeOperation::Present,
            &mut runner,
        )
        .expect("cloudflare present");
    route53
        .run_change_with(
            &Dns01ProviderExecutionConfig::route53("Z123456"),
            Dns01ChangeOperation::Cleanup,
            &mut runner,
        )
        .expect("route53 cleanup");
    exec.run_change_with(
        &Dns01ProviderExecutionConfig::exec("/usr/local/bin/harness-acme-dns"),
        Dns01ChangeOperation::Present,
        &mut runner,
    )
    .expect("exec present");

    assert_eq!(
        runner.events,
        vec![
            "cloudflare:present:zone-123:_acme-challenge.daemon.example.com:cloudflare-digest"
                .to_string(),
            "route53:DELETE:Z123456:_acme-challenge.daemon.example.com.:\"route53-digest\""
                .to_string(),
            "exec:/usr/local/bin/harness-acme-dns:present _acme-challenge.daemon.example.com exec-digest"
                .to_string(),
        ]
    );
}

#[test]
fn remote_dns01_provider_runner_rejects_wrong_config_and_redacts_runner_errors() {
    let cloudflare = Dns01ProviderAction::for_provider(
        RemoteDnsProvider::Cloudflare,
        "_acme-challenge.daemon.example.com",
        "cloudflare-digest",
    );
    let wrong_config = cloudflare
        .run_change_with(
            &Dns01ProviderExecutionConfig::route53("Z123456"),
            Dns01ChangeOperation::Present,
            &mut RecordingDns01Runner::default(),
        )
        .expect_err("cloudflare requires cloudflare config");
    assert!(
        wrong_config
            .to_string()
            .contains("cloudflare DNS provider configuration")
    );

    let mut runner = RecordingDns01Runner {
        fail_detail: Some("provider token=super-secret failed".to_string()),
        ..RecordingDns01Runner::default()
    };
    let failure = cloudflare
        .run_change_with(
            &Dns01ProviderExecutionConfig::cloudflare("zone-123"),
            Dns01ChangeOperation::Present,
            &mut runner,
        )
        .expect_err("provider runner failure should surface");

    assert!(failure.to_string().contains("provider"));
    assert!(!failure.to_string().contains("super-secret"));
}

#[derive(Default)]
struct RecordingDns01Runner {
    events: Vec<String>,
    fail_detail: Option<String>,
}

impl Dns01ProviderChangeRunner for RecordingDns01Runner {
    fn apply_cloudflare_change(
        &mut self,
        request: &CloudflareDns01ChangeRequest,
    ) -> Result<(), String> {
        self.maybe_fail()?;
        self.events.push(format!(
            "cloudflare:{}:{}:{}:{}",
            request.operation().as_str(),
            request.zone_id(),
            request.name(),
            request.content()
        ));
        Ok(())
    }

    fn apply_route53_change(&mut self, batch: &Route53Dns01ChangeBatch) -> Result<(), String> {
        self.maybe_fail()?;
        self.events.push(format!(
            "route53:{}:{}:{}:{}",
            batch.action(),
            batch.hosted_zone_id(),
            batch.name(),
            batch.quoted_value()
        ));
        Ok(())
    }

    fn run_exec_hook(&mut self, invocation: &Dns01ExecHookInvocation) -> Result<(), String> {
        self.maybe_fail()?;
        self.events.push(format!(
            "exec:{}:{}",
            invocation.program(),
            invocation.args().join(" ")
        ));
        Ok(())
    }
}

impl RecordingDns01Runner {
    fn maybe_fail(&self) -> Result<(), String> {
        match &self.fail_detail {
            Some(detail) => Err(detail.clone()),
            None => Ok(()),
        }
    }
}
