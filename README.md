# ClaudeBar

A menu-bar app for tracking Claude Code usage across multiple Anthropic accounts, on macOS and Linux, with a command-line tool that does everything the menu does.

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
- `claudebar` on the command line: usage, switching, signing in, limits and settings, locally or over SSH

## Installation

### macOS

Download the notarized .app from the [releases page](https://github.com/vinnysaj/ClaudeBar/releases). Updates are delivered in-app via Sparkle. To use `claudebar` from a terminal, click **Install claudebar** in Settings; it links the app's copy into `~/.local/bin`, where Claude Code's installer puts `claude`.

#### Keychain access

Claude Code stores its login in the macOS keychain. ClaudeBar reads and updates that item through the same system tool Claude Code itself uses (`/usr/bin/security`), so showing usage and switching accounts normally produces no keychain permission dialogs at all. If macOS does show one, click **Always Allow**. Stored credentials for non-active accounts live in ClaudeBar's own keychain item, which never prompts.

### Linux

ClaudeBar runs as a background service that does the polling and switching, with an optional menu-bar icon on the desktop. Claude Code must be installed. On x86_64 or aarch64:

```sh
mkdir -p ~/.local/bin
curl -L https://github.com/vinnysaj/ClaudeBar/releases/latest/download/claudebar-linux-$(uname -m).tar.gz | tar -xz -C ~/.local/bin
claudebar service install
```

`service install` starts the service under systemd and keeps it starting at login. On a server, `sudo loginctl enable-linger $USER` keeps it running while you're logged out. On a desktop it also starts the menu-bar icon, which needs Ubuntu 24.04 or later (or another distribution with glibc 2.38) and `sudo apt install libayatana-appindicator3-1 libcurl4t64`. `claudebar` itself is a static binary and runs anywhere.

Updates install themselves, checked daily; `claudebar config auto-update off` turns that off, and `claudebar update` installs the latest release now.

Claude Code keeps its login in `~/.claude/.credentials.json`; ClaudeBar keeps the other accounts' logins in `~/.local/share/ClaudeBar/credentials.json`, readable only by you.

## Command line

`claudebar` talks to the running app on a Mac and to the service on Linux.

```sh
claudebar                        # every account's usage, limits and pace (--json for scripts)
claudebar switch 2               # by number, email, or enough of the email
claudebar login                  # add an account
claudebar login work             # sign an account back in
claudebar limits work --weekly 80
claudebar config auto-switch on
claudebar update
```

`claudebar login` copies the sign-in link to your clipboard and prints it. Over SSH it goes to the clipboard of the machine your terminal runs on, through the terminal (OSC 52: iTerm2, Ghostty, kitty, WezTerm and Windows Terminal support it, Terminal.app doesn't; in tmux, `set -g set-clipboard on`). Open it in any browser, sign in, and paste the code the page ends on back into the terminal.

## Development

Build with `./build.sh` rather than bare `swift build`. The script signs the debug app with a stable identity; without a stable signature, macOS treats every rebuild as a new app and re-asks for keychain permission each time. Run it as `.build/debug/ClaudeBarApp`; `.build/debug/claudebar` is the command-line tool.

On Linux, `swift build` needs `libayatana-appindicator3-dev` for the menu-bar icon; `swift build --product claudebar` builds the rest without it.

