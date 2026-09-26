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
                if snapshot.displays.isEmpty && !snapshot.isPendingAdd {
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
            Text("Sign into Claude Code (run claude and /login) and ClaudeBar will pick the account up automatically.")
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

/// The pending-add hint, costs, and the app controls along the bottom.
struct PanelFooterView: View {
    let model: PanelModel
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if self.model.snapshot?.isPendingAdd == true {
                PendingAddRow(onCancel: self.actions.cancelAddAccount)
            }
            if let snapshot = self.model.snapshot {
                self.costOrScanSection(snapshot)
            }
            Divider().padding(.vertical, 6)
            self.controls
        }
        .padding(.horizontal, PanelLayout.horizontalPadding)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func costOrScanSection(_ snapshot: AccountsSnapshot) -> some View {
        if let cost = snapshot.cost, cost.todayTokens > 0 || cost.last30DaysTokens > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Divider().padding(.vertical, 6)
                Text("Cost")
                    .font(.system(size: 13, weight: .semibold))
                Text("Today: \(Formatting.formatCost(cost.todayCostUSD)) \u{00B7} \(Formatting.formatTokens(cost.todayTokens)) tokens")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Last 30 days: \(Formatting.formatCost(cost.last30DaysCostUSD)) \u{00B7} \(Formatting.formatTokens(cost.last30DaysTokens)) tokens")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if !cost.unpricedModels.isEmpty {
                    Text("Totals exclude \(cost.unpricedModels.joined(separator: ", ")) \u{2014} no published rates yet")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if let progress = self.model.scanProgress, !progress.isComplete {
            VStack(alignment: .leading, spacing: 4) {
                Divider().padding(.vertical, 6)
                HStack(spacing: 6) {
                    Spacer()
                    Text("Scanning logs...")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if progress.totalFiles > 0 {
                        Text("\(progress.scannedFiles)/\(progress.totalFiles)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                if progress.totalFiles > 0 {
                    ScanProgressBar(fraction: progress.fraction)
                }
            }
        }
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
                Button("Add Account", action: self.actions.addAccount)
                    .buttonStyle(.hoverBackground)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .disabled(self.model.snapshot?.isPendingAdd == true)
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

struct PendingAddRow: View {
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider().padding(.vertical, 4)
            HStack(alignment: .top, spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                Text("Run claude and use /login to sign into the other account. ClaudeBar will detect it automatically.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Cancel", action: self.onCancel)
                .buttonStyle(.hoverBackground)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, -HoverBackgroundButtonStyle.textInset)
        }
    }
}

struct ScanProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: max(0, geometry.size.width * CGFloat(min(self.fraction, 1))))
            }
        }
        .frame(height: 3)
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
