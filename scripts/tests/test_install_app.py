import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("install_app", Path(__file__).parents[1] / "install_app.py")
INSTALL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSTALL)


class InstallTests(unittest.TestCase):
    def test_bad_staged_signature_preserves_existing_app(self):
        with tempfile.TemporaryDirectory() as root:
            source, destination = self.apps(root)
            def verify(app, identity):
                if app != source and app != destination:
                    raise ValueError("damaged staged signature")
                return "same requirement"
            with patch.object(INSTALL, "verify", side_effect=verify):
                with self.assertRaisesRegex(ValueError, "damaged"):
                    INSTALL.install(source, destination, "VoxFlow Dev")
            self.assertEqual((destination / "version").read_text(), "old")

    def test_changed_requirement_cannot_replace_existing_app(self):
        with tempfile.TemporaryDirectory() as root:
            source, destination = self.apps(root)
            with patch.object(INSTALL, "verify", side_effect=lambda app, _: str(app)):
                with self.assertRaisesRegex(ValueError, "requirement"):
                    INSTALL.install(source, destination, "VoxFlow Dev")
            self.assertEqual((destination / "version").read_text(), "old")

    def test_failed_final_verification_rolls_back(self):
        with tempfile.TemporaryDirectory() as root:
            source, destination = self.apps(root)
            def verify(app, identity):
                if app == destination and (app / "version").read_text() == "new":
                    raise ValueError("final verification failed")
                return "same requirement"
            with patch.object(INSTALL, "verify", side_effect=verify):
                with self.assertRaisesRegex(ValueError, "final verification"):
                    INSTALL.install(source, destination, "VoxFlow Dev")
            self.assertEqual((destination / "version").read_text(), "old")

    def test_verified_install_preserves_source(self):
        with tempfile.TemporaryDirectory() as root:
            source, destination = self.apps(root)
            with patch.object(INSTALL, "verify", return_value="same requirement"):
                INSTALL.install(source, destination, "VoxFlow Dev")
            self.assertEqual((destination / "version").read_text(), "new")
            self.assertEqual((source / "version").read_text(), "new")

    def test_first_install_creates_destination(self):
        with tempfile.TemporaryDirectory() as root:
            source, destination = self.apps(root)
            INSTALL.shutil.rmtree(destination)
            with patch.object(INSTALL, "verify", return_value="same requirement"):
                INSTALL.install(source, destination, "VoxFlow Dev")
            self.assertEqual((destination / "version").read_text(), "new")

    def test_failed_restore_retains_recoverable_backup(self):
        with tempfile.TemporaryDirectory() as root:
            source, destination = self.apps(root)
            rename = Path.rename
            def cannot_restore(path, target):
                if path.name == "previous.app":
                    raise PermissionError("restore denied")
                return rename(path, target)
            def verify(app, identity):
                if app == destination and (app / "version").read_text() == "new":
                    raise ValueError("bad installed signature")
                return "same requirement"
            with patch.object(INSTALL, "verify", side_effect=verify), patch.object(Path, "rename", cannot_restore):
                with self.assertRaisesRegex(RuntimeError, "previous app retained"):
                    INSTALL.install(source, destination, "VoxFlow Dev")
            backups = list(destination.parent.glob(".voxflow-install-*/previous.app/version"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_text(), "old")

    @staticmethod
    def apps(root):
        source = Path(root) / "build" / "VoxFlow.app"
        destination = Path(root) / "Applications" / "VoxFlow.app"
        for path, version in [(source, "new"), (destination, "old")]:
            path.mkdir(parents=True)
            (path / "version").write_text(version)
        return source, destination


if __name__ == "__main__":
    unittest.main()
