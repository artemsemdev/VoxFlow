#!/usr/bin/env python3
"""Install an already built, consistently signed local app with rollback."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def verify(app, identity):
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    details = subprocess.run(["codesign", "-dvv", str(app)], check=True,
                             capture_output=True, text=True).stderr
    if f"Authority={identity}" not in details.splitlines():
        raise ValueError(f"{app} is not signed by {identity}; refusing to change identity")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != "dev.artemsem.voxflow":
        raise ValueError("Unexpected application bundle identifier")
    requirement = subprocess.run(["codesign", "-d", "-r-", str(app)], check=True,
                                 capture_output=True, text=True).stdout.strip()
    if not requirement.startswith("designated =>"):
        raise ValueError("Missing designated signing requirement")
    return requirement


def install(source, destination, identity):
    source, destination = Path(source).absolute(), Path(destination).absolute()
    if source == destination or destination.is_symlink():
        raise ValueError("Installation requires a separate, non-symlink destination")
    requirement = verify(source, identity)
    existed = destination.exists()
    if existed and verify(destination, identity) != requirement:
        raise ValueError("Designated requirement changed; existing permissions may be lost")
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Stage on the destination filesystem so each rename is atomic. The old application stays
    # available until the staged copy has passed signature validation.
    scratch = Path(tempfile.mkdtemp(prefix=".voxflow-install-", dir=destination.parent))
    staged, backup = scratch / "VoxFlow.app", scratch / "previous.app"
    preserve_backup = False
    try:
        shutil.copytree(source, staged, symlinks=True)
        if verify(staged, identity) != requirement:
            raise ValueError("Staged signing requirement differs from the built app")
        if existed:
            destination.rename(backup)
        try:
            staged.rename(destination)
            if verify(destination, identity) != requirement:
                raise ValueError("Installed signing requirement differs from the built app")
        except BaseException:
            try:
                if destination.exists():
                    shutil.rmtree(destination)
                if existed:
                    backup.rename(destination)
            except BaseException as rollback_error:
                preserve_backup = True
                raise RuntimeError(f"Restore failed; previous app retained at {backup}") from rollback_error
            raise
    finally:
        if not preserve_backup:
            shutil.rmtree(scratch)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--destination", type=Path, default=Path("/Applications/VoxFlow.app"))
    parser.add_argument("--identity", default="VoxFlow Dev")
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    if args.verify_only:
        verify(args.source, args.identity)
    else:
        running = subprocess.run(["pgrep", "-x", "VoxFlow"], capture_output=True)
        if running.returncode == 0:
            parser.error("Quit VoxFlow before replacing the installed app")
        if running.returncode != 1:
            parser.error("Could not determine whether VoxFlow is running")
        install(args.source, args.destination, args.identity)
        print(f"Installed {args.destination}; open it with: open '{args.destination}'")


if __name__ == "__main__":
    main()
