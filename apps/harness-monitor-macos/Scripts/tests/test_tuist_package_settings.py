from __future__ import annotations

import unittest
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
PACKAGE_MANIFEST = APP_ROOT / "Tuist" / "Package.swift"
BUILD_SETTINGS_HELPER = APP_ROOT / "Tuist" / "ProjectDescriptionHelpers" / "BuildSettings.swift"

RECOMMENDED_PACKAGE_SETTINGS = (
    '"ALWAYS_SEARCH_USER_PATHS": "NO"',
    '"ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES"',
    '"CLANG_ENABLE_OBJC_WEAK": "YES"',
    '"CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "YES"',
    '"ENABLE_STRICT_OBJC_MSGSEND": "YES"',
    '"GCC_NO_COMMON_BLOCKS": "YES"',
    '"LOCALIZATION_PREFERS_STRING_CATALOGS": "YES"',
    '"MTL_FAST_MATH": "YES"',
)


class TuistPackageSettingsTests(unittest.TestCase):
    def test_main_project_uses_xcode_recommended_settings(self) -> None:
        helper = BUILD_SETTINGS_HELPER.read_text()

        for setting in RECOMMENDED_PACKAGE_SETTINGS:
            with self.subTest(setting=setting):
                self.assertIn(setting, helper)

    def test_package_generated_projects_use_xcode_recommended_settings(self) -> None:
        manifest = PACKAGE_MANIFEST.read_text()

        for setting in RECOMMENDED_PACKAGE_SETTINGS:
            with self.subTest(setting=setting):
                self.assertIn(setting, manifest)


if __name__ == "__main__":
    unittest.main()
