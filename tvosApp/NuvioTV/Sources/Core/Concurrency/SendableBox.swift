/// Carries a value the compiler can't prove `Sendable` across an isolation
/// boundary, for call sites that already guarantee the access themselves (a
/// lock, a single owner, or an immutable object built without compiler-visible
/// `Sendable` conformance). Prefer a real `Sendable` conformance when the type
/// is ours.
struct SendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
