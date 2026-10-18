import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "check_build_logs.py"


class XCResultWarnings(unittest.TestCase):
    def check_report(self, report):
        with tempfile.TemporaryDirectory() as directory:
            log = pathlib.Path(directory) / "test.log"
            log.write_text("Tests passed.\n")
            result = pathlib.Path(directory) / "result.json"
            if report is not None:
                result.write_text(report if isinstance(report, str) else json.dumps(report))
            return subprocess.run([sys.executable, str(SCRIPT), str(log), "--xcresult-json", str(result)],
                                  capture_output=True, text=True)

    def test_focus_warning_without_warning_word_fails(self):
        message = "Accessing FocusState's value outside of the body of a View."
        report = {"issues": {"testWarningSummaries": {"_values": [
            {"message": {"_value": message}}
        ]}}}
        result = self.check_report(report)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(message, result.stderr)

    def test_build_warning_inside_an_action_fails(self):
        report = {"issues": {}, "actions": {"_values": [{"actionResult": {"issues": {
            "warningSummaries": {"_values": [{"message": {"_value": "Unused declaration"}}]}
        }}}]}}
        result = self.check_report(report)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Unused declaration", result.stderr)

    def test_empty_warning_collections_pass(self):
        result = self.check_report({"issues": {"testWarningSummaries": {"_values": []}}})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_or_invalid_report_cannot_pass(self):
        for report in (None, "{", [], {"unrelated": "JSON"}):
            with self.subTest(report=report):
                result = self.check_report(report)
                self.assertEqual(result.returncode, 2, result.stderr)

    def test_malformed_warning_collection_cannot_pass(self):
        result = self.check_report({"issues": {"testWarningSummaries": {"_values": "not an array"}}})
        self.assertEqual(result.returncode, 2, result.stderr)


if __name__ == "__main__":
    unittest.main()
