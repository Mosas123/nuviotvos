import Foundation

/// `UserDefaults` is documented as safe to use from any thread; making that
/// explicit lets stores and credentials cross isolation boundaries the same way
/// they did before Swift 6 checked them.
extension UserDefaults: @unchecked Sendable {}
