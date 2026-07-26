use std::io::{Error as IoError, ErrorKind};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::task::{Context, Poll};

use axum::BoxError;
use axum::body::Body;
use axum::response::Response;
use bytes::Bytes;
use http_body_util::BodyExt as _;
use hyper::body::{Body as HttpBody, Frame, Incoming};
use tokio::sync::{OwnedSemaphorePermit, mpsc};
use tokio::time::{Instant, timeout_at};

type PumpItem = Result<Frame<Bytes>, BoxError>;

#[derive(Clone)]
pub(super) struct CompanionResponseLease {
    inner: Arc<Mutex<CompanionResponseLeaseState>>,
}

#[derive(Default)]
struct CompanionResponseLeaseState {
    permits: Option<(OwnedSemaphorePermit, OwnedSemaphorePermit)>,
    finished: bool,
}

impl CompanionResponseLease {
    fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(CompanionResponseLeaseState::default())),
        }
    }

    fn bind(&self, http: OwnedSemaphorePermit, companion: OwnedSemaphorePermit) {
        let mut state = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        if state.finished || state.permits.is_some() {
            return;
        }
        state.permits = Some((http, companion));
    }

    fn finish(&self) {
        let permits = {
            let mut state = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            state.finished = true;
            state.permits.take()
        };
        drop(permits);
    }
}

pub(crate) fn bind_response_permits(
    response: Response,
    http: OwnedSemaphorePermit,
    companion: Option<OwnedSemaphorePermit>,
) -> Response {
    let Some(companion) = companion else {
        drop(http);
        return response;
    };
    let Some(lease) = response
        .extensions()
        .get::<CompanionResponseLease>()
        .cloned()
    else {
        drop(http);
        drop(companion);
        return response;
    };
    lease.bind(http, companion);
    response
}

pub(super) fn stream_upstream_body(
    upstream: Incoming,
    deadline: Instant,
    upstream_origin: &str,
) -> (Body, CompanionResponseLease) {
    stream_body(upstream, deadline, upstream_origin)
}

fn stream_body<B>(
    upstream: B,
    deadline: Instant,
    upstream_origin: &str,
) -> (Body, CompanionResponseLease)
where
    B: HttpBody<Data = Bytes> + Send + Unpin + 'static,
    B::Error: Into<BoxError> + Send + 'static,
{
    let (sender, receiver) = mpsc::channel(1);
    let timed_out = Arc::new(AtomicBool::new(false));
    let lease = CompanionResponseLease::new();
    tokio::spawn(pump_upstream(
        upstream,
        sender,
        deadline,
        upstream_origin.to_owned(),
        Arc::clone(&timed_out),
        lease.clone(),
    ));
    let body = CompanionResponseBody {
        receiver,
        timed_out,
        timeout_emitted: false,
        lease: lease.clone(),
    };
    (Body::new(body), lease)
}

async fn pump_upstream<B>(
    mut upstream: B,
    sender: mpsc::Sender<PumpItem>,
    deadline: Instant,
    upstream_origin: String,
    timed_out: Arc<AtomicBool>,
    lease: CompanionResponseLease,
) where
    B: HttpBody<Data = Bytes> + Send + Unpin + 'static,
    B::Error: Into<BoxError> + Send + 'static,
{
    loop {
        let next = tokio::select! {
            () = sender.closed() => break,
            next = timeout_at(deadline, upstream.frame()) => next,
        };
        let frame = match next {
            Ok(Some(frame)) => frame.map_err(Into::into),
            Ok(None) => break,
            Err(_) => {
                record_timeout(&timed_out, &upstream_origin);
                break;
            }
        };
        let failed = frame.is_err();
        match timeout_at(deadline, sender.send(frame)).await {
            Ok(Ok(())) if !failed => {}
            Ok(Ok(()) | Err(_)) => break,
            Err(_) => {
                record_timeout(&timed_out, &upstream_origin);
                break;
            }
        }
    }
    lease.finish();
}

fn record_timeout(timed_out: &AtomicBool, upstream_origin: &str) {
    timed_out.store(true, Ordering::Release);
    tracing::warn!(
        upstream = upstream_origin,
        "companion upstream response body timed out"
    );
}

struct CompanionResponseBody {
    receiver: mpsc::Receiver<PumpItem>,
    timed_out: Arc<AtomicBool>,
    timeout_emitted: bool,
    lease: CompanionResponseLease,
}

impl Drop for CompanionResponseBody {
    fn drop(&mut self) {
        self.lease.finish();
    }
}

impl HttpBody for CompanionResponseBody {
    type Data = Bytes;
    type Error = BoxError;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        let this = self.get_mut();
        match this.receiver.poll_recv(cx) {
            Poll::Ready(None)
                if this.timed_out.load(Ordering::Acquire) && !this.timeout_emitted =>
            {
                this.timeout_emitted = true;
                Poll::Ready(Some(Err(IoError::new(
                    ErrorKind::TimedOut,
                    "companion upstream response body timed out",
                )
                .into())))
            }
            Poll::Ready(frame) => Poll::Ready(frame),
            Poll::Pending => Poll::Pending,
        }
    }

    fn is_end_stream(&self) -> bool {
        self.receiver.is_closed()
            && self.receiver.is_empty()
            && (!self.timed_out.load(Ordering::Acquire) || self.timeout_emitted)
    }
}

#[cfg(test)]
mod tests {
    use std::convert::Infallible;
    use std::pin::Pin;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::task::{Context, Poll};
    use std::time::Duration;

    use axum::body::Body;
    use axum::response::Response;
    use bytes::Bytes;
    use futures_util::stream;
    use http_body_util::StreamBody;
    use hyper::body::{Body as HttpBody, Frame};
    use tokio::sync::Semaphore;
    use tokio::time::Instant;

    use super::{bind_response_permits, stream_body};

    struct PendingDropBody {
        dropped: Arc<AtomicBool>,
    }

    impl Drop for PendingDropBody {
        fn drop(&mut self) {
            self.dropped.store(true, Ordering::Release);
        }
    }

    impl HttpBody for PendingDropBody {
        type Data = Bytes;
        type Error = Infallible;

        fn poll_frame(
            self: Pin<&mut Self>,
            _cx: &mut Context<'_>,
        ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
            Poll::Pending
        }
    }

    #[test]
    fn core_response_releases_the_global_permit_after_headers() {
        let permits = Arc::new(Semaphore::new(1));
        let permit = Arc::clone(&permits).try_acquire_owned().expect("permit");

        let response = bind_response_permits(Response::new(Body::empty()), permit, None);

        assert_eq!(permits.available_permits(), 1);
        drop(response);
    }

    #[tokio::test]
    async fn dropping_the_client_body_releases_both_companion_permits() {
        let upstream_dropped = Arc::new(AtomicBool::new(false));
        let upstream = PendingDropBody {
            dropped: Arc::clone(&upstream_dropped),
        };
        let (body, lease) = stream_body(
            upstream,
            Instant::now() + Duration::from_secs(60),
            "http://127.0.0.1:8787",
        );
        let mut response = Response::new(body);
        response.extensions_mut().insert(lease);
        let global = Arc::new(Semaphore::new(1));
        let companion = Arc::new(Semaphore::new(1));
        let response = bind_response_permits(
            response,
            Arc::clone(&global).try_acquire_owned().expect("global"),
            Some(
                Arc::clone(&companion)
                    .try_acquire_owned()
                    .expect("companion"),
            ),
        );

        assert_eq!(global.available_permits(), 0);
        assert_eq!(companion.available_permits(), 0);
        drop(response);
        tokio::task::yield_now().await;
        assert_eq!(global.available_permits(), 1);
        assert_eq!(companion.available_permits(), 1);
        assert!(upstream_dropped.load(Ordering::Acquire));
    }

    #[tokio::test(start_paused = true)]
    async fn deadline_releases_permits_while_downstream_is_backpressured() {
        let frames = stream::iter([
            Ok::<_, Infallible>(Frame::data(Bytes::from_static(b"first"))),
            Ok(Frame::data(Bytes::from_static(b"second"))),
        ]);
        let deadline = Instant::now() + Duration::from_secs(60);
        let (body, lease) = stream_body(StreamBody::new(frames), deadline, "http://127.0.0.1:8787");
        let mut response = Response::new(body);
        response.extensions_mut().insert(lease);
        let global = Arc::new(Semaphore::new(1));
        let companion = Arc::new(Semaphore::new(1));
        let response = bind_response_permits(
            response,
            Arc::clone(&global).try_acquire_owned().expect("global"),
            Some(
                Arc::clone(&companion)
                    .try_acquire_owned()
                    .expect("companion"),
            ),
        );
        tokio::task::yield_now().await;
        assert_eq!(global.available_permits(), 0);
        assert_eq!(companion.available_permits(), 0);

        tokio::time::advance(Duration::from_secs(61)).await;
        tokio::task::yield_now().await;

        assert_eq!(global.available_permits(), 1);
        assert_eq!(companion.available_permits(), 1);
        drop(response);
    }
}
