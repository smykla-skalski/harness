//! Cancellation-safe upstream body relay with optional ordinary deadline.

use std::io::{Error as IoError, ErrorKind};
use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::task::{Context, Poll};

use axum::BoxError;
use axum::body::Body;
use bytes::Bytes;
use http_body_util::BodyExt as _;
use hyper::body::{Body as HttpBody, Frame};
use tokio::sync::{OwnedSemaphorePermit, mpsc};
use tokio::time::{Instant, timeout_at};

type PumpItem = Result<Frame<Bytes>, BoxError>;

pub(super) fn relay<B>(upstream: B, deadline: Option<Instant>, permit: OwnedSemaphorePermit) -> Body
where
    B: HttpBody<Data = Bytes> + Send + Unpin + 'static,
    B::Error: Into<BoxError> + Send + 'static,
{
    let (sender, receiver) = mpsc::channel(1);
    let timed_out = Arc::new(AtomicBool::new(false));
    tokio::spawn(pump(
        upstream,
        sender,
        deadline,
        Arc::clone(&timed_out),
        permit,
    ));
    Body::new(SybraResponseBody {
        receiver,
        timed_out,
        timeout_emitted: false,
    })
}

async fn pump<B>(
    mut upstream: B,
    sender: mpsc::Sender<PumpItem>,
    deadline: Option<Instant>,
    timed_out: Arc<AtomicBool>,
    _permit: OwnedSemaphorePermit,
) where
    B: HttpBody<Data = Bytes> + Send + Unpin + 'static,
    B::Error: Into<BoxError> + Send + 'static,
{
    loop {
        let next = next_frame(&mut upstream, &sender, deadline, &timed_out).await;
        let Some(frame) = next else {
            break;
        };
        let failed = frame.is_err();
        if !send_frame(&sender, frame, deadline, &timed_out).await || failed {
            break;
        }
    }
}

async fn next_frame<B>(
    upstream: &mut B,
    sender: &mpsc::Sender<PumpItem>,
    deadline: Option<Instant>,
    timed_out: &AtomicBool,
) -> Option<PumpItem>
where
    B: HttpBody<Data = Bytes> + Send + Unpin + 'static,
    B::Error: Into<BoxError> + Send + 'static,
{
    tokio::select! {
        () = sender.closed() => None,
        next = async {
            match deadline {
                Some(deadline) => if let Ok(next) = timeout_at(deadline, upstream.frame()).await {
                    next
                } else {
                    timed_out.store(true, Ordering::Release);
                    None
                },
                None => upstream.frame().await,
            }
        } => next.map(|frame| frame.map_err(Into::into)),
    }
}

async fn send_frame(
    sender: &mpsc::Sender<PumpItem>,
    frame: PumpItem,
    deadline: Option<Instant>,
    timed_out: &AtomicBool,
) -> bool {
    match deadline {
        Some(deadline) => {
            if let Ok(result) = timeout_at(deadline, sender.send(frame)).await {
                result.is_ok()
            } else {
                timed_out.store(true, Ordering::Release);
                false
            }
        }
        None => sender.send(frame).await.is_ok(),
    }
}

struct SybraResponseBody {
    receiver: mpsc::Receiver<PumpItem>,
    timed_out: Arc<AtomicBool>,
    timeout_emitted: bool,
}

impl HttpBody for SybraResponseBody {
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
                Poll::Ready(Some(Err(timeout_error())))
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

pub(super) fn timeout_error() -> BoxError {
    IoError::new(
        ErrorKind::TimedOut,
        "Sybra upstream response body timed out",
    )
    .into()
}
