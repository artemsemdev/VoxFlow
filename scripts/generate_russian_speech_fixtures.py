"""Regenerate the fixed Russian corpus locally; no uploads or voice downloads."""

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import wave

ROOT = Path(__file__).resolve().parents[1] / "VoxFlowKit/Tests/VoxFlowSpeechTests/Fixtures/RussianLongForm"
CASES = ["reminder", "conditions", "incident", "planning", "explanation", "handover", "proposal", "retrospective"]


def generate():
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise SystemExit("Install ffmpeg to regenerate fixtures; tests do not require it.")
    entries = []
    for name in CASES:
        with tempfile.TemporaryDirectory(prefix="voxflow-ru-") as temporary:
            temporary = Path(temporary)
            subprocess.run(["/usr/bin/say", "-v", "Milena", "-r", "165", "-f", str(ROOT / f"{name}.txt"),
                            "-o", str(temporary / "speech.aiff")], check=True)
            subprocess.run(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                            str(temporary / "speech.aiff"), str(temporary / "speech.wav")], check=True)
            with wave.open(str(temporary / "speech.wav")) as audio:
                assert (audio.getnchannels(), audio.getframerate(), audio.getsampwidth()) == (1, 16000, 2)
                pcm = audio.readframes(audio.getnframes())
            assert len(pcm) > 32000, f"Empty or truncated synthesis: {name}"
            parts = []
            for number, start in enumerate(range(0, len(pcm), 30 * 32000)):
                data = pcm[start:start + 30 * 32000]
                with wave.open(str(temporary / "part.wav"), "wb") as audio:
                    audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                    audio.writeframes(data)
                filename = f"{name}-{number + 1:02}.flac"
                subprocess.run([ffmpeg, "-nostdin", "-v", "error", "-y", "-i", str(temporary / "part.wav"),
                                "-c:a", "flac", str(ROOT / filename)], check=True)
                decoded = subprocess.check_output([ffmpeg, "-nostdin", "-v", "error", "-i",
                                                   str(ROOT / filename), "-f", "s16le", "-"])
                assert decoded == data, f"Lossless round-trip failed: {filename}"
                assert (ROOT / filename).stat().st_size < 1_000_000, f"Fixture exceeds repository limit: {filename}"
                parts.append(filename)
            entries.append(dict(id=name, voice="Milena", rate=165, frames=len(pcm) // 2,
                                pcmSHA256=hashlib.sha256(pcm).hexdigest(), parts=parts))
            print(name, round(len(pcm) / 32000, 2), "seconds", len(parts), "parts", flush=True)
    (ROOT / "manifest.json").write_text("[\n" + ",\n".join("  " + json.dumps(e) for e in entries) + "\n]\n")


if __name__ == "__main__":
    generate()
