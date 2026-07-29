use std::future::Future;
use std::sync::Arc;

use tokio::sync::Notify;

tokio::task_local! {
    static START_AUTHORIZATION_PAUSE: StartAuthorizationPause;
}

#[derive(Clone)]
pub(super) struct StartAuthorizationPause {
    reached: Arc<Notify>,
    resume: Arc<Notify>,
}

impl StartAuthorizationPause {
    pub(super) fn new() -> Self {
        Self {
            reached: Arc::new(Notify::new()),
            resume: Arc::new(Notify::new()),
        }
    }

    pub(super) async fn scope<F>(&self, future: F) -> F::Output
    where
        F: Future,
    {
        START_AUTHORIZATION_PAUSE.scope(self.clone(), future).await
    }

    pub(super) async fn wait_until_reached(&self) {
        self.reached.notified().await;
    }

    pub(super) fn resume(&self) {
        self.resume.notify_one();
    }
}

pub(super) async fn pause_before_final_authorization() {
    let pause = START_AUTHORIZATION_PAUSE.try_with(Clone::clone).ok();
    if let Some(pause) = pause {
        pause.reached.notify_one();
        pause.resume.notified().await;
    }
}
