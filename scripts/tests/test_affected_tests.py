import json
import pathlib
import subprocess
import sys
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SCRIPTS = HERE.parent
sys.path.insert(0, str(SCRIPTS))

import affected_tests  # noqa: E402

FIXTURE = HERE / "fixtures" / "demo-describe.json"


def describe():
    return json.loads(FIXTURE.read_text())


class AffectedTestTargets(unittest.TestCase):
    def test_leaf_module_change_selects_only_its_tests(self):
        got = affected_tests.affected_test_targets(describe(), ["Sources/B/Foo.swift"])
        self.assertEqual(got, {"BTests"})

    def test_middle_module_change_selects_dependents(self):
        got = affected_tests.affected_test_targets(describe(), ["Sources/A/Bar.swift"])
        self.assertEqual(got, {"ATests", "BTests"})

    def test_root_module_change_selects_everything_downstream(self):
        got = affected_tests.affected_test_targets(describe(), ["Sources/Core/Version.swift"])
        self.assertEqual(got, {"CoreTests", "ATests", "BTests"})

    def test_test_target_change_selects_itself(self):
        got = affected_tests.affected_test_targets(describe(), ["Tests/ATests/ATests.swift"])
        self.assertEqual(got, {"ATests"})

    def test_executable_change_selects_nothing(self):
        got = affected_tests.affected_test_targets(describe(), ["Sources/Tool/main.swift"])
        self.assertEqual(got, set())

    def test_manifest_change_selects_all(self):
        self.assertEqual(affected_tests.affected_test_targets(describe(), ["Package.swift"]), "ALL")
        self.assertEqual(affected_tests.affected_test_targets(describe(), ["Package.resolved"]), "ALL")

    def test_unknown_path_selects_all(self):
        self.assertEqual(affected_tests.affected_test_targets(describe(), ["Plugins/X/y.swift"]), "ALL")

    def test_no_changes_selects_nothing(self):
        self.assertEqual(affected_tests.affected_test_targets(describe(), []), set())

    def test_mixed_changes_union(self):
        got = affected_tests.affected_test_targets(describe(), ["Sources/B/Foo.swift", "Tests/CoreTests/T.swift"])
        self.assertEqual(got, {"BTests", "CoreTests"})


class Cli(unittest.TestCase):
    def run_cli(self, *args):
        cmd = [sys.executable, str(SCRIPTS / "affected_tests.py"), "--package-path", "v2/VoxFlowKit",
               "--describe-json", str(FIXTURE), *args]
        return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout.strip()

    def test_strips_package_prefix_and_prints_names(self):
        self.assertEqual(self.run_cli("v2/VoxFlowKit/Sources/B/Foo.swift"), "BTests")

    def test_regex_format(self):
        self.assertEqual(self.run_cli("--format", "regex", "v2/VoxFlowKit/Sources/A/Bar.swift"),
                         r"^(ATests|BTests)\.")

    def test_all_is_printed_verbatim(self):
        self.assertEqual(self.run_cli("v2/VoxFlowKit/Package.swift"), "ALL")

    def test_file_outside_package_selects_all(self):
        self.assertEqual(self.run_cli("v2/VoxFlow/App/VoxFlowApp.swift"), "ALL")

    def test_empty_input_prints_empty_line(self):
        self.assertEqual(self.run_cli(), "")

    def test_files_json_is_read_and_merged(self):
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump(["v2/VoxFlowKit/Sources/B/Foo.swift"], fh)
        try:
            self.assertEqual(self.run_cli("--files-json", fh.name, "v2/VoxFlowKit/Tests/CoreTests/T.swift"),
                             "BTests CoreTests")
        finally:
            pathlib.Path(fh.name).unlink()


if __name__ == "__main__":
    unittest.main()
