use super::remote::RemoteRole;
use super::remote_identity::RemoteStoredClient;

#[must_use]
pub(crate) fn is_remote_viewer(client: Option<&RemoteStoredClient>) -> bool {
    client.is_some_and(|client| client.role == RemoteRole::Viewer)
}
