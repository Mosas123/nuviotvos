# Vendored playback dependencies

## AetherEngine (pin 7.34.1)

Local pin of [AetherEngine 7.34.1](https://github.com/superuser404notfound/AetherEngine/releases/tag/7.34.1) with imports rewritten to the namespaced FFmpeg modules below.

## FFmpegBuild 3.7.0 (namespaced upstream)

Local pin of [FFmpegBuild 3.7.0](https://github.com/superuser404notfound/FFmpegBuild/tree/3.7.0). The upstream release ships the nine dynamic frameworks and SwiftPM targets under the `AetherLib*` namespace so they can embed next to MPVKit’s `Libav*` stack in the same app binary. The umbrella product is `AetherFFmpegBuild`.

| Upstream module | Nuvio module / framework |
|---|---|
| Libavcodec | AetherLibavcodec |
| Libavformat | AetherLibavformat |
| Libavutil | AetherLibavutil |
| Libswresample | AetherLibswresample |
| Libswscale | AetherLibswscale |
| Libavfilter | AetherLibavfilter |
| Libdav1d | AetherLibdav1d |
| Libzimg | AetherLibzimg |
| Libzvbi | AetherLibzvbi |

### Refreshing from upstream

1. Clone upstream FFmpegBuild at the desired tag into a temp dir.
2. For 3.0.0 and later, copy the already-namespaced `AetherLib*.xcframework` trees directly; do not run `namespace_ffmpegbuild.py` on them.
3. For older unprefixed releases, restore `Lib*.xcframework` trees and run `python3 Vendor/namespace_ffmpegbuild.py` once.
4. Rebase AetherEngine and retain its `../FFmpegBuild` path dependency and `import AetherLib*` names.

Keep the AetherEngine patch surface minimal so rebases stay manageable.

The Nuvio host offers an off-by-default setting for TrueHD Atmos object rendering to 9.1.6 APAC. LibTrueHD is pinned to 2.2.0; APAC rendering requires tvOS 26 or later and a supported 48 kHz TrueHD Atmos VOD source. The engine retains its ordinary audio bridge for other content.
