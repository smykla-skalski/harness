from __future__ import annotations

import unittest
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
ADAPTIVE_GRID_LAYOUT = (
    APP_ROOT
    / "Sources"
    / "HarnessMonitorUIPreviewable"
    / "Views"
    / "HarnessMonitorAdaptiveGridLayout.swift"
)
COLUMN_SCROLL_VIEW = (
    APP_ROOT
    / "Sources"
    / "HarnessMonitorUIPreviewable"
    / "Views"
    / "HarnessMonitorColumnScrollView.swift"
)
PREFERENCES_PREVIEW_SUPPORT = (
    APP_ROOT
    / "Sources"
    / "HarnessMonitorUIPreviewable"
    / "Views"
    / "PreferencesPreviewSupport.swift"
)


class PreviewableExportTests(unittest.TestCase):
    def test_adaptive_grid_layout_stays_public_for_preview_thunks(self) -> None:
        source = ADAPTIVE_GRID_LAYOUT.read_text()

        expected_tokens = (
            "public struct HarnessMonitorAdaptiveGridLayout: Layout",
            "public struct Cache",
            "public let minimumColumnWidth: CGFloat",
            "public let maximumColumns: Int",
            "public let spacing: CGFloat",
            "public init(",
            "public func makeCache(",
            "public func updateCache(",
            "public func sizeThatFits(",
            "public func placeSubviews(",
        )

        for token in expected_tokens:
            with self.subTest(token=token):
                self.assertIn(token, source)

        self.assertEqual(source.count("public func explicitAlignment("), 2)

    def test_public_preview_support_avoids_default_argument_generators(self) -> None:
        column_source = COLUMN_SCROLL_VIEW.read_text()
        preview_source = PREFERENCES_PREVIEW_SUPPORT.read_text()

        forbidden_column_defaults = (
            "horizontalPadding: CGFloat = 24",
            "verticalPadding: CGFloat = 24",
            "constrainContentWidth: Bool = false",
            "readableWidth: Bool = false",
            "topScrollEdgeEffect: HarnessMonitorColumnTopScrollEdgeEffect = .soft",
        )
        for token in forbidden_column_defaults:
            with self.subTest(token=token):
                self.assertNotIn(token, column_source)

        forbidden_preview_defaults = (
            "scenario: HarnessMonitorPreviewStoreFactory.Scenario = .cockpitLoaded",
            "events: [DaemonAuditEvent] = Self.recentEvents",
            "previewFeedback: PreviewFeedback? = nil",
        )
        for token in forbidden_preview_defaults:
            with self.subTest(token=token):
                self.assertNotIn(token, preview_source)

        self.assertIn("public static func makeStore() -> HarnessMonitorStore", preview_source)
        self.assertIn(
            "public static func makeStore(previewFeedback: PreviewFeedback) -> HarnessMonitorStore",
            preview_source,
        )


if __name__ == "__main__":
    unittest.main()
