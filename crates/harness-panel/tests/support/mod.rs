//! A stub GitHub and a panel bound to a real port, for the sign-in tests.

use std::fs;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use axum::Json;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::http::header::AUTHORIZATION;
use axum::routing::{get, post};
use axum::{Form, Router};
use harness_panel::config::{DEFAULT_GITHUB_AUTHORIZE_URL, PanelArgs};
use harness_panel::http::{PanelState, router};
use harness_panel::store::Store;
use reqwest::header::{COOKIE, LOCATION, ORIGIN, SET_COOKIE};
use reqwest::redirect::Policy;
use reqwest::{Client, RequestBuilder, Response, StatusCode};
use serde::{Deserialize, Serialize};
use tokio::net::TcpListener;
use url::Url;

/// The only authorization code the stub will exchange. Anything else stands in
/// for a code GitHub has already spent or expired.
const VALID_CODE: &str = "valid-code";
const ACCESS_TOKEN: &str = "gho_stub_token";

#[derive(Debug, Clone, Serialize)]
struct StubUser {
    id: u64,
    login: String,
    name: Option<String>,
    avatar_url: Option<String>,
}

#[derive(Clone)]
struct StubState {
    user: Arc<Mutex<StubUser>>,
    exchanges: Arc<AtomicUsize>,
    profile_reads: Arc<AtomicUsize>,
}

/// Stands in for GitHub's OAuth and REST endpoints.
pub struct GitHubStub {
    base_url: String,
    state: StubState,
}

impl GitHubStub {
    pub async fn start(login: &str, id: u64) -> Self {
        let state = StubState {
            user: Arc::new(Mutex::new(StubUser {
                id,
                login: login.to_owned(),
                name: Some(format!("{login} display")),
                avatar_url: Some("https://avatars.example.com/x.png".to_owned()),
            })),
            exchanges: Arc::new(AtomicUsize::new(0)),
            profile_reads: Arc::new(AtomicUsize::new(0)),
        };

        let app = Router::new()
            .route("/login/oauth/access_token", post(access_token))
            .route("/user", get(user))
            .with_state(state.clone());
        let base_url = spawn(app).await;

        Self { base_url, state }
    }

    /// Change who the next sign-in reports, standing in for a rename or a
    /// different person at the keyboard.
    pub fn become_user(&self, login: &str, id: u64) {
        let mut user = self.state.user.lock().expect("stub user lock");
        user.id = id;
        login.clone_into(&mut user.login);
        user.name = Some(format!("{login} display"));
    }

    pub fn token_url(&self) -> String {
        format!("{}/login/oauth/access_token", self.base_url)
    }

    pub fn api_url(&self) -> String {
        self.base_url.clone()
    }

    pub fn token_exchanges(&self) -> usize {
        self.state.exchanges.load(Ordering::SeqCst)
    }

    pub fn profile_reads(&self) -> usize {
        self.state.profile_reads.load(Ordering::SeqCst)
    }
}

#[derive(Debug, Deserialize)]
struct TokenRequest {
    code: String,
}

/// GitHub answers a code it will not honour with HTTP 200 and an `error` field
/// rather than a failure status, and the panel has to cope with that.
async fn access_token(
    State(state): State<StubState>,
    Form(request): Form<TokenRequest>,
) -> Json<serde_json::Value> {
    state.exchanges.fetch_add(1, Ordering::SeqCst);
    if request.code == VALID_CODE {
        Json(serde_json::json!({
            "access_token": ACCESS_TOKEN,
            "token_type": "bearer",
            "scope": "read:user",
        }))
    } else {
        Json(serde_json::json!({
            "error": "bad_verification_code",
            "error_description": "The code passed is incorrect or expired.",
        }))
    }
}

async fn user(
    State(state): State<StubState>,
    headers: HeaderMap,
) -> Result<Json<StubUser>, StatusCode> {
    let presented = headers
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default();
    if presented != format!("Bearer {ACCESS_TOKEN}") {
        return Err(StatusCode::UNAUTHORIZED);
    }
    state.profile_reads.fetch_add(1, Ordering::SeqCst);
    Ok(Json(state.user.lock().expect("stub user lock").clone()))
}

/// A panel bound to a loopback port, reached the way a browser reaches it.
pub struct PanelUnderTest {
    base_url: String,
    client: Client,
    _directory: tempfile::TempDir,
}

impl PanelUnderTest {
    pub async fn start(github: &GitHubStub, owner_login: &str) -> Self {
        let directory = tempfile::tempdir().expect("temp dir");
        let secret = directory.path().join("secret");
        fs::write(&secret, "s3cret").expect("writing the secret");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&secret, fs::Permissions::from_mode(0o600))
                .expect("restricting the secret");
        }

        // The listener is bound first so the public origin can name the port
        // the panel actually got, which is what the callback URL is built from.
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let address = listener.local_addr().expect("local address");

        let args = PanelArgs {
            listen: address,
            public_origin: format!("http://127.0.0.1:{}", address.port()),
            base_path: "/panel".to_owned(),
            state_dir: directory.path().join("state"),
            github_client_id: "Iv1.stub".to_owned(),
            github_client_secret_file: secret,
            owner_login: owner_login.to_owned(),
            github_authorize_url: DEFAULT_GITHUB_AUTHORIZE_URL.to_owned(),
            github_token_url: github.token_url(),
            github_api_url: github.api_url(),
            session_ttl_hours: 12,
        };
        let config = args.resolve().expect("valid configuration");
        let base_url = config.public_origin.clone();
        let store = Store::open(&config.state_dir).await.expect("store");
        let state = PanelState::new(config, store).expect("panel state");

        tokio::spawn(async move {
            axum::serve(listener, router(state)).await.ok();
        });

        Self {
            base_url,
            // Following the redirect would send the test to github.com, and
            // each hop is what these tests are checking.
            client: Client::builder()
                .redirect(Policy::none())
                .build()
                .expect("client"),
            _directory: directory,
        }
    }

    pub async fn get(&self, path: &str, cookie: Option<&str>) -> Response {
        self.send(self.client.get(format!("{}{path}", self.base_url)), cookie)
            .await
    }

    pub async fn post(&self, path: &str, cookie: Option<&str>) -> Response {
        self.send(
            self.client
                .post(format!("{}{path}", self.base_url))
                .header(ORIGIN, &self.base_url),
            cookie,
        )
        .await
    }

    async fn send(&self, request: RequestBuilder, cookie: Option<&str>) -> Response {
        let request = match cookie {
            Some(cookie) => request.header(COOKIE, cookie),
            None => request,
        };
        request.send().await.expect("the panel answers")
    }

    /// Drive a whole sign-in and return the session cookie it produced.
    pub async fn sign_in(&self) -> String {
        let start = self.get("/panel/auth/github/start", None).await;
        let sign_in_cookie = sign_in_cookie(&start);
        let state = state_from_authorize_url(&location(&start));
        let callback = self
            .get(
                &format!("/panel/auth/github/callback?code={VALID_CODE}&state={state}"),
                Some(&sign_in_cookie),
            )
            .await;
        assert_eq!(
            callback.status(),
            StatusCode::SEE_OTHER,
            "sign-in should have succeeded"
        );
        session_cookie(&callback)
    }
}

async fn spawn(app: Router) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let address = listener.local_addr().expect("local address");
    tokio::spawn(async move {
        axum::serve(listener, app).await.ok();
    });
    format!("http://127.0.0.1:{}", address.port())
}

pub fn location(response: &Response) -> String {
    response
        .headers()
        .get(LOCATION)
        .and_then(|value| value.to_str().ok())
        .expect("a redirect")
        .to_owned()
}

pub fn sign_in_cookie(response: &Response) -> String {
    cookie_with_prefix(response, "harness_panel_signin_")
}

pub fn session_cookie(response: &Response) -> String {
    cookie_named(response, "harness_panel_session")
}

fn cookie_named(response: &Response, name: &str) -> String {
    response
        .headers()
        .get_all(SET_COOKIE)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .find(|value| value.starts_with(&format!("{name}=")))
        .and_then(|value| value.split(';').next())
        .unwrap_or_else(|| panic!("no {name} cookie was set"))
        .to_owned()
}

fn cookie_with_prefix(response: &Response, prefix: &str) -> String {
    response
        .headers()
        .get_all(SET_COOKIE)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .find(|value| value.starts_with(prefix))
        .and_then(|value| value.split(';').next())
        .unwrap_or_else(|| panic!("no {prefix} cookie was set"))
        .to_owned()
}

pub fn state_from_authorize_url(authorize_url: &str) -> String {
    Url::parse(authorize_url)
        .expect("an authorize url")
        .query_pairs()
        .find(|(key, _)| key == "state")
        .map(|(_, value)| value.into_owned())
        .expect("the authorize url carries a state")
}
