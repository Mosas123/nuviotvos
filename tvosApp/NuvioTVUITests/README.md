# tvOS UI suite — developer validation

These sources use XCUIRemote directional presses and Select/Menu, not touch gestures.
The helper checks focus before Select. Legacy poster-image selectors must resolve to
one enclosing accessible button. Missing/ambiguous controls, missing focus, changed
target identity and bounded navigation failure record a test failure; Select is not
sent to an arbitrary focused element. Custom focus guides may need fixture-specific
routes. The geometric route search is limited to 40 presses and is not proof that all
screens can be navigated automatically.

Catalog-toggle and touch pull-to-refresh cases are explicitly skipped until their
fixtures/observable supported behavior exist. Other legacy fixed waits, broad outcome
assertions, English labels and external catalog/account data still need review.
Remote presses at a scroll boundary need not change focus; existing scroll/performance
tests do not establish frame rate, memory bounds or that all content was traversed.

PR #240 supplies source fixes. PR #241 registers the target and shared NuvioTV-UI
scheme and includes the source prerequisite. Merge #240 first when practical.
No app code is changed. This update has NOT been generated, compiled or executed.
The maintainer owns build-for-testing and simulator/device validation before merge.

After generating the workspace with the repository's pinned Tuist setup:

```sh
xcodebuild build-for-testing \
  -workspace tvosApp/NuvioTV.xcworkspace \
  -scheme NuvioTV-UI \
  -destination 'platform=tvOS Simulator,name=Apple TV' \
  CODE_SIGNING_ALLOWED=NO
```

Choose an installed Apple TV simulator destination if that example name differs.
Then configure the catalog, Continue Watching, watchlist and language fixtures and
run supported flows. Check that unresolvable/unfocused controls fail before Select,
poster selection opens the intended Details screen, Menu returns correctly, and the
two unsupported/unfinished cases are reported as skipped. Record SDK/destination and
results in the PR. The existing unit scheme and CI selection are unchanged.
