#!/usr/bin/env bash
set -euo pipefail

binary_dir="${HOME}/.local/bin"
binary_path="${binary_dir}/harness"
tmp_path="${binary_path}.new"
signing_identity="Developer ID Application: Bartlomiej Smykla (Q498EB36N4)"

trap 'rm -f "${tmp_path}"' EXIT

mkdir -p "${binary_dir}"
rm -f "${tmp_path}"
cp target/release/harness "${tmp_path}"
chmod 755 "${tmp_path}"
codesign --force --options=runtime -s "${signing_identity}" "${tmp_path}"
chmod 555 "${tmp_path}"
mv -f "${tmp_path}" "${binary_path}"

expected_version="$("${binary_path}" --version | awk '{print $2}')"
"${binary_path}" daemon stop --json >/dev/null
"${binary_path}" daemon remove-launch-agent --json >/dev/null
"${binary_path}" daemon install-launch-agent --binary-path "${binary_path}" --json >/dev/null

HARNESS_BINARY="${binary_path}" EXPECTED_VERSION="${expected_version}" python3 <<'PY'
import json
import os
import subprocess
import sys
import time
import urllib.request

binary = os.environ["HARNESS_BINARY"]
expected = os.environ["EXPECTED_VERSION"]
deadline = time.time() + 15
last_error = "daemon validation did not start"

# launchctl "loaded" state can lag behind bootstrap, so validate the
# daemon by manifest version and live health instead.
while time.time() < deadline:
    try:
        result = subprocess.run(
            [binary, "daemon", "status"],
            check=True,
            capture_output=True,
            text=True,
        )
        report = json.loads(result.stdout)
        manifest = report.get("manifest")
        if manifest is None:
            raise RuntimeError("daemon status reported no manifest")
        if manifest.get("version") != expected:
            raise RuntimeError(
                f"daemon manifest version {manifest.get('version')} != expected {expected}"
            )

        launch_agent = report.get("launch_agent", {})
        if not launch_agent.get("installed"):
            raise RuntimeError("daemon launch agent is not installed")

        endpoint = manifest.get("endpoint")
        if not endpoint:
            raise RuntimeError("daemon manifest is missing an endpoint")

        with urllib.request.urlopen(
            f"{endpoint.rstrip('/')}/v1/health",
            timeout=2,
        ) as response:
            health = json.load(response)

        if health.get("status") != "ok":
            raise RuntimeError(f"daemon health status {health.get('status')!r}")
        if health.get("version") != expected:
            raise RuntimeError(
                f"daemon health version {health.get('version')} != expected {expected}"
            )

        print(f"validated daemon {expected} at {endpoint}")
        sys.exit(0)
    except Exception as exc:  # noqa: BLE001 - surface the latest validation failure
        last_error = str(exc)
        time.sleep(0.25)

raise SystemExit(f"daemon reinstall validation failed: {last_error}")
PY
