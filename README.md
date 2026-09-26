# ClaudeBar

A macOS menu-bar app for tracking Claude Code usage across multiple Anthropic accounts.

- Shows session, weekly, and per-model usage for every signed-in account at once
- One-click account switching: ClaudeBar swaps the credentials Claude Code reads, and running `claude` sessions pick up the new account within seconds
- Add accounts without touching the login your `claude` sessions run on: Add Account runs Claude Code's own sign-in in a separate config home, stores the new account, and cleans up after itself. A signed-out account gets a Sign In button the same way. The sign-in page opens in your default browser, or Settings can have ClaudeBar copy its link instead, to paste into any browser or profile on this Mac. Running `/login` in `claude` still works too — ClaudeBar detects and stores that account automatically
- Session and weekly limits for every account, with per-account overrides: give your main account a lower weekly limit and the rest stays free for claude.ai
- A "Next" badge recommends the account with room under both of its limits whose weekly window resets soonest
- Optional auto-switching moves the login to that account before the active one reaches either limit, polling faster the harder a session is being used, and stays put rather than landing on an account that's nearly full (off by default; configure it from the gear icon)
- Every usage reading is kept for five weeks to learn your pace: how fast each account fills per hour of work, and when in the week you tend to work (seeded from the work hours you set)
- Hover an account for its details: usage against its limits, current and typical pace, when it would reach its limits, a chart of the week so far and where it's headed, and its limits
- Usage comes straight from Anthropic's OAuth endpoints — no CLI processes are spawned
- Cost & Pace: estimated costs for today and the last 30 days from your local Claude Code logs, and a one-line verdict on whether your accounts carry the week at your current pace. Hover it for tokens by hour over the last week, so big sessions stand out as spikes, then the work each account has left and when you tend to work
- A global keyboard shortcut shows or hides the panel from any app; set it in Settings

## Installation

Download the notarized .app from the [releases page](https://github.com/vinnysaj/ClaudeBar/releases). Updates are delivered in-app via Sparkle.

### Keychain access

Claude Code stores its login in the macOS keychain. ClaudeBar reads and updates that item through the same system tool Claude Code itself uses (`/usr/bin/security`), so showing usage and switching accounts normally produces no keychain permission dialogs at all. If macOS does show one, click **Always Allow**. Stored credentials for non-active accounts live in ClaudeBar's own keychain item, which never prompts.

## Development

Build with `./build.sh` rather than bare `swift build`. The script signs the debug binary with a stable identity; without a stable signature, macOS treats every rebuild as a new app and re-asks for keychain permission each time.

