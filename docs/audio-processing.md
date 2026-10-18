# Microphone processing

Settings → Audio offers optional noise suppression through Apple's public AVAudioEngine voice
processing. It defaults off. Changes are captured when the next microphone recording starts;
an active engine is never reconfigured because a setting changed.

Apple couples voice processing with attenuation of other audio. Its public ducking levels have
no off option. The Audio page therefore offers Minimum, Standard and Maximum reduction while
noise suppression is enabled, with an explicit explanation of the minimum attenuation. Turning
noise suppression off disables voice processing and its audio reduction. This replaces the
original design's independently labeled ducking toggle, which the public API cannot implement
honestly. No device volume, system preference or other application's settings are modified.

The microphone engine configures processing while stopped and removes it when capture ends.
Device restarts use the same capture's settings. Unsupported devices report an engine error;
the user can disable noise suppression to retain the existing raw-input path.

Apple references:

- [Voice processing enablement](https://developer.apple.com/documentation/avfaudio/avaudioionode/setvoiceprocessingenabled(_:))
- [Other-audio ducking configuration](https://developer.apple.com/documentation/avfaudio/avaudioinputnode/voiceprocessingotheraudioduckingconfiguration)
- [Supported configuration and levels](https://developer.apple.com/documentation/avfaudio/avaudiovoiceprocessingotheraudioduckingconfiguration)

Automated tests use fake configuration nodes and in-memory settings; they never enable voice
processing on hardware or change audio device/system settings.

## Test microphone

The Audio page records at most five seconds (80,000 mono samples at 16 kHz), updates its level
meter, and plays the recording from an in-memory WAV. A five-second deadline also ends a test
when no chunks arrive. Stop, leaving Audio, or starting dictation cancels recording/playback and
discards the buffer. Permission is requested only after the user presses Test microphone.

Dictation and microphone testing share one source and exclusive capture lease; it is released
only after the native engine stops. The test never transcribes, saves audio, adds history, reads
or writes the clipboard, or loads a speech model. Device changes continue through the existing
microphone restart path; losing the input device ends the test with an error.
