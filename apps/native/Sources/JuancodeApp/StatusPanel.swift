import SwiftUI
import JuancodeCore
import JuancodeServices

/// Per-provider auth + MCP-server health — the native analogue of the web
/// `StatusPanel.tsx`. Lists each provider (claude/codex) with an availability
/// dot, version + command, and its MCP servers with a normalized health dot,
/// transport badge, detail, and auth scheme. Reads the in-process status cache
/// on `AppModel` (populated by `getAllStatus`, which shells into the real CLIs).
/// Presented as a sheet from the sidebar toolbar, like `SearchPanel`.
struct StatusPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Auth & MCP status").font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button { model.loadStatus() } label: {
                    Text(model.statusLoading ? "…" : "Refresh").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .disabled(model.statusLoading)
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Close")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            content
        }
        .frame(width: 560, height: 460)
        .onAppear { if model.providerStatus == nil { model.loadStatus() } }
    }

    private var subtitle: String {
        if model.statusLoading && model.providerStatus == nil { return "checking…" }
        if model.providerStatus != nil { return "confirm your servers are live" }
        return ""
    }

    @ViewBuilder private var content: some View {
        if let providers = model.providerStatus {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(providers, id: \.id) { p in
                        ProviderCard(provider: p)
                    }
                }
                .padding(12)
            }
        } else {
            VStack { Spacer(); Text("checking…").font(.system(size: 12)).foregroundStyle(.secondary); Spacer() }
                .frame(maxWidth: .infinity)
        }
    }
}

/// One provider: availability dot + label + version, command on the trailing
/// edge, optional warning/error banners, then its MCP server rows.
private struct ProviderCard: View {
    let provider: ProviderStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(provider.available ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(provider.label).font(.system(size: 13, weight: .medium))
                if let version = provider.version {
                    Text(version).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(provider.command)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(provider.command)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if let warning = provider.warning {
                Divider()
                Text("\u{26A0} \(warning)")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = provider.error {
                Divider()
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if provider.error == nil && provider.mcpServers.isEmpty {
                Divider()
                Text("No MCP servers configured.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(provider.mcpServers.enumerated()), id: \.offset) { _, s in
                Divider()
                ServerRow(server: s)
            }
        }
        .background(Color(NSColor.textBackgroundColor).opacity(0.4))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// One MCP server row: health dot, name, transport badge, monospaced detail,
/// optional auth scheme, trailing status text. Mirrors the web `ServerRow`.
private struct ServerRow: View {
    let server: McpServerStatus

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 7, height: 7)
                .help(server.displayStatus)
            Text(server.name).font(.system(size: 12, weight: .medium))
            if let transport = server.transport {
                Text(transport.uppercased())
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Text(server.detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(server.detail)
            if let auth = server.auth {
                Text(auth).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Text(server.displayStatus)
                .font(.system(size: 11))
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var dotColor: Color { StatusPanel.color(for: server.presentation.palette) }
    private var textColor: Color { StatusPanel.color(for: server.presentation.palette) }
}

extension StatusPanel {
    /// Map a pure `HealthPalette` (from JuancodeServices) to a SwiftUI `Color`.
    /// Kept here so the health → palette logic stays SwiftUI-free and testable.
    static func color(for palette: HealthPalette) -> Color {
        switch palette {
        case .emerald: return .green
        case .amber: return .orange
        case .sky: return .blue
        case .red: return .red
        case .neutralStrong: return .secondary
        case .neutral: return .secondary
        }
    }
}
