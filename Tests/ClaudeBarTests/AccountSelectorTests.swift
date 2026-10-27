import Foundation
import Testing
@testable import ClaudeBarCore

@Suite("Account selector")
struct AccountSelectorTests {
    /// In status order, so the first is number 1.
    private let displays = [
        "ann@example.com", "joann@example.com", "annie@example.com", "agent007@example.com",
    ].enumerated().map { index, email in
        AccountDisplay(
            account: Account(
                id: "00000000-0000-0000-0000-00000000000\(index)", email: email, organizationName: nil,
                oauthAccountRaw: nil, displayOrder: index, needsRelogin: false, preferences: .default),
            usage: nil, isActive: index == 0, isRecommended: false, isStale: false,
            limits: UsageFixture.limits)
    }

    @Test(
        "Picks the account a selector names: by number, exact email, id, or a unique part of the email",
        arguments: [
            ("2", "joann@example.com"),
            // Also part of joann's email, but an exact match wins.
            ("ann@example.com", "ann@example.com"),
            ("ANNIE@example.com", "annie@example.com"),
            ("00000000-0000-0000-0000-000000000002", "annie@example.com"),
            ("joann", "joann@example.com"),
        ])
    func picksTheNamedAccount(selector: String, email: String) throws {
        #expect(try AccountSelector.resolve(selector, in: self.displays).account.email == email)
    }

    @Test(
        "Refuses rather than guesses: a partial match of several, or a number past the list even when an email holds it",
        arguments: [
            ("ann", AccountSelector.Failure.ambiguous(
                "ann", matches: ["ann@example.com", "joann@example.com", "annie@example.com"])),
            ("7", .noMatch("7")),
            ("0", .noMatch("0")),
            ("bob", .noMatch("bob")),
        ])
    func refusesUnclearSelectors(selector: String, failure: AccountSelector.Failure) {
        #expect(throws: failure) {
            try AccountSelector.resolve(selector, in: self.displays)
        }
    }
}
