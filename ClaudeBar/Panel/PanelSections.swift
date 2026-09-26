import SwiftUI

/// Every panel section lays out at this width; the menu is as wide as its widest item.
enum PanelLayout {
    static let width: CGFloat = 346
    static let horizontalPadding: CGFloat = 14
    /// The hover panels that open beside the main one.
    static let detailWidth: CGFloat = 330
}

/// Title, refresh and settings controls, then whatever stands in for the
/// account rows before there are any: the banner, a loading state, or the
/// first-run hint.
struct PanelHeaderView: View {
    let model: PanelModel
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Text("Claude")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                if self.model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Button(action: self.actions.refresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.hoverBackgroundIcon)
                }
                Button(action: self.actions.openSettings) {
                    Image(systemName: "gear")
                }
                .buttonStyle(.hoverBackgroundIcon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.trailing, -HoverBackgroundButtonStyle.iconInset)
            }
            if let updatedAt = self.model.snapshot?.updatedAt {
                Text("Updated \(Formatting.timeAgo(from: updatedAt))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Divider().padding(.top, 6)
            if let banner = self.model.snapshot?.banner {
                BannerView(banner: banner)
            }
            if let snapshot = self.model.snapshot {
                if snapshot.displays.isEmpty {
                    self.emptySection
                }
            } else {
                self.loadingSection
            }
        }
        .padding(.horizontal, PanelLayout.horizontalPadding)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var emptySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No accounts yet")
                .font(.system(size: 12, weight: .semibold))
            Text("Add Account below signs you in without touching Claude Code's own login. Running claude and /login works too; ClaudeBar picks that account up automatically.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    private var loadingSection: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text("Loading...")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

/// A sign-in in progress and the app controls along the bottom.
struct PanelFooterView: View {
    let model: PanelModel
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let signIn = self.model.signIn {
                SignInProgressRow(progress: signIn, actions: self.actions)
            }
            Divider().padding(.vertical, 6)
            self.controls
        }
        .padding(.horizontal, PanelLayout.horizontalPadding)
        .padding(.bottom, 10)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Toggle("Launch at Login", isOn: Binding(
                    get: { self.model.launchAtLogin },
                    set: { _ in self.actions.toggleLaunchAtLogin() }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add Account") { self.actions.signIn(nil) }
                    .buttonStyle(.hoverBackground)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .disabled(self.model.signIn != nil)
                Button("Quit", action: self.actions.quit)
                    .buttonStyle(.hoverBackground)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, -HoverBackgroundButtonStyle.textInset)
            }
            if let checkForUpdates = self.actions.checkForUpdates {
                HStack {
                    Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Check for Updates", action: checkForUpdates)
                        .buttonStyle(.hoverBackground)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, -HoverBackgroundButtonStyle.textInset)
                }
            }
        }
    }
}

struct BannerView: View {
    let banner: Banner

    private var color: Color {
        switch self.banner.kind {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }

    var body: some View {
        Text(self.banner.message)
            .font(.system(size: 11))
            .foregroundStyle(self.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
    }
}

/// A sign-in running in the claude CLI: where to finish it, and a way out.
struct SignInProgressRow: View {
    let progress: SignInProgress
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider().padding(.vertical, 4)
            HStack(alignment: .top, spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                Text(self.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = self.progress.problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                if let page = self.progress.page {
                    Button("Open Page", action: self.actions.openSignInPage)
                    Button(self.progress.isLinkCopied ? "Copy Again" : "Copy Link", action: self.actions.copySignInLink)
                    if page.endsOnCode {
                        Button("Paste Code", action: self.actions.pasteSignInCode)
                    }
                }
                Button("Cancel", action: self.actions.cancelSignIn)
            }
            .buttonStyle(.hoverBackground)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.leading, -HoverBackgroundButtonStyle.textInset)
        }
    }

    private var message: String {
        let account = self.progress.email ?? "the account to add"
        guard let page = self.progress.page else {
            return "Starting the sign-in to \(account)..."
        }
        if page.endsOnCode {
            return "Sign in to \(account), copy the code the page ends on, then click Paste Code."
        }
        if self.progress.isLinkCopied {
            return "Sign-in link copied. Paste it into any browser on this Mac and sign in to \(account); ClaudeBar takes it from there."
        }
        return "Sign in to \(account) in your browser; ClaudeBar takes it from there."
    }
}

extension View {
    /// The highlight behind a row that opens a hover panel, standing in for the
    /// one AppKit draws on a menu item with a submenu (it draws none for items
    /// with custom views).
    func rowHighlight(_ isHighlighted: Bool) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHighlighted ? 0.07 : 0))
                    .padding(.horizontal, 5))
            .animation(.easeOut(duration: 0.12), value: isHighlighted)
    }
}

/// Marks a row whose hover panel has more.
struct DisclosureChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}
