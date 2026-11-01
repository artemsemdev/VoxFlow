# VoxFlow Mac App Store — Privacy Policy

Last updated: 1 November 2026

This policy covers **VoxFlow: Offline Transcription**, the macOS App Store edition
with bundle identifier `dev.artemsem.voxflow.store`, published by Ainstainer DACH GmbH.

## Speech and files stay on your Mac

VoxFlow processes microphone audio and the audio/video files you choose locally.
It does not upload recordings, file contents, transcripts or drafts to the developer
or an online transcription service. It has no account, advertising, tracking SDK,
analytics service or developer-operated backend.

Microphone access is requested when you start dictation. Recording stops when you
stop dictation or after the configured silence interval. Captured audio is processed
in memory; VoxFlow does not create a permanent recording of your dictation.
You can revoke microphone access in macOS System Settings → Privacy & Security.

## Local storage and your control

The app starts with an empty draft and queue. It does not import data or preferences
from the separately distributed desktop edition. Your dictation draft, preferences,
downloaded speech models and default transcript exports are stored in the app's
macOS sandbox. Source audio/video files remain in the locations you selected.

The draft is saved locally as you edit it. To clear it, select all text in the draft
and delete it. Remove downloaded models using the Models screen. Exported files
remain until you delete them in Finder; use Reveal in Finder to locate an export.
The processing queue is not a persistent history database.

Drafts and exports are ordinary local files; VoxFlow does not apply its own file
encryption. macOS account permissions, FileVault and any backups you configure
control their protection and retention. Copying text places it on the system
clipboard. Exporting to a cloud-synced folder can cause your sync provider to upload
that file according to your settings. These actions are under your control.

## Model downloads and network connections

Speech models are downloaded only when you request them in the app. Downloads use
HTTPS from Hugging Face and its delivery infrastructure. Those services receive
normal connection information such as an IP address and the requested model URL;
they do not receive your audio, documents or transcripts from VoxFlow. Their handling
of connection data is described in the [Hugging Face privacy policy](https://huggingface.co/privacy).
After a model is installed, transcription works without a network connection.

Apple handles App Store purchases and may provide app diagnostics according to your
Apple settings. VoxFlow does not receive your payment card details. See
[Apple's privacy policy](https://www.apple.com/legal/privacy/).

## Support and policy changes

For questions or requests, use [VoxFlow support](https://github.com/artemsemdev/VoxFlow/issues).
GitHub issues are public: describe the problem without posting private transcripts,
recordings, passwords or other sensitive information. GitHub handles information
you choose to submit under its own privacy policy.

We cannot retrieve or erase local recordings, drafts or exports remotely because
VoxFlow does not send them to us. If app behavior changes, this policy will be updated
and the date above will identify the revision.
