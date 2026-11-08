import PlamoKit
import SwiftUI

/// Root of the main window: sidebar + content (DeepL desktop layout).
struct MainWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.settings.hasAcceptedCurrentTerms {
            mainContent
        } else {
            TermsGateView()
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selectedSection) {
                Section {
                    ForEach([SidebarSection.translator, .glossary, .history]) { section in
                        Label(section.title, systemImage: section.symbol).tag(section)
                    }
                }
                Section("管理") {
                    ForEach([SidebarSection.models, .settings]) { section in
                        Label(section.title, systemImage: section.symbol).tag(section)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) {
                SidebarFooter()
            }
        } detail: {
            Group {
                switch model.selectedSection {
                case .translator: TranslatorView(session: model.mainSession)
                case .glossary: GlossaryView()
                case .history: HistoryView()
                case .models: ModelStoreView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ModelToolbarMenu()
            }
        }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView()
        }
    }
}

/// Shortcut hint and permission state at the bottom of the sidebar.
private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.settings.doubleCopyEnabled && model.monitor.state == .needsRelaunch {
                Button {
                    model.relaunch()
                } label: {
                    Label("再起動して ⌘C+C を有効にする", systemImage: "arrow.clockwise.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            } else if !model.shortcutPermissionsGranted && model.settings.doubleCopyEnabled {
                Button {
                    model.requestShortcutPermissions()
                } label: {
                    Label("⌘C+C を使うには許可が必要", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            } else if model.settings.doubleCopyEnabled {
                Label {
                    Text("\(model.settings.shortcut.displayString) で\nどこからでも翻訳")
                } icon: {
                    Image(systemName: "keyboard")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}

/// Model picker in the window toolbar.
struct ModelToolbarMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Section("翻訳モデル") {
                ForEach(model.models.models) { m in
                    let installed = model.models.state(for: m).isInstalled
                    Button {
                        if installed { model.models.select(m) } else { model.selectedSection = .models }
                    } label: {
                        if model.models.activeModel?.id == m.id {
                            Label(m.displayName, systemImage: "checkmark")
                        } else {
                            Text(installed ? m.displayName : "\(m.displayName)（未ダウンロード）")
                        }
                    }
                }
            }
            Divider()
            Button("モデルストアを開く…") { model.selectedSection = .models }
        } label: {
            HStack(spacing: 5) {
                if model.models.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "cpu")
                }
                Text(model.models.activeModel.map { "PLaMo \($0.sizeLabel)" } ?? "モデルなし")
            }
        }
        .help("翻訳モデルを選択")
    }
}
