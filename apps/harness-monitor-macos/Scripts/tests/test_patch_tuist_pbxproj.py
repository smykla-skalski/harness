from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
PATCHER_PATH = APP_ROOT / "Scripts" / "patch-tuist-pbxproj.py"


def load_patcher_module():
    spec = importlib.util.spec_from_file_location("patch_tuist_pbxproj", PATCHER_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class PatchTuistPbxprojTests(unittest.TestCase):
    def test_strips_target_team_attributes_from_generated_project(self) -> None:
        module = load_patcher_module()
        pbxproj = """// !$*UTF8*$!
{
\tarchiveVersion = 1;
\tclasses = {
\t};
\tobjectVersion = 55;
\tobjects = {

/* Begin PBXNativeTarget section */
\t\tAAAAAAAAAAAAAAAAAAAAAAAA /* HarnessMonitorRegistry */ = {
\t\t\tisa = PBXNativeTarget;
\t\t\tproductType = "com.apple.product-type.framework";
\t\t};
\t\tBBBBBBBBBBBBBBBBBBBBBBBB /* HarnessMonitorRegistryTests */ = {
\t\t\tisa = PBXNativeTarget;
\t\t\tproductType = "com.apple.product-type.bundle.unit-test";
\t\t};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\tCCCCCCCCCCCCCCCCCCCCCCCC /* Project object */ = {
\t\t\tisa = PBXProject;
\t\t\tattributes = {
\t\t\t\tBuildIndependentTargetsInParallel = YES;
\t\t\t\tLastUpgradeCheck = 9999;
\t\t\t\tTargetAttributes = {
\t\t\t\t\tAAAAAAAAAAAAAAAAAAAAAAAA = {
\t\t\t\t\t\tDevelopmentTeam = Q498EB36N4;
\t\t\t\t\t\tProvisioningStyle = Automatic;
\t\t\t\t\t};
\t\t\t\t\tBBBBBBBBBBBBBBBBBBBBBBBB = {
\t\t\t\t\t\tDevelopmentTeam = Q498EB36N4;
\t\t\t\t\t\tProvisioningStyle = Automatic;
\t\t\t\t\t\tTestTargetID = AAAAAAAAAAAAAAAAAAAAAAAA;
\t\t\t\t\t};
\t\t\t\t};
\t\t\t};
\t\t};
/* End PBXProject section */
\t};
}
"""

        with tempfile.TemporaryDirectory() as tmp_dir:
            pbxproj_path = Path(tmp_dir) / "project.pbxproj"
            pbxproj_path.write_text(pbxproj)

            module.patch_pbxproj(pbxproj_path, "2640", "2640", "55", "55")

            patched = pbxproj_path.read_text()

        self.assertIn("LastUpgradeCheck = 2640;", patched)
        self.assertIn("\t\t\t\t\tBBBBBBBBBBBBBBBBBBBBBBBB = {\n", patched)
        self.assertIn("\t\t\t\t\t\tTestTargetID = AAAAAAAAAAAAAAAAAAAAAAAA;\n", patched)
        self.assertNotIn("DevelopmentTeam = Q498EB36N4;", patched)
        self.assertNotIn("ProvisioningStyle = Automatic;", patched)

    def test_adds_disabled_mac_app_groups_capability_for_monitor_app_targets(self) -> None:
        module = load_patcher_module()
        pbxproj = """// !$*UTF8*$!
{
\tarchiveVersion = 1;
\tclasses = {
\t};
\tobjectVersion = 55;
\tobjects = {

/* Begin PBXNativeTarget section */
\t\tAAAAAAAAAAAAAAAAAAAAAAAA /* HarnessMonitor */ = {
\t\t\tisa = PBXNativeTarget;
\t\t\tname = HarnessMonitor;
\t\t\tproductType = "com.apple.product-type.application";
\t\t};
\t\tBBBBBBBBBBBBBBBBBBBBBBBB /* HarnessMonitorUITestHost */ = {
\t\t\tisa = PBXNativeTarget;
\t\t\tname = HarnessMonitorUITestHost;
\t\t\tproductType = "com.apple.product-type.application";
\t\t};
\t\tCCCCCCCCCCCCCCCCCCCCCCCC /* HarnessMonitorUITests */ = {
\t\t\tisa = PBXNativeTarget;
\t\t\tname = HarnessMonitorUITests;
\t\t\tproductType = "com.apple.product-type.bundle.ui-testing";
\t\t};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\tDDDDDDDDDDDDDDDDDDDDDDDD /* Project object */ = {
\t\t\tisa = PBXProject;
\t\t\tattributes = {
\t\t\t\tBuildIndependentTargetsInParallel = YES;
\t\t\t\tTargetAttributes = {
\t\t\t\t\tCCCCCCCCCCCCCCCCCCCCCCCC = {
\t\t\t\t\t\tTestTargetID = BBBBBBBBBBBBBBBBBBBBBBBB;
\t\t\t\t\t};
\t\t\t\t};
\t\t\t};
\t\t};
/* End PBXProject section */
\t};
}
"""

        with tempfile.TemporaryDirectory() as tmp_dir:
            pbxproj_path = Path(tmp_dir) / "project.pbxproj"
            pbxproj_path.write_text(pbxproj)

            module.patch_pbxproj(pbxproj_path, "2640", "2640", "55", "55")

            patched = pbxproj_path.read_text()

        self.assertIn(
            "\t\t\t\t\tAAAAAAAAAAAAAAAAAAAAAAAA = {\n"
            "\t\t\t\t\t\tSystemCapabilities = {\n"
            "\t\t\t\t\t\t\tcom.apple.ApplicationGroups.Mac = {\n"
            "\t\t\t\t\t\t\t\tenabled = 0;\n"
            "\t\t\t\t\t\t\t};\n"
            "\t\t\t\t\t\t};\n"
            "\t\t\t\t\t};\n",
            patched,
        )
        self.assertIn(
            "\t\t\t\t\tBBBBBBBBBBBBBBBBBBBBBBBB = {\n"
            "\t\t\t\t\t\tSystemCapabilities = {\n"
            "\t\t\t\t\t\t\tcom.apple.ApplicationGroups.Mac = {\n"
            "\t\t\t\t\t\t\t\tenabled = 0;\n"
            "\t\t\t\t\t\t\t};\n"
            "\t\t\t\t\t\t};\n"
            "\t\t\t\t\t};\n",
            patched,
        )
        self.assertIn("\t\t\t\t\t\tTestTargetID = BBBBBBBBBBBBBBBBBBBBBBBB;\n", patched)


if __name__ == "__main__":
    unittest.main()
