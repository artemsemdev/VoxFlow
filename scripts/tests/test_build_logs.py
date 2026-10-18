import pathlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "check_build_logs.py"


class BuildLogs(unittest.TestCase):
    def check_logs(self, *contents):
        with tempfile.TemporaryDirectory() as directory:
            paths = []
            for index, content in enumerate(contents):
                path = pathlib.Path(directory) / f"build-{index}.log"
                path.write_text(content)
                paths.append(str(path))
            return subprocess.run([sys.executable, str(SCRIPT), *paths], capture_output=True, text=True)

    def test_clean_log_passes(self):
        result = self.check_logs("Build succeeded.\nTests passed.\nWarnings as errors enabled.\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_swift_and_metal_warnings_fail(self):
        result = self.check_logs("Compile\nsource.swift:12:4: warning: unused result\nshader: warning: type mismatch\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("unused result", result.stderr)
        self.assertIn("type mismatch", result.stderr)

    def test_uppercase_xcode_destination_warning_fails(self):
        result = self.check_logs("--- xcodebuild: WARNING: Using the first of multiple matching destinations:\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("multiple matching destinations", result.stderr)

    def test_warning_in_another_log_is_not_ignored(self):
        result = self.check_logs("Build succeeded\n", "test.swift: warning: deprecated\n")
        self.assertEqual(result.returncode, 1)

    def test_last_line_without_newline_is_checked(self):
        self.assertEqual(self.check_logs("driver: Warning: ambiguous option").returncode, 1)

    def test_missing_log_fails_instead_of_claiming_clean(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "missing.log"
            result = subprocess.run([sys.executable, str(SCRIPT), str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("missing.log", result.stderr)


if __name__ == "__main__":
    unittest.main()
