import SwiftUI
import JuancodeServices

/// The bottom shell-terminal panel for ONE workdir, VS Code-style: a tab strip of
/// plain shell terminals plus the active tab's pane(s). Scope is PER-WORKDIR — the
/// panel is keyed by folder `cwd` in `AppModel`, so every session in a folder shares
/// the same terminals and a session switch within the folder shows them unchanged.
///
/// The pure tab/pane layout lives in `TerminalPanelModel`; this view stays thin,
/// rendering the model and routing tab/split/close actions back to `AppModel`. Each
/// pane is backed by a live `EphemeralPty` (a `$SHELL -i` spawned in `cwd`) rendered
/// by `SwiftTermEphemeral`.
struct BottomTerminalPanel: View {
    @Environment(AppModel.self) private var model
    let cwd: String
    /// True while the panel is kept mounted but collapsed to zero height (the
    /// keep-alive toggle, juancode-it1). Threaded into each pane's terminal wrapper,
    /// which freezes pty sizing and pauses surface rendering until re-shown.
    var hidden: Bool = false

    private var panel: TerminalPanelModel { model.terminalPanel(cwd) }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appSurface)
    }

    private var tabStrip: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(panel.tabs) { tab in
                        tabChip(tab)
                    }
                }
                .padding(.horizontal, 6)
            }
            Spacer(minLength: 0)
            Button {
                model.splitActiveTerminal(cwd: cwd)
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .buttonStyle(.borderless)
            .help("Split the active terminal into two panes")
            .disabled(splitDisabled)
            .clickCursor()
            Button {
                model.openTerminalTab(cwd: cwd)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New terminal")
            .padding(.trailing, 6)
            .clickCursor()
        }
        .frame(height: 30)
    }

    private var splitDisabled: Bool {
        guard let active = panel.activeTab else { return true }
        return active.isSplit
    }

    private func tabChip(_ tab: TerminalTab) -> some View {
        let active = tab.id == panel.activeTabID
        return HStack(spacing: 5) {
            Image(systemName: "terminal").font(.system(size: 10))
            Text(tab.title).font(.system(size: 11)).lineLimit(1)
            Button {
                model.closeTerminalTab(cwd: cwd, tab: tab.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("Close terminal")
            .clickCursor()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(active ? Color.accentColor.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { model.selectTerminalTab(cwd: cwd, tab: tab.id) }
    }

    @ViewBuilder
    private var content: some View {
        if let tab = panel.activeTab {
            if tab.isSplit {
                HStack(spacing: 0) {
                    paneView(tab.panes[0])
                    Divider()
                    paneView(tab.panes[1])
                }
            } else {
                paneView(tab.panes[0])
            }
        } else {
            ContentUnavailableView {
                Label("No terminal", systemImage: "terminal")
            } description: {
                Text("Open a shell terminal in this folder with +.")
            }
        }
    }

    /// One shell pane. Keyed by pane id so each pty binds to a stable view; if the
    /// pty has exited (or failed to spawn) we show a placeholder rather than crash.
    @ViewBuilder
    private func paneView(_ pane: TerminalPaneID) -> some View {
        if let pty = model.shellPty(pane) {
            Group {
                if TerminalBackendChoice.useGhostty {
                    GhosttyEphemeral(pty: pty, hidden: hidden, onExit: {})
                } else {
                    SwiftTermEphemeral(pty: pty, hidden: hidden, onExit: {})
                }
            }
            .background(Color.black)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(pane)
        } else {
            Color.appSurface
                .overlay(Text("Shell exited").font(.system(size: 11)).foregroundStyle(.secondary))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(pane)
        }
    }
}
