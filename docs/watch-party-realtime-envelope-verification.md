# Watch Party Realtime envelope verification — Supabase Swift 2.55.4

Status: pinned SDK contract verified by static source review; fix not built or device-tested.

## Exact dependency

Nuvio's tvosApp/.package.resolved pins Supabase Swift 2.55.4 at:
fee4bd78997f8b4e919c1c9711e0cfb346fd7a55

At this revision, the modern implementation is in Sources/RealtimeV2.
Earlier reads used Sources/Realtime, which returned 404 for these files.
The release exists; those failures did not establish dependency unavailability.

## Verified call chain

- [Package.swift](https://github.com/supabase/supabase-swift/blob/fee4bd78997f8b4e919c1c9711e0cfb346fd7a55/Package.swift) declares RealtimeV2 and makes Realtime depend on it.
- [RealtimeChannelV2.swift](https://github.com/supabase/supabase-swift/blob/fee4bd78997f8b4e919c1c9711e0cfb346fd7a55/Sources/RealtimeV2/RealtimeChannelV2.swift): the JSON broadcast handler forwards message.payload to broadcast callbacks; it does not extract its inner payload. The binary JSON handler constructs an event/payload/type envelope before forwarding.
- [RealtimeChannel+AsyncAwait.swift](https://github.com/supabase/supabase-swift/blob/fee4bd78997f8b4e919c1c9711e0cfb346fd7a55/Sources/RealtimeV2/RealtimeChannel%2BAsyncAwait.swift): broadcastStream yields callback objects unchanged.
- [RealtimeChannelBroadcastTests.swift](https://github.com/supabase/supabase-swift/blob/fee4bd78997f8b4e919c1c9711e0cfb346fd7a55/Tests/RealtimeTests/RealtimeChannelBroadcastTests.swift): receive_jsonBroadcastFromBinaryFrame expects the custom count field inside the callback's inner payload. These upstream tests were read, not executed here.

The old Nuvio adapter encodes the entire object and passes it to Session, which decodes WatchPartyPlayback at the root. An envelope has no root seq/paused/position_ms/at, so it cannot decode as Playback. The try? path discards it before recording a Received transition.

## Fix in this branch

WatchPartyChannelContract.broadcastPayload validates type=broadcast, event matching the known subscription, and an object payload. WatchPartyRealtimeChannel forwards that inner object to existing Session decoders. Session membership, media, host and ordering checks remain unchanged.

Four XCTest methods were added to the existing Foundation suite. They cover pause/play field preservation, event bodies/null revocation, malformed envelopes and downstream validation. None was executed.

## Remaining validation

The pinned source mismatch is statically confirmed; attribution of every build76 symptom is not. Verify the IPA's resolved revision, compile and run tests, then build a new IPA. Test Samsung/Fire TV host to Apple TV guest without local intervention; correlate incoming/accepted/applied timestamps and simultaneous positions. Position jumps, server delivery and all device paths are not declared fixed.

No heartbeat, playback engine, backend, SDK dependency or permission changes. No private diagnostic payloads published. No request for the two SDK source files is needed now that they are retrievable by exact revision.
