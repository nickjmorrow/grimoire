import Testing
@testable import GrimoireUI

@Suite struct SmokeTests {
    @Test func packageBuilds() { #expect(true) }
}
