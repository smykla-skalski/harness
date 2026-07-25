# Harness panel

The panel is a companion web service. Someone signs in with GitHub, the panel records their account, and the daemon serves the panel to the public internet on its own HTTPS listener. It exists so getting a pairing link stops requiring shell access to the daemon host.

The panel never links against the `harness` crate. It reaches the daemon the same way any other client does, over the daemon's public HTTP API, and `scripts/check-binary-contracts.sh` fails the build if that ever stops being true.

## What this version does

Sign-in, and the owner's view of who has signed in. Generating a pairing link from the panel is not part of it yet; the personal page says so. Until it lands, links still come from `harness-daemon remote pair create` on the host.

## How it fits together

The daemon forwards one path subtree to the panel over loopback:

```bash
harness-daemon remote serve \
  --domain harness.example.com \
  --companion-upstream http://127.0.0.1:8787 \
  --companion-path-prefix /panel
```

The prefix is forwarded verbatim, so the panel serves its own routes under `/panel/...` and `--base-path` has to match `--companion-path-prefix`. The daemon exempts that subtree from remote bearer auth, because the panel authenticates people itself; its body, URI, and header limits still apply.

Everything absolute the panel produces, including the OAuth `redirect_uri`, is built from `--public-origin` and `--base-path`. It never derives its origin from forwarded headers, so whoever can reach the loopback listener cannot choose where GitHub sends an authorization code.

## GitHub OAuth app

Register an OAuth app owned by whoever runs the panel, with:

- Homepage URL `https://harness.example.com/panel/`
- Authorization callback URL `https://harness.example.com/panel/auth/github/callback`

The panel requests `read:user` and nothing else. The access token is used once, to read the profile, and is never stored.

Write the client secret to a file the service can read and nobody else can:

```bash
sudo install -d -m 0700 /etc/harness-panel
printf '%s' "$GITHUB_CLIENT_SECRET" | sudo tee /etc/harness-panel/github-client-secret >/dev/null
sudo chmod 0400 /etc/harness-panel/github-client-secret
```

The panel refuses to start if that file is readable by group or other. It is never taken as a flag value or an environment string, both of which any local process can read out of `/proc`.

## Installing

```bash
mise run install:harness:panel
```

Then render the unit, read it, and install it:

```bash
harness-panel print-unit \
  --public-origin https://harness.example.com \
  --base-path /panel \
  --state-dir /var/lib/harness-panel \
  --github-client-id Iv1.abc123 \
  --github-client-secret-file /etc/harness-panel/github-client-secret \
  --owner-login your-github-login \
  | sudo tee /etc/systemd/system/harness-panel.service

sudo systemctl daemon-reload
sudo systemctl enable --now harness-panel.service
```

`print-unit` reads nothing off disk, so it works on a host where the secret file does not exist yet.

It ignores `--state-dir`. The rendered unit always points the panel at `%S/<unit>`, the directory `StateDirectory=` creates for it, because `ProtectSystem=strict` leaves nowhere else writable. The flag is still required because `serve` and `print-unit` take the same arguments; pass anything, or pass the path you would use when running the panel by hand.

The rendered unit runs under `DynamicUser=yes` with an empty capability bounding set, and takes the client secret through `LoadCredential=`, which re-exposes it as mode 0400 owned by that transient user. `systemd-analyze security` scores it 1.1. What it still counts against the unit is inherent to the job: the panel has host network access, allocates Internet sockets, and pins no IP allow list, because GitHub's address ranges rotate and a stale list would take sign-in down without a word.

## Checking it

```bash
curl -fsS http://127.0.0.1:8787/panel/healthz
```

`"assets":"bundled"` means the binary carries the real web app. `"assets":"placeholder"` means it was built with `HARNESS_PANEL_SKIP_FRONTEND_BUILD=1` and serves a stand-in page; rebuild it with Node available.

Then open `https://harness.example.com/panel/` and sign in. The owner also sees everyone else who has signed in; nobody else does.

## Who owns the panel

`--owner-login` names a GitHub login, and a login is not a person: renaming one frees the old name for anyone to register. So the flag decides only who the panel is claimed for, once. The first time somebody whose login matches it signs in, the panel records their immutable GitHub account id and answers "is this the owner" from that pair from then on. Renaming the owner's login does not cost them the panel, and picking up their old name does not gain it.

The flag is matched without regard to case, because GitHub treats logins that way and the flag is typed by hand.

Re-pointing a panel at a different owner therefore means changing `--owner-login` *and* deleting the recorded claim:

```bash
sudo systemctl stop harness-panel
sudo sqlite3 /var/lib/harness-panel/panel.sqlite3 'DELETE FROM owner_binding'
sudo systemctl start harness-panel
```

The next sign-in by someone matching the new `--owner-login` claims it. Changing the flag alone does nothing, which is the point: it is not what ownership rests on.

## Upgrading

Stop the unit, install the new binary, start it again. The panel has no transactional upgrade path through the `harness-systemd` controller the way the remote daemon does; that is tracked in #604. Do not assume `daemon:remote:deploy` touches it.

## Where its state lives

One SQLite database under the state directory, holding accounts, sessions, and sign-ins in flight. The directory is created mode 0700 and the database stores only the SHA-256 of a session token, so a copy of it is not a set of working sessions. Deleting the database signs everyone out and forgets who has signed in; it costs nothing else.

## Developing

The web app is Svelte and TypeScript under `crates/harness-panel/frontend`, built by Vite and embedded into the binary by the crate's build script. Building the crate builds the assets, so Node has to be on `PATH`; `mise` pins it.

```bash
mise run panel:frontend:install   # once, or after the lockfile changes
mise run panel:frontend:lint
mise run panel:frontend:test
```

Vite bakes the mount point into its asset URLs at build time, but `--base-path` is chosen at start, so the bundle is built against the sentinel `/__harness_panel_base__` and the serving binary substitutes the configured prefix into `index.html`. Only `index.html` mentions the sentinel. If you change `base` in `vite.config.ts`, change `BASE_PATH_SENTINEL` in `src/assets.rs` and the `harness-panel-base` meta tag with it.
