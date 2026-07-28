mod client;
#[cfg(test)]
mod fake;
#[cfg(test)]
mod tests;
mod types;

pub use client::{HttpClient, ReqwestHttpClient};
#[cfg(test)]
pub use fake::FakeHttpClient;
pub use types::{HttpMethod, HttpResponse};
