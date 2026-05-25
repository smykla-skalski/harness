# App Review Notes

Harness Monitor is a free utility for monitoring Harness work from iPhone and Apple Watch. It is not a remote desktop client and does not stream raw shell or TUI sessions.

## No-Mac Evaluation

Reviewers can evaluate the app without a Mac:

1. Launch Harness Monitor on iPhone.
2. Open Settings.
3. Enable Demo mode.
4. Review Today, Sessions, Reviews, Commands, widgets, and Live Activity states using built-in sample data.
   Live Activities surface either the running command or the highest-priority critical decision.

Demo mode is built into the normal app and is also used for screenshots and previews. It is not hidden review-only behavior.

## Live Pairing Evaluation

If a Mac is available:

1. Launch Harness Monitor on macOS.
2. Open Settings.
3. Use the "Pair iPhone or Apple Watch" panel.
4. Scan the QR code from iPhone Settings in Harness Monitor.
5. Confirm that the iPhone shows the live station and mirrored Needs You, Sessions, Reviews, and Commands state.

Pairing links use the existing `harness://pair` deep link scheme.

## Data And Privacy

The app uses private CloudKit records to relay state between trusted user devices. Payload content is encrypted before CloudKit write. Metadata used for routing includes record type, station ID, schema version, revision, update time, expiry, tombstone state, and chunk IDs.

No credentials, tokens, environment secrets, raw authentication files, raw shell streams, or raw terminal UI streams are mirrored.

Users can export or delete mirrored CloudKit records from iPhone Settings. The app has no ads, no tracking, and no third-party analytics by default.

Mirror exports include encrypted record payloads plus an inventory that lists station counts, record-type counts, tombstones, expiry range, encrypted byte count, clear metadata keys, and encrypted-envelope keys. Delete uses the same inventory model to report exactly what was removed from the private CloudKit database before local mobile and watch caches are cleared.

## Notifications

Default notification behavior is intentionally limited to user-attention events, command status or failure, station health, and critical decisions.
