## tvOS Beta 3.4.4

> **Install:** [NuvioTV-3.4.4-unsigned-release.ipa](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.4.4/NuvioTV-3.4.4-unsigned-release.ipa) requires a compatible tvOS development or sideloading signing workflow before installation.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

> 🎉 **Thank you for 200+ GitHub Stars!** A huge thank you to everyone in the community for supporting NuvioTVOS and helping reach 200+ stars on GitHub! Your feedback, issue reports, and testing make this possible.

### Redesigned Playback Info & Real-Time Telemetry Dashboard

- **Horizontal Telemetry Glass Cards:** Completely overhauled the Playback Info tab in the Siri Remote Scene panel (`ScenePanelView.swift`) into a sleek horizontal multi-card dashboard inspired by modern Apple TV metrics.
- **Engine & Video Stream Insights:** Real-time inspection of active engine (AetherEngine, MPVKit, AVPlayer), engine version, container format, video codec, resolution, framerate, video bitrate, decoder pipeline, and dynamic range with dedicated Dolby Vision profile identification.
- **Comprehensive Audio & Spatial Metrics:** Live display of active audio codec, channel layout (e.g. 5.1, 7.1, Stereo), language, audio bitrate, spatial audio format confirmation (Dolby Atmos, TrueHD APAC 9.1.6, DTS:X), and audio rendering pipeline.

### AetherEngine 7.36.0, DTS:X & TrueHD Atmos Spatial Audio

- **AetherEngine 7.36.0 Upgrade:** Upgraded AetherEngine to 7.36.0 with native DTS:X, multi-channel bitstreaming, and Dolby Atmos audio output activation.
- **Opt-In TrueHD Atmos Spatial Audio:** Added per-profile TrueHD Atmos spatial audio decoding toggle with automatic APAC fallback detection.
- **Native Player External Mode:** Added Native Player (system AVPlayer) as an external player target with seamless playback coordination.

### Simkl Synchronization & Multi-Account Hardening

- **Atomic Snapshots & Lineage Integrity:** Hardened Simkl activity, history, and library item synchronization with atomic snapshots and profile store cache isolation.
- **Race Condition & Token Refresh Fixes:** Eliminated PIN authorization races, token rotation memory leaks, and stale commit overrides after profile switches or cancellation.
- **Precise History Identity Resolution:** Prevented cross-show watch state merging by title/year fallback for Simkl items with canonical identifiers.

### Cloud Debrid, TorBox, SMB & Jellyfin Enhancements

- **Extended Debrid Batch Ingest:** Scaled Real-Debrid cache availability resolution beyond 50 hashes with chunked batching.
- **Episode Boundary Token Matching:** Fixed episode token recognition in multi-season debrid packs.
- **Provider Ownership & Cloud Fallback Isolation:** Isolated playback provider context in TorBox and cloud sources to prevent incorrect fallbacks.
- **SMB & Jellyfin Resilience:** Hardened direct SMB title matching, connection generations, and graceful disconnection teardown.

### Playback, Subtitles & Telemetry Fixes

- **Scoped Subtitle Headers:** Enforced same-origin security on external subtitle headers.
- **Dynamic HDR Headroom:** Enhanced HDR presentation with real-time EDR headroom calibration.
- **Persistent Cache Validation:** Ensured cache reuse properly validates upstream headers and conditional etags.
- **Home Geometry & UI Performance:** Prevented unnecessary GeometryReader re-renders in Home backdrop and folder shelves.

### Tests & Stability

- 877 automated unit and regression tests passing with 0 failures across playback backends, stream caching, subtitle rendering, sync services, and layout settings.

### Known issues

- Picture in Picture requires a supported Apple TV 4K / tvOS 15+ device.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV paths still need real-device validation; the Apple TV Simulator cannot play AV1.
