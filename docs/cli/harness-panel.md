# Command-Line Help for `harness-panel`

This document contains the help content for the `harness-panel` command-line program.

**Command Overview:**

* [`harness-panel`↴](#harness-panel)
* [`harness-panel serve`↴](#harness-panel-serve)
* [`harness-panel pair`↴](#harness-panel-pair)
* [`harness-panel print-unit`↴](#harness-panel-print-unit)
* [`harness-panel print-socket-unit`↴](#harness-panel-print-socket-unit)

## `harness-panel`

Harness panel: GitHub sign-in and account roster

**Usage:** `harness-panel <COMMAND>`

###### **Subcommands:**

* `serve` — Serve the panel
* `pair` — Claim the daemon credential the panel mints with, once
* `print-unit` — Print the hardened systemd service for review before it is installed
* `print-socket-unit` — Print the systemd socket that reserves the panel listener across service restarts



## `harness-panel serve`

Serve the panel

**Usage:** `harness-panel serve [OPTIONS] --public-origin <PUBLIC_ORIGIN> --state-dir <STATE_DIR> --companion-auth-token-file <COMPANION_AUTH_TOKEN_FILE> --github-client-id <GITHUB_CLIENT_ID> --github-client-secret-file <GITHUB_CLIENT_SECRET_FILE> --owner-login <OWNER_LOGIN> --daemon-endpoint <DAEMON_ENDPOINT> --daemon-spki-pin <DAEMON_SPKI_PIN>`

###### **Options:**

* `--listen <LISTEN>` — Address to serve on. Bind loopback and let the daemon forward to it

  Default value: `127.0.0.1:8787`
* `--public-origin <PUBLIC_ORIGIN>` — Origin the panel is reached at, such as `https://harness.example.com`
* `--base-path <BASE_PATH>` — Path subtree the panel is mounted under, matching the daemon's `--companion-path-prefix`. Use `/` to serve the origin root

  Default value: `/panel`
* `--state-dir <STATE_DIR>` — Directory holding the panel's `SQLite` database
* `--companion-auth-token-file <COMPANION_AUTH_TOKEN_FILE>` — File holding the private token the daemon presents on every forwarded request
* `--github-client-id <GITHUB_CLIENT_ID>` — GitHub OAuth app client id
* `--github-client-secret-file <GITHUB_CLIENT_SECRET_FILE>` — File holding the GitHub OAuth app client secret. The secret is never taken as a flag value or an environment string, both of which any local process can read out of `/proc`
* `--owner-login <OWNER_LOGIN>` — GitHub login of the person who owns this panel
* `--github-authorize-url <GITHUB_AUTHORIZE_URL>` — Authorization endpoint. Override for GitHub Enterprise

  Default value: `https://github.com/login/oauth/authorize`
* `--github-token-url <GITHUB_TOKEN_URL>` — Access-token endpoint. Override for GitHub Enterprise

  Default value: `https://github.com/login/oauth/access_token`
* `--github-api-url <GITHUB_API_URL>` — REST API base. Override for GitHub Enterprise

  Default value: `https://api.github.com`
* `--session-ttl-hours <SESSION_TTL_HOURS>` — How long a signed-in session stays valid

  Default value: `12`
* `--daemon-endpoint <DAEMON_ENDPOINT>` — The daemon's public origin, such as `https://harness.example.com`
* `--daemon-spki-pin <DAEMON_SPKI_PIN>` — The daemon's certificate pin, as `sha256/<base64>`. Every pairing invitation the daemon issues carries the same value
* `--pair-link-role <PAIR_LINK_ROLE>` — The role every link the panel mints grants

  Default value: `operator`
* `--pair-link-ttl-seconds <PAIR_LINK_TTL_SECONDS>` — How long a minted link stays claimable

  Default value: `600`



## `harness-panel pair`

Claim the daemon credential the panel mints with, once.

Separate from `serve` because the code is one-time: left in a unit file it would be spent on the first start and refused on every restart.

**Usage:** `harness-panel pair [OPTIONS] --public-origin <PUBLIC_ORIGIN> --state-dir <STATE_DIR> --companion-auth-token-file <COMPANION_AUTH_TOKEN_FILE> --github-client-id <GITHUB_CLIENT_ID> --github-client-secret-file <GITHUB_CLIENT_SECRET_FILE> --owner-login <OWNER_LOGIN> --daemon-endpoint <DAEMON_ENDPOINT> --daemon-spki-pin <DAEMON_SPKI_PIN> --code-file <CODE_FILE>`

###### **Options:**

* `--listen <LISTEN>` — Address to serve on. Bind loopback and let the daemon forward to it

  Default value: `127.0.0.1:8787`
* `--public-origin <PUBLIC_ORIGIN>` — Origin the panel is reached at, such as `https://harness.example.com`
* `--base-path <BASE_PATH>` — Path subtree the panel is mounted under, matching the daemon's `--companion-path-prefix`. Use `/` to serve the origin root

  Default value: `/panel`
* `--state-dir <STATE_DIR>` — Directory holding the panel's `SQLite` database
* `--companion-auth-token-file <COMPANION_AUTH_TOKEN_FILE>` — File holding the private token the daemon presents on every forwarded request
* `--github-client-id <GITHUB_CLIENT_ID>` — GitHub OAuth app client id
* `--github-client-secret-file <GITHUB_CLIENT_SECRET_FILE>` — File holding the GitHub OAuth app client secret. The secret is never taken as a flag value or an environment string, both of which any local process can read out of `/proc`
* `--owner-login <OWNER_LOGIN>` — GitHub login of the person who owns this panel
* `--github-authorize-url <GITHUB_AUTHORIZE_URL>` — Authorization endpoint. Override for GitHub Enterprise

  Default value: `https://github.com/login/oauth/authorize`
* `--github-token-url <GITHUB_TOKEN_URL>` — Access-token endpoint. Override for GitHub Enterprise

  Default value: `https://github.com/login/oauth/access_token`
* `--github-api-url <GITHUB_API_URL>` — REST API base. Override for GitHub Enterprise

  Default value: `https://api.github.com`
* `--session-ttl-hours <SESSION_TTL_HOURS>` — How long a signed-in session stays valid

  Default value: `12`
* `--daemon-endpoint <DAEMON_ENDPOINT>` — The daemon's public origin, such as `https://harness.example.com`
* `--daemon-spki-pin <DAEMON_SPKI_PIN>` — The daemon's certificate pin, as `sha256/<base64>`. Every pairing invitation the daemon issues carries the same value
* `--pair-link-role <PAIR_LINK_ROLE>` — The role every link the panel mints grants

  Default value: `operator`
* `--pair-link-ttl-seconds <PAIR_LINK_TTL_SECONDS>` — How long a minted link stays claimable

  Default value: `600`
* `--code-file <CODE_FILE>` — File holding the one-time pairing code. A file rather than a flag value, which any local process can read out of `/proc`



## `harness-panel print-unit`

Print the hardened systemd service for review before it is installed

**Usage:** `harness-panel print-unit [OPTIONS] --public-origin <PUBLIC_ORIGIN> --state-dir <STATE_DIR> --companion-auth-token-file <COMPANION_AUTH_TOKEN_FILE> --github-client-id <GITHUB_CLIENT_ID> --github-client-secret-file <GITHUB_CLIENT_SECRET_FILE> --owner-login <OWNER_LOGIN> --daemon-endpoint <DAEMON_ENDPOINT> --daemon-spki-pin <DAEMON_SPKI_PIN>`

###### **Options:**

* `--listen <LISTEN>` — Address to serve on. Bind loopback and let the daemon forward to it

  Default value: `127.0.0.1:8787`
* `--public-origin <PUBLIC_ORIGIN>` — Origin the panel is reached at, such as `https://harness.example.com`
* `--base-path <BASE_PATH>` — Path subtree the panel is mounted under, matching the daemon's `--companion-path-prefix`. Use `/` to serve the origin root

  Default value: `/panel`
* `--state-dir <STATE_DIR>` — Directory holding the panel's `SQLite` database
* `--companion-auth-token-file <COMPANION_AUTH_TOKEN_FILE>` — File holding the private token the daemon presents on every forwarded request
* `--github-client-id <GITHUB_CLIENT_ID>` — GitHub OAuth app client id
* `--github-client-secret-file <GITHUB_CLIENT_SECRET_FILE>` — File holding the GitHub OAuth app client secret. The secret is never taken as a flag value or an environment string, both of which any local process can read out of `/proc`
* `--owner-login <OWNER_LOGIN>` — GitHub login of the person who owns this panel
* `--github-authorize-url <GITHUB_AUTHORIZE_URL>` — Authorization endpoint. Override for GitHub Enterprise

  Default value: `https://github.com/login/oauth/authorize`
* `--github-token-url <GITHUB_TOKEN_URL>` — Access-token endpoint. Override for GitHub Enterprise

  Default value: `https://github.com/login/oauth/access_token`
* `--github-api-url <GITHUB_API_URL>` — REST API base. Override for GitHub Enterprise

  Default value: `https://api.github.com`
* `--session-ttl-hours <SESSION_TTL_HOURS>` — How long a signed-in session stays valid

  Default value: `12`
* `--daemon-endpoint <DAEMON_ENDPOINT>` — The daemon's public origin, such as `https://harness.example.com`
* `--daemon-spki-pin <DAEMON_SPKI_PIN>` — The daemon's certificate pin, as `sha256/<base64>`. Every pairing invitation the daemon issues carries the same value
* `--pair-link-role <PAIR_LINK_ROLE>` — The role every link the panel mints grants

  Default value: `operator`
* `--pair-link-ttl-seconds <PAIR_LINK_TTL_SECONDS>` — How long a minted link stays claimable

  Default value: `600`
* `--unit <UNIT>` — Unit name, which also names the state directory

  Default value: `harness-panel`
* `--binary-path <BINARY_PATH>` — Path the unit starts the panel from

  Default value: `/usr/local/bin/harness-panel`



## `harness-panel print-socket-unit`

Print the systemd socket that reserves the panel listener across service restarts

**Usage:** `harness-panel print-socket-unit [OPTIONS]`

###### **Options:**

* `--listen <LISTEN>` — Address systemd owns and passes to the panel service

  Default value: `127.0.0.1:8787`
* `--unit <UNIT>` — Unit stem shared by the socket and service

  Default value: `harness-panel`



<hr/>

<small><i>
    This document was generated automatically by
    <a href="https://crates.io/crates/clap-markdown"><code>clap-markdown</code></a>.
</i></small>

