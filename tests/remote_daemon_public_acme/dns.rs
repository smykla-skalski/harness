use std::future::Future;
use std::net::Ipv4Addr;
use std::panic::{AssertUnwindSafe, resume_unwind};

use async_trait::async_trait;
use futures_util::FutureExt as _;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PublicDnsRecordLease {
    pub entry_id: u64,
    pub name: String,
    pub address: Ipv4Addr,
}

#[async_trait]
pub trait PublicDnsApi: Send + Sync {
    async fn add_a_record(
        &self,
        name: &str,
        address: Ipv4Addr,
    ) -> Result<PublicDnsRecordLease, String>;

    async fn wait_for_a_record(
        &self,
        name: &str,
        address: Ipv4Addr,
        present: bool,
    ) -> Result<(), String>;

    async fn remove_record(&self, lease: &PublicDnsRecordLease) -> Result<(), String>;
}

pub async fn with_temporary_a_record<Api, Operation, OperationFuture, Output>(
    api: &Api,
    name: &str,
    address: Ipv4Addr,
    operation: Operation,
) -> Result<Output, String>
where
    Api: PublicDnsApi,
    Operation: FnOnce() -> OperationFuture,
    OperationFuture: Future<Output = Result<Output, String>>,
{
    let lease = api.add_a_record(name, address).await?;
    let operation_outcome = AssertUnwindSafe(async {
        api.wait_for_a_record(name, address, true).await?;
        operation().await
    })
    .catch_unwind()
    .await;
    let cleanup_result = cleanup_temporary_a_record(api, &lease).await;
    finish_operation_after_cleanup(operation_outcome, cleanup_result)
}

fn finish_operation_after_cleanup<Output>(
    operation_outcome: Result<Result<Output, String>, Box<dyn std::any::Any + Send>>,
    cleanup_result: Result<(), String>,
) -> Result<Output, String> {
    match operation_outcome {
        Ok(operation_result) => combine_operation_and_cleanup(operation_result, cleanup_result),
        Err(panic) => {
            if let Err(cleanup_error) = cleanup_result {
                panic!("temporary DNS cleanup failed after operation panic: {cleanup_error}");
            }
            resume_unwind(panic)
        }
    }
}

async fn cleanup_temporary_a_record<Api: PublicDnsApi>(
    api: &Api,
    lease: &PublicDnsRecordLease,
) -> Result<(), String> {
    let removal = api.remove_record(lease).await;
    let absence = api
        .wait_for_a_record(&lease.name, lease.address, false)
        .await;
    match (removal, absence) {
        (Ok(()), Ok(())) => Ok(()),
        (Err(error), Ok(())) | (Ok(()), Err(error)) => Err(error),
        (Err(removal_error), Err(absence_error)) => Err(format!(
            "remove record failed: {removal_error}; authoritative absence failed: {absence_error}"
        )),
    }
}

fn combine_operation_and_cleanup<Output>(
    operation: Result<Output, String>,
    cleanup: Result<(), String>,
) -> Result<Output, String> {
    match (operation, cleanup) {
        (Ok(output), Ok(())) => Ok(output),
        (Err(error), Ok(())) | (Ok(_), Err(error)) => Err(error),
        (Err(operation_error), Err(cleanup_error)) => Err(format!(
            "{operation_error}; temporary DNS cleanup also failed: {cleanup_error}"
        )),
    }
}

#[cfg(test)]
mod tests {
    use std::panic::AssertUnwindSafe;
    use std::sync::Mutex;

    use futures_util::FutureExt as _;

    use super::*;

    #[tokio::test]
    async fn temporary_a_record_is_removed_after_success() {
        let api = RecordingDnsApi::default();

        let output = with_temporary_a_record(&api, "tls.example.com", address(), || async {
            Ok::<_, String>(42)
        })
        .await
        .expect("temporary record operation");

        assert_eq!(output, 42);
        assert_eq!(
            api.calls(),
            [
                "add:tls.example.com",
                "wait-present:tls.example.com",
                "remove:73",
                "wait-absent:tls.example.com",
            ]
        );
    }

    #[tokio::test]
    async fn temporary_a_record_is_removed_after_operation_failure() {
        let api = RecordingDnsApi::default();

        let error = with_temporary_a_record(&api, "http.example.com", address(), || async {
            Err::<(), _>("issuance failed".to_string())
        })
        .await
        .expect_err("operation should fail");

        assert_eq!(error, "issuance failed");
        assert_eq!(
            api.calls(),
            [
                "add:http.example.com",
                "wait-present:http.example.com",
                "remove:73",
                "wait-absent:http.example.com",
            ]
        );
    }

    #[tokio::test]
    async fn temporary_a_record_is_removed_when_readiness_fails() {
        let api = RecordingDnsApi::with_ready_failure();

        let error = with_temporary_a_record(&api, "dns.example.com", address(), || async {
            Ok::<(), String>(())
        })
        .await
        .expect_err("readiness should fail");

        assert_eq!(error, "authoritative visibility timed out");
        assert_eq!(
            api.calls(),
            [
                "add:dns.example.com",
                "wait-present:dns.example.com",
                "remove:73",
                "wait-absent:dns.example.com",
            ]
        );
    }

    #[tokio::test]
    async fn temporary_a_record_is_removed_before_operation_panic_resumes() {
        let api = RecordingDnsApi::default();

        let panic = AssertUnwindSafe(with_temporary_a_record::<_, _, _, ()>(
            &api,
            "panic.example.com",
            address(),
            || async {
                panic!("unexpected client panic");
            },
        ))
        .catch_unwind()
        .await;

        assert!(panic.is_err());
        assert_eq!(
            api.calls(),
            [
                "add:panic.example.com",
                "wait-present:panic.example.com",
                "remove:73",
                "wait-absent:panic.example.com",
            ]
        );
    }

    fn address() -> Ipv4Addr {
        Ipv4Addr::new(192, 0, 2, 7)
    }

    #[derive(Default)]
    struct RecordingDnsApi {
        calls: Mutex<Vec<String>>,
        fail_ready: bool,
    }

    impl RecordingDnsApi {
        fn with_ready_failure() -> Self {
            Self {
                calls: Mutex::default(),
                fail_ready: true,
            }
        }

        fn calls(&self) -> Vec<String> {
            self.calls.lock().expect("calls lock").clone()
        }

        fn record(&self, call: String) {
            self.calls.lock().expect("calls lock").push(call);
        }
    }

    #[async_trait]
    impl PublicDnsApi for RecordingDnsApi {
        async fn add_a_record(
            &self,
            name: &str,
            address: Ipv4Addr,
        ) -> Result<PublicDnsRecordLease, String> {
            self.record(format!("add:{name}"));
            Ok(PublicDnsRecordLease {
                entry_id: 73,
                name: name.to_string(),
                address,
            })
        }

        async fn wait_for_a_record(
            &self,
            name: &str,
            _address: Ipv4Addr,
            present: bool,
        ) -> Result<(), String> {
            self.record(format!(
                "wait-{}:{name}",
                if present { "present" } else { "absent" }
            ));
            if present && self.fail_ready {
                Err("authoritative visibility timed out".to_string())
            } else {
                Ok(())
            }
        }

        async fn remove_record(&self, lease: &PublicDnsRecordLease) -> Result<(), String> {
            self.record(format!("remove:{}", lease.entry_id));
            Ok(())
        }
    }
}
