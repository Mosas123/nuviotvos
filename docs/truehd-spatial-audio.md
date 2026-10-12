# Optional TrueHD Atmos spatial audio

In **Settings → Playback → Player**, enable **TrueHD Atmos Spatial Audio (Beta)**.
The preference is off by default, belongs to the current profile, and applies to
subsequent playback loads. It uses AetherEngine; MPVKit and external players retain
their existing behavior. The switch is disabled below tvOS 26, and playback also
ignores an enabled preference synced from a newer device.

For supported 48 kHz TrueHD Atmos video-on-demand sources, the engine decodes the
object presentation and timed metadata, renders to a fixed 9.1.6 (16-channel) bed,
encodes APAC, and plays through the native HLS/AVPlayer path. The upstream bitrate
default is 320 kbps per output channel (5.12 Mbps for this layout).

APAC is lossy. This is not TrueHD bitstream passthrough and does not send the
original dynamic objects to the receiver for independent rendering. Other source
formats, unsupported routes, and failures to start the spatial path retain the
engine's existing audio bridge behavior. A fixed 9.1.6 render is not a claim of
perfect reproduction on every speaker layout. The option remains experimental.

## Dependencies and compatibility

- AetherEngine 7.34.1, preserving Nuvio's local integrations.
- FFmpegBuild 3.7.0 with the existing AetherLib module names for MPVKit coexistence.
- LibTrueHD 2.2.0, pinned exactly, with its licenses/notices in app resources.
- Minimum app deployment target: tvOS 18, required by the decoder dependency.
- APAC encoding requires tvOS 26 or later, independently of the app minimum.

The two new localization keys have English fallback text in all supported locales.

## Listening report

The contributor reports that an earlier personal Nuvio 3.4.2 build using these
engine versions and the same fixed 9.1.6 configuration worked “amazingly well”
with locally streamed TrueHD Atmos movies on an Apple TV 4K (3rd generation),
tvOS 27, and a Sonos surround system. That was a personal build with the option
always enabled, not the new settings UI. This is a subjective listening report,
not a measurement of object accuracy, losslessness, or universal compatibility.

Credit for the renderer/encoder implementation belongs to AetherEngine and its
upstream contributors, including the Silo implementation credited in AetherEngine's
7.34.0 release notes. LibTrueHD packages the truehdd Rust decoder. This contribution
updates Nuvio's integration and adds its persisted opt-in control.
