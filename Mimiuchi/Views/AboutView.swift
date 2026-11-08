import AppKit
import PlamoKit
import SwiftUI

/// Project page and contact (Terms of Use, Article 10).
enum AppLinks {
    static let repository = URL(string: "https://github.com/uni4029/Mimiuchi")!
    static let issues = URL(string: "https://github.com/uni4029/Mimiuchi/issues")!
}

/// User-facing license wording shared by the About screens, the model store and onboarding.
enum AboutText {
    static let modelLicense =
        "モデルは PLaMo Community License で提供されており、ダウンロードして使うとこのライセンスに同意したことになります。個人の私的な利用や学術用途などの非商用利用は無料です。業務での利用（組織内での利用を含む）は商用利用にあたり、PFN への登録（売上 10 億円以下なら無料）または契約が必要です。"
    static let unofficial = "Mimiuchi は個人が開発したアプリで、Preferred Networks の公式製品ではありません。"
}

/// A license text bundled in `Contents/Resources/Licenses` (the repository's `Licenses/` folder).
struct LicenseDocument: Identifiable, Hashable {
    /// File name in `Licenses/` without `.txt`.
    let id: String
    let name: String
    let license: String
    let usage: String

    var text: String {
        guard let url = Bundle.main.url(forResource: id, withExtension: "txt", subdirectory: "Licenses"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "ライセンス文が見つかりません（Licenses/\(id).txt）。" }
        return text
    }

    static let plamoJapanese = LicenseDocument(
        id: "PLaMo-Community-License-ja", name: "PLaMo Community License（日本語）",
        license: "PLaMo Community License", usage: "翻訳モデル PLaMo 3 Translate と PlamoKit")
    static let plamoEnglish = LicenseDocument(
        id: "PLaMo-Community-License-en", name: "PLaMo Community License (English)",
        license: "PLaMo Community License", usage: "翻訳モデル PLaMo 3 Translate と PlamoKit")

    /// Open-source software compiled into the app (keep in sync with `Licenses/README.md`).
    static let openSource: [LicenseDocument] = [
        LicenseDocument(
            id: "Mimiuchi", name: "Mimiuchi", license: "Apache License 2.0",
            usage: "このアプリのコード（PFN のコードから移植した部分を除く）"),
        LicenseDocument(id: "mlx-swift", name: "MLX Swift", license: "MIT License", usage: "推論エンジン"),
        LicenseDocument(id: "mlx", name: "MLX", license: "MIT License", usage: "MLX Swift に含まれる機械学習フレームワーク"),
        LicenseDocument(id: "mlx-c", name: "MLX C", license: "MIT License", usage: "MLX Swift に含まれる C API"),
        LicenseDocument(id: "mlx-lm", name: "MLX LM", license: "MIT License", usage: "PLaMo 3 のモデルコードの元になったコード"),
        LicenseDocument(id: "PocketFFT", name: "PocketFFT", license: "BSD 3-Clause License", usage: "MLX に含まれるライブラリ"),
        LicenseDocument(id: "metal-cpp", name: "metal-cpp", license: "Apache License 2.0", usage: "MLX に含まれるライブラリ"),
        LicenseDocument(id: "fmt", name: "{fmt}", license: "MIT License", usage: "MLX に含まれるライブラリ"),
        LicenseDocument(id: "nlohmann-json", name: "JSON for Modern C++", license: "MIT License", usage: "MLX に含まれるライブラリ"),
        LicenseDocument(
            id: "swift-numerics", name: "Swift Numerics", license: "Apache License 2.0（Runtime Library Exception 付き）",
            usage: "MLX Swift が使うライブラリ"),
    ]
}

/// The "Built with PLaMo" notice required by the PLaMo Community License (Article 4).
struct BuiltWithPLaMoBadge: View {
    var body: some View {
        Text("Built with PLaMo")
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.brand.opacity(0.16), in: Capsule())
    }
}

/// Settings > 情報: version, "Built with PLaMo", the model license and open-source licenses.
struct AboutSettings: View {
    @Environment(AppModel.self) private var model
    @State private var shownLicense: LicenseDocument?
    @State private var showTerms = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short)（\(build)）"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Mimiuchi").font(.system(size: 20, weight: .bold))
                        Text("バージョン \(version) · 作者 uni4029").font(.callout).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Link("GitHub", destination: AppLinks.repository)
                            Link("お問い合わせ（Issues）", destination: AppLinks.issues)
                        }
                        .font(.callout)
                    }
                    Spacer()
                    BuiltWithPLaMoBadge()
                }
            }
            Section("翻訳モデル") {
                Text("翻訳には Preferred Networks の PLaMo 3 Translate を使っています。" + AboutText.modelLicense)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("ライセンスを読む") { shownLicense = .plamoJapanese }
                    Button("English") { shownLicense = .plamoEnglish }
                    Spacer()
                    Link("商用利用の登録（PFN）", destination: PlamoModelCatalog.commercialRegistrationURL)
                }
                Text(AboutText.unofficial)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("利用規約") {
                LabeledContent("同意") {
                    if model.settings.hasAcceptedCurrentTerms, let date = model.settings.termsAcceptedAt {
                        Text("\(date.formatted(date: .long, time: .shortened)) に同意")
                    } else {
                        Text("未同意")
                    }
                }
                Button("利用規約を読む") { showTerms = true }
            }
            Section("オープンソースライセンス") {
                ForEach(LicenseDocument.openSource) { document in
                    LabeledContent {
                        Button("表示") { shownLicense = document }
                    } label: {
                        Text(document.name)
                        Text("\(document.license) · \(document.usage)")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $shownLicense) { LicenseTextView(document: $0) }
        .sheet(isPresented: $showTerms) { TermsOfUseSheet() }
    }
}

/// Full text of a bundled license.
struct LicenseTextView: View {
    let document: LicenseDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(document.name).font(.headline)
            ScrollView {
                Text(document.text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color.paneBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
            HStack {
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 520)
    }
}

/// Standard About panel ("Mimiuchi について") with the PLaMo notice in its credits.
enum AboutPanel {
    static func show() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 4
        let result = NSMutableAttributedString()
        func append(_ text: String, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, link: URL? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: weight),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
            if let link { attributes[.link] = link }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        append("Built with PLaMo\n", weight: .semibold)
        append("翻訳モデル: PLaMo 3 Translate © Preferred Networks, Inc.\n")
        append("PLaMo Community License", link: PlamoModelCatalog.licenseURL)
        append("\n" + AboutText.unofficial + "\n", color: .secondaryLabelColor)
        append("作者: uni4029 · ", color: .secondaryLabelColor)
        append("GitHub", link: AppLinks.repository)
        return result
    }
}
