# VoiceOver smoke

1. Launch the app with `HARNESS_MONITOR_PREVIEW_ACP_PENDING=1`, `HARNESS_MONITOR_PREVIEW_ACP_ATTENTION_CONTEXT=foreground`, and a seeded supervisor decision for the ACP agent.
2. With VoiceOver running, confirm the ACP toast announces **"Permission requested by … workspace window."** once, exposes **Open Workspace** and **Dismiss permission alert**, and does not trap focus.
3. Activate **Open Workspace** from the toast and confirm the workspace window becomes key and VoiceOver lands on the decision's primary action.
4. Relaunch with `HARNESS_MONITOR_PREVIEW_NOTIFICATION_AUTHORIZATION=denied`, open **Settings > Notifications**, and confirm the ACP status copy explains the degraded path and exposes **Open System Settings**.
5. Relaunch with `HARNESS_MONITOR_PREVIEW_ACP_ATTENTION_CONTEXT=hidden` and authorized notifications, then confirm the app does not show the in-app toast while a Notification Center alert is delivered instead.
