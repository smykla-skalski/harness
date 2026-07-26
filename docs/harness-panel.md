# Harness panel

The panel is a companion web service. Someone signs in with GitHub, the panel records their account, and the daemon serves the panel to the public internet on its own HTTPS listener. It exists so getting a pairing link stops requiring shell access to the daemon host.

The panel never links against the `harness` crate. It reaches the daemon the same way any other client does, over the daemon's public HTTP API, and `scripts/check-binary-contracts.sh` fails the build if that ever stops being true.

## What this version does

Sign-in, the owner's view of who has signed in, approval, and self-service pairing links. Someone signs in, the owner approves them, and they generate their own link.

## Daemon-to-panel credential

The daemon and panel share a dedicated proxy token that is separate from the GitHub client secret. The token must contain at least 32 bytes of visible ASCII; `openssl rand -hex 32` produces 32 random bytes as 64 hexadecimal characters.

These commands assume a Linux host with OpenSSL, `sudo` access, and either no existing token or an existing token that must remain unchanged. They are safe to rerun because an existing token is left in place.

```bash
sudo install -d -m 0700 /etc/harness-panel
if ! sudo test -e /etc/harness-panel/companion-auth-token; then
  companion_token_tmp="$(mktemp)" || exit 1
  if openssl rand -hex 32 >"$companion_token_tmp" &&
      sudo install -m 0400 "$companion_token_tmp" /etc/harness-panel/companion-auth-token; then
    printf 'created companion authentication token\n'
  else
    rm -f "$companion_token_tmp"
    unset companion_token_tmp
    exit 1
  fi
  rm -f "$companion_token_tmp"
  unset companion_token_tmp
fi
```

Both services receive the same source file through `LoadCredential=`. The panel rejects every direct loopback request without the credential, while the public daemon removes any caller-supplied `Authorization` header and injects `Authorization: Bearer <token>` before forwarding.

## How it fits together

Foreground `harness-daemon remote serve` deliberately rejects companion routing. A foreground panel can crash while the daemon remains public, freeing the loopback port for another local process to impersonate; an operational promise to stop the daemon first cannot make that failure mode safe.

Install and start the panel service and persistent socket below before enabling companion routing on the production daemon. Then give the credential source and socket dependency to the systemd installer. This command assumes the trusted controller and daemon are installed at the shown paths and the proxy token already exists. The copyable command is for an existing remote-daemon installation: `--reconfigure` makes the controller snapshot the old binary, unit, environment, and state before replacing the unit. Omit that flag only for the first installation, when the remote-daemon unit is absent.

```bash
sudo /usr/local/bin/harness-systemd install \
  --reconfigure \
  --binary-path /usr/local/bin/harness-daemon \
  --domain harness.example.com \
  --acme-email ops@example.com \
  --companion-upstream http://127.0.0.1:8787 \
  --companion-path-prefix /panel \
  --companion-panel-socket-unit harness-panel.socket \
  --companion-auth-token-file /etc/harness-panel/companion-auth-token
```

The prefix is forwarded verbatim, so the panel serves its own routes under `/panel/...` and `--base-path` has to match `--companion-path-prefix`. The daemon exempts that subtree from remote bearer auth: the proxy token authenticates the daemon-to-panel hop, while the panel's GitHub session authenticates the person. The daemon's body, URI, and header limits still apply, and GitHub OAuth starts are rate-limited by the real public source address before forwarding.

Everything absolute the panel produces, including the OAuth `redirect_uri`, is built from `--public-origin` and `--base-path`. It never derives its origin from forwarded headers, so whoever can reach the loopback listener cannot choose where GitHub sends an authorization code.

## GitHub OAuth app

Register an OAuth app owned by whoever runs the panel, with:

- Homepage URL `https://harness.example.com/panel/`
- Authorization callback URL `https://harness.example.com/panel/auth/github/callback`

The panel requests `read:user` and nothing else. The access token is used once, to read the profile, and is never stored.

Write the client secret to a file the service can read and nobody else can:

```bash
sudo install -d -m 0700 /etc/harness-panel
client_secret_tmp="$(mktemp)" || exit 1
if ! printf '%s' "$GITHUB_CLIENT_SECRET" >"$client_secret_tmp" ||
    ! sudo install -m 0400 "$client_secret_tmp" /etc/harness-panel/github-client-secret; then
  rm -f "$client_secret_tmp"
  unset client_secret_tmp
  exit 1
fi
rm -f "$client_secret_tmp"
unset client_secret_tmp
```

`mktemp` creates the staging file readable only by its owner, and `install` puts it in place already at 0400. Writing straight to the destination and tightening it afterwards would leave the secret world-readable for as long as the two commands take, which is a window any local process can wait for.

The panel refuses to start if that file is readable by group or other. It is never taken as a flag value or an environment string, both of which any local process can read out of `/proc`.

## Installing

These commands assume a Linux host running systemd 247 or newer, a checkout of this repository with its `mise` configuration trusted, the default install paths with `HARNESS_INSTALL_BINARY_DIR` unset, `sudo` access, existing root-only credentials at `/etc/harness-panel/github-client-secret` and `/etc/harness-panel/companion-auth-token`, and no edits to the values between reviewing and installing the rendered units. They are for the first installation and stop if either unit already exists. Follow [Upgrading](#upgrading) for an existing installation.

```bash
mise run install:harness:panel || exit 1
panel_candidate="$HOME/.local/bin/harness-panel"
```

The `mise` task installs the candidate under `$HOME`. Render and review with that candidate before replacing `/usr/local/bin/harness-panel`; the installed service uses `ProtectHome=true` and cannot execute the candidate in place.

Run this block in the same shell as the preceding block. It checks every systemd load path, renders the service and its persistent listener into temporary files, and installs them only if both renders succeed. If the second unit copy fails, the commands remove the first copy and return failure instead of leaving a mixed pair.

```bash
panel_service_unit="$(mktemp)" || exit 1
panel_socket_unit="$(mktemp)" || {
  rm -f "$panel_service_unit"
  unset panel_service_unit
  exit 1
}
panel_service_load_state="$(sudo systemctl show --property=LoadState --value harness-panel.service)" || exit 1
panel_socket_load_state="$(sudo systemctl show --property=LoadState --value harness-panel.socket)" || exit 1
panel_install_status=0
if test "$panel_service_load_state" != not-found ||
    test "$panel_socket_load_state" != not-found ||
    sudo test -e /etc/systemd/system/harness-panel.service ||
    sudo test -e /etc/systemd/system/harness-panel.socket; then
  printf 'panel units already exist; follow the Upgrading section\n' >&2
  panel_install_status=1
elif "$panel_candidate" print-unit \
    --public-origin https://harness.example.com \
    --base-path /panel \
    --state-dir /var/lib/harness-panel \
    --github-client-id Iv1.abc123 \
    --github-client-secret-file /etc/harness-panel/github-client-secret \
    --companion-auth-token-file /etc/harness-panel/companion-auth-token \
    --owner-login your-github-login \
    --daemon-endpoint https://harness.example.com \
    --daemon-spki-pin sha256/BASE64 \
    >"$panel_service_unit" &&
    "$panel_candidate" print-socket-unit \
      --listen 127.0.0.1:8787 \
      >"$panel_socket_unit"; then
  less "$panel_service_unit" "$panel_socket_unit"
  printf 'Install these units? [y/N] '
  read -r install_unit
  case "$install_unit" in
    y|Y)
      if ! sudo install -m 0755 "$panel_candidate" /usr/local/bin/harness-panel; then
        printf 'panel binary installation failed\n' >&2
        panel_install_status=1
      elif ! sudo install -m 0644 "$panel_service_unit" /etc/systemd/system/harness-panel.service; then
        printf 'panel service installation failed\n' >&2
        panel_install_status=1
      elif ! sudo install -m 0644 "$panel_socket_unit" /etc/systemd/system/harness-panel.socket; then
        if sudo rm -f /etc/systemd/system/harness-panel.service; then
          printf 'panel socket installation failed; removed the new service unit\n' >&2
        else
          printf 'panel socket installation and service-unit rollback both failed\n' >&2
        fi
        panel_install_status=1
      elif ! sudo systemctl daemon-reload ||
          ! sudo systemctl enable --now harness-panel.socket harness-panel.service; then
        printf 'panel units were installed but activation failed; inspect systemctl status before retrying\n' >&2
        panel_install_status=1
      fi
      ;;
    *)
      printf 'units not installed\n'
      ;;
  esac
else
  printf 'unit rendering failed; the installed units were not changed\n' >&2
  panel_install_status=1
fi
rm -f "$panel_service_unit" "$panel_socket_unit"
if test "$panel_install_status" -ne 0; then
  unset install_unit panel_candidate panel_install_status panel_service_load_state panel_service_unit panel_socket_load_state panel_socket_unit
  false
else
  unset install_unit panel_candidate panel_install_status panel_service_load_state panel_service_unit panel_socket_load_state panel_socket_unit
fi
```

Neither renderer reads from disk, so rendering does not verify that either credential file exists.

It ignores `--state-dir`. The rendered unit always points the panel at `%S/<unit>`, the directory `StateDirectory=` creates for it, because `ProtectSystem=strict` leaves nowhere else writable. The flag is still required because `serve` and `print-unit` take the same arguments; pass anything, or pass the path you would use when running the panel by hand.

The socket unit owns the loopback listener continuously and passes it to each panel process, so a local process cannot take the port while the panel restarts and receive forwarded credentials. The panel fails closed if that exact socket is not inherited. The managed daemon requires and binds its lifecycle to the same socket unit, so it cannot start without the reserved listener and stops if the socket goes inactive.

The rendered service runs under `DynamicUser=yes` with an empty capability bounding set, and takes both credentials through `LoadCredential=`, which exposes protected, read-only copies to the transient user. On ACL-capable hosts the effective ACL mask may appear as a group-read mode bit; the panel accepts that only for a root-owned direct child of its systemd credential directory. `systemd-analyze security` scores it 1.1. What it still counts against the unit is inherent to the job: the panel has host network access, allocates Internet sockets, and pins no IP allow list, because GitHub's address ranges rotate and a stale list would take sign-in down without a word.

## Pairing the panel with the daemon

The panel mints links through the daemon, so it needs a credential of its own. Create a `pairing-broker` link on the daemon host and note both the code and the pin:

```bash
harness-daemon remote pair create --role pairing-broker
```

The output carries a `harness://pair?payload=…` link. Its payload holds the one-time code and `server_spki_sha256`; the code goes to `harness-panel pair` once, through the file below, and the pin becomes `--daemon-spki-pin`. The pin is the daemon's certificate, not a secret, and it stays the same until the certificate is renewed with a new key.

Write the code to a file only root can read, then claim it once as root. The panel service never reads this file and must not be given access to it: `pair` is an operator command that runs to completion and stores the credential it claims, while `serve` only ever reads what is already stored. Claiming is separate for that reason: a one-time code left in a unit file would be spent on the first start and refused on every restart afterwards.

```bash
sudo install -d -m 0700 /etc/harness-panel
pair_code_tmp="$(mktemp)" || exit 1
if ! printf '%s' "$PAIR_CODE" >"$pair_code_tmp" ||
    ! sudo install -m 0400 "$pair_code_tmp" /etc/harness-panel/daemon-pair-code; then
  rm -f "$pair_code_tmp"
  unset pair_code_tmp
  exit 1
fi
rm -f "$pair_code_tmp"
unset pair_code_tmp

sudo harness-panel pair \
  --public-origin https://harness.example.com \
  --state-dir /var/lib/harness-panel \
  --github-client-id Iv1.abc123 \
  --github-client-secret-file /etc/harness-panel/github-client-secret \
  --owner-login your-github-login \
  --daemon-endpoint https://harness.example.com \
  --daemon-spki-pin sha256/BASE64 \
  --code-file /etc/harness-panel/daemon-pair-code

sudo rm /etc/harness-panel/daemon-pair-code
```

The code is a credential in transit, which is why it goes in a file rather than a flag value: any local process can read a command line out of `/proc`. `pair` refuses a code file that group or other can read, and refuses a credential the daemon issues with any role but `pairing_broker`, rather than storing one that fails later for whoever first tries to generate a link.

Re-pair the same way after revoking the panel's client on the daemon.

## Checking it

```bash
curl -fsS https://harness.example.com/panel/healthz
```

Probe through the public daemon so the proxy token never enters a non-root shell. A direct request to `http://127.0.0.1:8787/panel/healthz` without the credential returns `401 Unauthorized`; the same protection covers assets, OAuth, sign-out, and API routes.

`"assets":"bundled"` means the binary carries the real web app. `"assets":"placeholder"` means it was built with `HARNESS_PANEL_SKIP_FRONTEND_BUILD=1` and serves a stand-in page; rebuild it with Node available.

Then open `https://harness.example.com/panel/` and sign in. The owner also sees everyone else who has signed in; nobody else does.

## Approving someone

Everyone starts unable to pair, including the owner. The owner approves an account from the roster, and that account can then generate its own link from its page. The link is shown once: it carries a one-time code, so the panel keeps only the pairing id, the role, and the timestamps, and never the link itself.

The role and lifetime of every link come from `--pair-link-role` and `--pair-link-ttl-seconds`, never from whoever asked. A link the daemon issues under any other role is recorded and then withheld: the panel cannot revoke what it has already caused, so the most it can do is leave the code unshown to lapse unclaimed, and the row is there to revoke on the daemon. An approved account cannot choose what its link grants. Only `operator` and `viewer` may be minted: the panel holds a credential whose one power is minting, and the daemon does not check that a requested role is at or below the caller's own, so anything more would let an approved account end up with more authority than the panel itself has.

An account may hold five unexpired links at once. A revoke cannot reach a link already minted, so without a cap one approved account, or whoever took its session, could leave a pile of live credentials to hunt down one at a time.

The slot is taken before the daemon is asked, so requests arriving together cannot each see the same one free. A panel that dies between taking a slot and receiving the link leaves a row whose id begins `reservation:`, which counts against the cap until it lapses on the configured lifetime and matches no pairing on the daemon.

### What a revoke reaches

Revoking stops that account generating **new** links. It does not reach backwards:

- a link already generated stays claimable until it expires
- a device that already paired keeps working

Cut off a paired device with `harness-daemon remote clients revoke` on the daemon host. The panel deliberately has no power to do that: it holds a credential that may only mint links, so it cannot revoke the devices those links produced.

## Who owns the panel

`--owner-login` names a GitHub login, and a login is not a person: renaming one frees the old name for anyone to register. So the flag decides only who the panel is claimed for, once. The first time somebody whose login matches it signs in, the panel records their immutable GitHub account id and answers "is this the owner" from that pair from then on. Renaming the owner's login does not cost them the panel, and picking up their old name does not gain it.

The flag is matched without regard to case, because GitHub treats logins that way and the flag is typed by hand.

Re-pointing a panel at a different owner therefore means changing `--owner-login` *and* deleting the recorded claim:

```bash
sudo systemctl stop harness-remote-daemon.service
sudo systemctl stop harness-panel.socket harness-panel.service
sudo sqlite3 /var/lib/harness-panel/panel.sqlite3 'DELETE FROM owner_binding'
sudo systemctl start harness-panel.socket harness-panel.service
sudo systemctl start harness-remote-daemon.service
```

The example uses the default daemon unit name; substitute the installed name if it differs. Stopping the public daemon before releasing the socket ensures no forwarded credential can reach another process during maintenance. The next sign-in by someone matching the new `--owner-login` claims the panel. Changing the flag alone does nothing, which is the point: it is not what ownership rests on.

## Upgrading

The panel has no transactional upgrade path through the `harness-systemd` controller; that is tracked in #604. Do not assume `daemon:remote:deploy` touches it. Render both candidate units before changing the host, then save the installed binary and unit pair in a root-owned backup directory. Each update block quiesces the public route and takes a consistent SQLite backup before starting the candidate; the database is the panel StateDirectory's only persistent payload, and SQLite's backup command folds any WAL state into that image.

```bash
mise run install:harness:panel || exit 1
panel_candidate="$HOME/.local/bin/harness-panel"
panel_service_unit="$(mktemp)" || exit 1
panel_socket_unit="$(mktemp)" || {
  rm -f "$panel_service_unit"
  unset panel_service_unit
  exit 1
}
if ! "$panel_candidate" print-unit \
    --public-origin https://harness.example.com \
    --base-path /panel \
    --state-dir /var/lib/harness-panel \
    --github-client-id Iv1.abc123 \
    --github-client-secret-file /etc/harness-panel/github-client-secret \
    --companion-auth-token-file /etc/harness-panel/companion-auth-token \
    --owner-login your-github-login \
    >"$panel_service_unit" ||
    ! "$panel_candidate" print-socket-unit \
      --listen 127.0.0.1:8787 \
      >"$panel_socket_unit"; then
  rm -f "$panel_service_unit" "$panel_socket_unit"
  unset panel_candidate panel_service_unit panel_socket_unit
  exit 1
fi
less "$panel_service_unit" "$panel_socket_unit"
panel_backup_dir="$(sudo mktemp -d /var/tmp/harness-panel-backup.XXXXXX)" || exit 1
if ! sudo install -m 0755 /usr/local/bin/harness-panel "$panel_backup_dir/harness-panel" ||
    ! sudo install -m 0644 /etc/systemd/system/harness-panel.service "$panel_backup_dir/harness-panel.service" ||
    ! sudo install -m 0644 /etc/systemd/system/harness-panel.socket "$panel_backup_dir/harness-panel.socket"; then
  printf 'backup failed; installed files were not changed\n' >&2
  exit 1
fi
printf 'rollback copy: %s\n' "$panel_backup_dir"
```

Run the preparation block and exactly one update block below in the same shell; they share the rendered-unit and backup-path variables. Both update blocks require the `sqlite3` CLI already used by the ownership-reset procedure.

For a binary or service-only update, record whether the remote daemon is active and stop it before taking the database snapshot. Leave `harness-panel.socket` active so it owns the listener throughout the restart; `enable --now` alone does not restart an active service. Restart the remote daemon only after the candidate answers the authenticated loopback check, and keep it stopped if any step fails.

```bash
remote_was_active=false
if sudo systemctl is-active --quiet harness-remote-daemon.service; then
  remote_was_active=true
fi
(
  set -eu
  sudo systemctl stop harness-remote-daemon.service
  sudo test -f /var/lib/harness-panel/panel.sqlite3
  sudo sqlite3 /var/lib/harness-panel/panel.sqlite3 'PRAGMA wal_checkpoint(TRUNCATE)'
  sudo sqlite3 /var/lib/harness-panel/panel.sqlite3 ".backup '$panel_backup_dir/panel.sqlite3'"
  sudo install -m 0755 "$panel_candidate" /usr/local/bin/harness-panel
  sudo install -m 0644 "$panel_service_unit" /etc/systemd/system/harness-panel.service
  sudo systemctl daemon-reload
  sudo systemctl enable harness-panel.socket harness-panel.service
  sudo systemctl restart harness-panel.service
  panel_status="$(curl --max-time 10 -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8787/panel/healthz || true)"
  if test "$panel_status" != 401; then
    printf 'panel loopback authentication check returned %s; restore %s\n' "$panel_status" "$panel_backup_dir" >&2
    exit 1
  fi
  if test "$remote_was_active" = true; then
    sudo systemctl start harness-remote-daemon.service
  fi
)
panel_update_status=$?
if test "$panel_update_status" -eq 0; then
  rm -f "$panel_service_unit" "$panel_socket_unit"
  unset panel_candidate panel_service_unit panel_socket_unit panel_update_status
else
  rm -f "$panel_service_unit" "$panel_socket_unit"
  unset panel_candidate panel_service_unit panel_socket_unit panel_update_status
  false
fi
```

A `ListenStream=` change releases the protected listener, so quiesce the public route before stopping the socket. Render and review both candidate units first. Record whether the remote daemon is active, stop the remote daemon, stop the panel service and socket, install the binary and both unit files, reload systemd, start the socket, and then start the panel. Keep the remote daemon stopped if any step fails.

```bash
remote_was_active=false
if sudo systemctl is-active --quiet harness-remote-daemon.service; then
  remote_was_active=true
fi
(
  set -eu
  sudo systemctl stop harness-remote-daemon.service
  sudo systemctl stop harness-panel.service harness-panel.socket
  sudo test -f /var/lib/harness-panel/panel.sqlite3
  sudo sqlite3 /var/lib/harness-panel/panel.sqlite3 'PRAGMA wal_checkpoint(TRUNCATE)'
  sudo sqlite3 /var/lib/harness-panel/panel.sqlite3 ".backup '$panel_backup_dir/panel.sqlite3'"
  sudo install -m 0755 "$panel_candidate" /usr/local/bin/harness-panel
  sudo install -m 0644 "$panel_service_unit" /etc/systemd/system/harness-panel.service
  sudo install -m 0644 "$panel_socket_unit" /etc/systemd/system/harness-panel.socket
  sudo systemctl daemon-reload
  sudo systemctl enable harness-panel.socket harness-panel.service
  sudo systemctl start harness-panel.socket
  sudo systemctl start harness-panel.service
  panel_status="$(curl --max-time 10 -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8787/panel/healthz || true)"
  if test "$panel_status" != 401; then
    printf 'panel loopback authentication check returned %s; remote daemon remains stopped; restore %s\n' "$panel_status" "$panel_backup_dir" >&2
    exit 1
  fi
  if test "$remote_was_active" = true; then
    sudo systemctl start harness-remote-daemon.service
  fi
)
panel_update_status=$?
if test "$panel_update_status" -eq 0; then
  rm -f "$panel_service_unit" "$panel_socket_unit"
  unset panel_candidate panel_service_unit panel_socket_unit panel_update_status
else
  rm -f "$panel_service_unit" "$panel_socket_unit"
  unset panel_candidate panel_service_unit panel_socket_unit panel_update_status
  false
fi
```

The sequences are coordinated, not atomic. If copying, migration, activation, or verification fails, keep the remote daemon stopped and restore the saved binary, unit pair, and database snapshot together. Restoring the snapshot discards every panel database change made after it, so do not resume public traffic or reuse an old backup between the snapshot and rollback.

```bash
(
  set -eu
  sudo systemctl stop harness-remote-daemon.service
  sudo systemctl stop harness-panel.service harness-panel.socket
  sudo install -m 0755 "$panel_backup_dir/harness-panel" /usr/local/bin/harness-panel
  sudo install -m 0644 "$panel_backup_dir/harness-panel.service" /etc/systemd/system/harness-panel.service
  sudo install -m 0644 "$panel_backup_dir/harness-panel.socket" /etc/systemd/system/harness-panel.socket
  sudo sqlite3 /var/lib/harness-panel/panel.sqlite3 'PRAGMA wal_checkpoint(TRUNCATE)'
  sudo sqlite3 /var/lib/harness-panel/panel.sqlite3 ".restore '$panel_backup_dir/panel.sqlite3'"
  sudo sqlite3 /var/lib/harness-panel/panel.sqlite3 'PRAGMA wal_checkpoint(TRUNCATE)'
  sudo systemctl daemon-reload
  sudo systemctl start harness-panel.socket
  sudo systemctl start harness-panel.service
  panel_status="$(curl --max-time 10 -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8787/panel/healthz || true)"
  if test "$panel_status" != 401; then
    printf 'restored panel authentication check returned %s; remote daemon remains stopped\n' "$panel_status" >&2
    exit 1
  fi
  if test "${remote_was_active:-false}" = true; then
    sudo systemctl start harness-remote-daemon.service
  fi
)
panel_rollback_status=$?
if test "$panel_rollback_status" -eq 0; then
  unset panel_rollback_status
else
  unset panel_rollback_status
  false
fi
```

The outer `remote_was_active` value survives a failed update and makes the rollback restart `harness-remote-daemon.service` only when it was active before maintenance and the restored panel returned `401`. Keep the backup directory until the public health check and sign-in flow pass.

## Where its state lives

One SQLite database under the state directory, holding accounts, sessions, sign-ins in flight, approval decisions, the credential the panel authenticates to the daemon with, and a record of which links it minted. The directory is created mode 0700 and the database stores only the SHA-256 of a session token, so a copy of it is not a set of working sessions. The daemon credential is the one secret held in the clear, because the panel has to replay it on every mint. That makes the database credential-bearing where it previously was not: the sessions beside it are only hashes, but a copy of this row mints pairing links for any identity its holder names. Treat a backup as a secret, and revoke the panel's client on the daemon if one leaks. Deleting the database signs everyone out and forgets who has signed in; it costs nothing else.

## Developing

The web app is Svelte and TypeScript under `crates/harness-panel/frontend`, built by Vite and embedded into the binary by the crate's build script. Building the crate builds the assets, so Node has to be on `PATH`; `mise` pins it.

```bash
mise run panel:frontend:install   # once, or after the manifest or lockfile changes
mise run panel:frontend:lint
mise run panel:frontend:test
```

Vite bakes the mount point into its asset URLs at build time, but `--base-path` is chosen at start, so the bundle is built against the sentinel `/__harness_panel_base__` and the serving binary substitutes the configured prefix into `index.html`. Only `index.html` mentions the sentinel. If you change `base` in `vite.config.ts`, change `BASE_PATH_SENTINEL` in `src/assets.rs` and the `harness-panel-base` meta tag with it.
