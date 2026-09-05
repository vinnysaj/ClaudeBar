import Foundation
import Testing
@testable import ClaudeBar

/// `Formatting.resetDescription` reads the wall clock, so these cases are the
/// ones that hold whenever they run.
@Suite("Reset descriptions")
struct ResetDescriptionTests {
    @Test("A reset time that has passed reads as already reset")
    func pastResetReadsAsJustReset() {
        #expect(Formatting.resetDescription(from: Date(timeIntervalSinceNow: -60)) == "Just reset")
    }

    @Test("A reset time far ahead is announced rather than reported as past")
    func futureResetIsAnnounced() {
        let description = Formatting.resetDescription(from: Date(timeIntervalSinceNow: 60 * 24 * 60 * 60))
        #expect(description.hasPrefix("Resets "))
    }
}

@Suite("Number formatting")
struct NumberFormattingTests {
    @Test("Token counts are abbreviated by magnitude")
    func tokenCountsAreAbbreviated() {
        #expect(Formatting.formatTokens(0) == "0")
        #expect(Formatting.formatTokens(999) == "999")
        #expect(Formatting.formatTokens(1_000) == "1K")
        #expect(Formatting.formatTokens(12_345) == "12K")
        #expect(Formatting.formatTokens(1_200_000) == "1M")
        #expect(Formatting.formatTokens(2_500_000_000) == "2.5B")
    }

    @Test("Costs drop their cents once they run into five figures")
    func costsDropCentsWhenLarge() {
        #expect(Formatting.formatCost(0) == "$0.00")
        #expect(Formatting.formatCost(12.5) == "$12.50")
        #expect(Formatting.formatCost(9_999.99) == "$9999.99")
        #expect(Formatting.formatCost(10_000) == "$10000")
    }
}
