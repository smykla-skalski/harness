#![deny(unsafe_code)]

mod execute;
mod remote;
mod remote_acme;
mod remote_clients;
mod remote_companion_activation;
mod remote_doctor;
mod remote_pair_reviews;
mod remote_serve;
mod remote_serve_startup;
mod systemd_state;
#[cfg(test)]
mod tests;

pub use execute::execute_remote_command;
pub use remote::*;
