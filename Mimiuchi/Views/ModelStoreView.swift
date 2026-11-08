import PlamoKit
import SwiftUI

/// Model store: download, select and delete PLaMo 3 Translate models.
struct ModelStoreView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingDelete: PlamoModelDescriptor?
    @State private var errorMessage: String?

    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private var physicalMemoryGB: Int {
        Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                ForEach(model.models.models) { descriptor in
                    ModelCard(
                        descriptor: descriptor,
                        state: model.models.state(for: descriptor),
                        isActive: model.models.activeModel?.id == descriptor.id,
                        isLoaded: model.models.loadedModelId == descriptor.id,
                        memoryWarning: descriptor.recommendedMemoryGB > physicalMemoryGB ? "このMac（\(physicalMemoryGB)GB）ではメモリが不足する可能性があります" : nil,
                        onDownload: { model.models.download(descriptor) },
                        onCancel: { model.models.cancelDownload(descriptor) },
                        onSelect: { model.models.select(descriptor) },
                        onDelete: { pendingDelete = descriptor })
                }
                licenseNote
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("モデルストア")
        .onAppear { model.models.refresh() }
        .confirmationDialog(
            "\(pendingDelete?.displayName ?? "") を削除しますか？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                if let descriptor = pendingDelete {
                    do { try model.models.delete(descriptor) } catch { errorMessage = error.localizedDescription }
                }
                pendingDelete = nil
            }
        } message: {
            Text("ダウンロード済みのモデルファイル（\(byteFormatter.string(fromByteCount: pendingDelete.map { model.models.store.diskUsage(for: $0) } ?? 0))）をディスクから削除します。再度使うにはダウンロードが必要です。")
        }
        .alert("エラー", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PLaMo 3 Translate").font(.system(size: 26, weight: .bold))
            Text("Preferred Networks による翻訳特化 LLM。53 言語に対応し、Apple シリコン向け MLX 4bit 版をこの Mac 上だけで実行します（テキストは外部に送信されません）。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Label("空き容量 \(byteFormatter.string(fromByteCount: model.models.availableDiskBytes))", systemImage: "internaldrive")
                Label("メモリ \(physicalMemoryGB) GB", systemImage: "memorychip")
                Button {
                    let dir = model.models.store.rootDirectory
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                } label: {
                    Label("保存先を表示", systemImage: "folder")
                }
                .buttonStyle(.link)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
    }

    private var licenseNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ライセンス").font(.headline)
            Text(AboutText.modelLicense)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Link("PLaMo Community License を読む", destination: PlamoModelCatalog.licenseURL)
                Link("商用利用の登録（PFN）", destination: PlamoModelCatalog.commercialRegistrationURL)
            }
            .font(.system(size: 12))
            BuiltWithPLaMoBadge()
                .padding(.top, 4)
        }
        .padding(.top, 6)
    }
}

private struct ModelCard: View {
    let descriptor: PlamoModelDescriptor
    let state: ModelManager.InstallState
    let isActive: Bool
    let isLoaded: Bool
    let memoryWarning: String?
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onSelect: () -> Void
    let onDelete: () -> Void

    private let byteFormatter = ByteCountFormatter()

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.brand.gradient)
                Text(descriptor.sizeLabel)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(descriptor.displayName).font(.system(size: 16, weight: .semibold))
                    tag(descriptor.formatLabel)
                    if isActive { tag("使用中", tint: .green) }
                    if descriptor.sizeLabel == "0.8B" || descriptor.sizeLabel == "2B" { tag("おすすめ", tint: .orange) }
                }
                Text(descriptor.summary).font(.system(size: 13)).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Label(byteFormatter.string(fromByteCount: descriptor.downloadBytes), systemImage: "arrow.down.circle")
                    Label("推奨メモリ \(descriptor.recommendedMemoryGB) GB", systemImage: "memorychip")
                    Link(destination: descriptor.repositoryURL) {
                        Label("Hugging Face", systemImage: "link")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                if let memoryWarning, !state.isInstalled {
                    Label(memoryWarning, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                statusView
            }
            Spacer(minLength: 0)
            actions
        }
        .padding(16)
        .background(Color.paneBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isActive ? Color.brand.opacity(0.6) : Color.primary.opacity(0.1), lineWidth: isActive ? 1.5 : 1))
    }

    @ViewBuilder private var statusView: some View {
        switch state {
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress.fraction)
                HStack {
                    Text(progressText(progress)).monospacedDigit()
                    Spacer()
                    Text(progress.currentFile).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        case .installed(let bytes):
            Label("ダウンロード済み（\(byteFormatter.string(fromByteCount: bytes))）\(isLoaded ? " · メモリに読み込み済み" : "")", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .notInstalled:
            EmptyView()
        }
    }

    @ViewBuilder private var actions: some View {
        VStack(alignment: .trailing, spacing: 8) {
            switch state {
            case .notInstalled, .failed:
                Button("ダウンロード", action: onDownload)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brand)
            case .downloading:
                Button("キャンセル", role: .cancel, action: onCancel)
            case .installed:
                if isActive {
                    Label("使用中", systemImage: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.brand)
                        .padding(.vertical, 4)
                } else {
                    Button("このモデルを使う", action: onSelect)
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brand)
                }
                Button("削除…", role: .destructive, action: onDelete)
                    .buttonStyle(.bordered)
            }
        }
        .controlSize(.regular)
    }

    private func tag(_ text: String, tint: Color = .secondary) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func progressText(_ p: ModelDownloadProgress) -> String {
        switch p.phase {
        case .listing: return "ファイル一覧を取得中…"
        case .verifying: return "検証中… \(Int(p.fraction * 100))%"
        case .finished: return "完了"
        case .downloading:
            var s = "\(Int(p.fraction * 100))% · \(byteFormatter.string(fromByteCount: p.completedBytes)) / \(byteFormatter.string(fromByteCount: p.totalBytes))"
            if p.bytesPerSecond > 0 {
                s += " · \(byteFormatter.string(fromByteCount: Int64(p.bytesPerSecond)))/秒"
                let remaining = Double(p.totalBytes - p.completedBytes) / p.bytesPerSecond
                if remaining.isFinite, remaining > 0 { s += " · 残り約\(Int(remaining.rounded()))秒" }
            }
            return s
        }
    }
}
