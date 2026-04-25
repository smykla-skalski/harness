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
    def test_patches_generated_package_test_targets_with_team_attributes(self) -> None:
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

            module.patch_pbxproj(pbxproj_path, "2640", "2640", "Q498EB36N4", "55", "55")

            patched = pbxproj_path.read_text()

        self.assertIn("LastUpgradeCheck = 2640;", patched)
        self.assertIn("\t\t\t\t\tBBBBBBBBBBBBBBBBBBBBBBBB = {\n", patched)
        self.assertIn("\t\t\t\t\t\tDevelopmentTeam = Q498EB36N4;\n", patched)
        self.assertIn("\t\t\t\t\t\tProvisioningStyle = Automatic;\n", patched)
        self.assertNotIn("\t\t\t\t\tAAAAAAAAAAAAAAAAAAAAAAAA = {\n", patched)


if __name__ == "__main__":
    unittest.main()
