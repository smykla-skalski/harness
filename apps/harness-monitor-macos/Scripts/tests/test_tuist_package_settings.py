from __future__ import annotations

import unittest
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
PROJECT_MANIFEST = APP_ROOT / "Project.swift"
PACKAGE_MANIFEST = APP_ROOT / "Tuist" / "Package.swift"
BUILD_SETTINGS_HELPER = APP_ROOT / "Tuist" / "ProjectDescriptionHelpers" / "BuildSettings.swift"

RECOMMENDED_PACKAGE_SETTINGS = (
    '"ALWAYS_SEARCH_USER_PATHS": "NO"',
    '"ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES"',
    '"CLANG_ENABLE_OBJC_WEAK": "YES"',
    '"CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "YES"',
    '"COMPILATION_CACHE_ENABLE_CACHING": "YES"',
    '"ENABLE_STRICT_OBJC_MSGSEND": "YES"',
    '"GCC_NO_COMMON_BLOCKS": "YES"',
    '"LOCALIZATION_PREFERS_STRING_CATALOGS": "YES"',
    '"MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE"',
    '"MTL_FAST_MATH": "YES"',
    '"SWIFT_ENABLE_PREFIX_MAPPING": "YES"',
)

RECOMMENDED_FRAMEWORK_SETTINGS = (
    '"ENABLE_MODULE_VERIFIER": "YES"',
    '"MODULE_VERIFIER_SUPPORTED_LANGUAGES": "objective-c objective-c++"',
    '"MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS": "gnu17 gnu++20"',
)

PREVIEW_OVERRIDE_SETTINGS = (
    '"SWIFT_ENABLE_PREFIX_MAPPING": "NO"',
)

PROJECT_MANIFEST_SETTINGS = (
    '"REGISTER_APP_GROUPS": "YES"',
)


class TuistPackageSettingsTests(unittest.TestCase):
    def test_main_project_uses_xcode_recommended_settings(self) -> None:
        helper = BUILD_SETTINGS_HELPER.read_text()

        for setting in RECOMMENDED_PACKAGE_SETTINGS:
            with self.subTest(setting=setting):
                self.assertIn(setting, helper)

        for setting in RECOMMENDED_FRAMEWORK_SETTINGS:
            with self.subTest(setting=setting):
                self.assertIn(setting, helper)

        for setting in PREVIEW_OVERRIDE_SETTINGS:
            with self.subTest(setting=setting):
                self.assertIn(setting, helper)

    def test_project_manifest_uses_recommended_framework_settings(self) -> None:
        manifest = PROJECT_MANIFEST.read_text()

        for setting in RECOMMENDED_FRAMEWORK_SETTINGS:
            with self.subTest(setting=setting):
                self.assertIn(setting, manifest)

        self.assertNotIn('"ENABLE_MODULE_VERIFIER": "NO"', manifest)
        for setting in PREVIEW_OVERRIDE_SETTINGS:
            with self.subTest(setting=setting):
                self.assertIn(setting, manifest)
        for setting in PROJECT_MANIFEST_SETTINGS:
            with self.subTest(setting=setting):
                self.assertIn(setting, manifest)
        self.assertNotIn('"DEVELOPMENT_TEAM": "Q498EB36N4"', manifest)

    def test_package_generated_projects_use_xcode_recommended_settings(self) -> None:
        manifest = PACKAGE_MANIFEST.read_text()

        for setting in RECOMMENDED_PACKAGE_SETTINGS:
            with self.subTest(setting=setting):
                self.assertIn(setting, manifest)

        for setting in RECOMMENDED_FRAMEWORK_SETTINGS:
            with self.subTest(setting=setting):
                self.assertIn(setting, manifest)

        for setting in PREVIEW_OVERRIDE_SETTINGS:
            with self.subTest(setting=setting):
                self.assertIn(setting, manifest)


if __name__ == "__main__":
    unittest.main()
