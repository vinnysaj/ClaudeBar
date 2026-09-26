# ClaudeBar

## Tests
- Add a unit test only when a bug would stay invisible while using the app: decision logic, boundaries, ordering, and rare states like limits reached, windows resetting, relogin, or grace periods.
- Don't test what a glance at the app shows (formatting, layout, copy), constants, one-line arithmetic, pass-through code, or Swift/Foundation behavior.
- A test must fail under a plausible bug in the code it covers; if no realistic mutation breaks it, delete it. Derive expected values from the rule, never from the implementation's formula.
- Test pure functions over snapshots with an injected `now`: no wall clock, keychain, network, or UI.
- One test per rule or boundary; fold near-duplicates into `@Test(arguments:)`.
