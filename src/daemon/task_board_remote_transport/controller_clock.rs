#[cfg(test)]
use std::collections::VecDeque;
#[cfg(test)]
use std::sync::Mutex;

use crate::daemon::db::utc_now;

#[derive(Debug)]
pub(super) enum ControllerClock {
    System,
    #[cfg(test)]
    Queued(Mutex<VecDeque<String>>),
}

impl ControllerClock {
    pub(super) fn now(&self) -> String {
        match self {
            Self::System => utc_now(),
            #[cfg(test)]
            Self::Queued(times) => times
                .lock()
                .expect("controller test clock lock")
                .pop_front()
                .expect("controller test clock exhausted"),
        }
    }

    #[cfg(test)]
    pub(super) fn queued(times: impl IntoIterator<Item = String>) -> Self {
        Self::Queued(Mutex::new(times.into_iter().collect()))
    }
}
