## tvOS Beta 3.4.3

> **Install:** [NuvioTV-3.4.3-unsigned-release.ipa](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.4.3/NuvioTV-3.4.3-unsigned-release.ipa) requires a compatible tvOS development or sideloading signing workflow before installation.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

> 🎉 **Thank you for 200+ GitHub Stars!** A huge thank you to everyone in the community for supporting NuvioTVOS and helping reach 200+ stars on GitHub! Your feedback, issue reports, and testing make this possible.

### Apple TV-Inspired Grid View Hero Redesign

- **Native Apple TV-Style Hero Showcase:** Completely overhauled the hero slideshow in Home Grid View (`TVGridHeroSlideshowView`) with full-bleed cinematic artwork, dynamic typography, responsive action controls, and fluid focus handoff designed to mirror the native Apple TV interface.
- **Fluid Grid Navigation & Focus Memory:** Polished scroll tracking and focus restoration between the top hero carousel and multi-column catalog grids for buttery-smooth navigation.

### Enhanced Rewatch Tracking & Dynamic Multi-Watch Badges

- **Multi-Watch Count Indicators:** Rewatching content now visually tracks your completion count directly on poster cards (`WatchedCheckmarkPresentation`). The first complete watch displays a clean checkmark, while subsequent rewatches dynamically present the watch count (`2`, `3`, etc.).
- **Accurate Rewatch Preservation:** Hardened watch history ledger and sync resolution to preserve rewatch counts across Trakt, Simkl, WeTrakr, and local profiles without losing progress markers.

### Search Artwork Enrichment & Custom Addon Posters

- **Add-on Artwork Preservation:** Search result deduplication and metadata enrichment now recognize third-party catalog feeds, preserving custom posters, backdrops, and card aspect ratios instead of erroneously overwriting them with generic Cinemeta assets.
- **Configurable Search Artwork Preference:** Added `preferAddonArtworkInSearch` settings toggle with full test coverage for seamless search discovery.

### Player Subtitle Menu & UI Polish

- **Streamlined Subtitle Track Selector:** Overhauled `PlayerSubtitleMenuButton` and `SubtitleMenuFormatter` with hierarchical language grouping, sanitized provider tags, clean track subtitles, and instant selection feedback.
- **Playback Controls & Lifecycle Hardening:** Refined loading spinner overlays, benchmark completion callbacks, and startup engine warmup for near-instant playback readiness.

### Tests & Stability

- 791 automated unit and regression tests passing with 0 failures across playback backends, stream caching, subtitle rendering, sync services, and layout settings.

### Known issues

- Picture in Picture requires a supported Apple TV 4K / tvOS 15+ device.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV paths still need real-device validation; the Apple TV Simulator cannot play AV1.
