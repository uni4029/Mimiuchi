import AppKit
import CryptoKit
import SwiftUI

/// The bundled Terms of Use (`TermsOfUse.md` at the repository root).
///
/// Acceptance is tied to the SHA-256 of the displayed text, so any change to the terms asks every
/// user to agree again. If the file is missing, nobody can agree and the app stays locked.
struct TermsOfUse: Sendable {
    enum Block: Hashable, Sendable {
        case title(String)
        case heading(String)
        case paragraph(String)
        /// Marker ("1.") and text.
        case numbered(String, String)
        case bullet(String)
    }

    let blocks: [Block]
    /// SHA-256 (hex) of the document without its leading comment.
    let hash: String

    static let current: TermsOfUse? = {
        guard let url = Bundle.main.url(forResource: "TermsOfUse", withExtension: "md"),
            let markdown = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return TermsOfUse(markdown: markdown)
    }()

    init?(markdown: String) {
        let text = Self.removingComments(markdown).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()

        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("## ") {
                flush()
                blocks.append(.heading(String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                flush()
                blocks.append(.title(String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") {
                flush()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else if let marker = Self.numberMarker(of: line) {
                flush()
                blocks.append(.numbered(marker, String(line.dropFirst(marker.count + 1))))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        self.blocks = blocks
    }

    /// "1. text" → "1."
    private static func numberMarker(of line: String) -> String? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return digits + "."
    }

    private static func removingComments(_ text: String) -> String {
        var result = text
        while let start = result.range(of: "<!--") {
            guard let end = result.range(of: "-->", range: start.upperBound ..< result.endIndex) else {
                result.removeSubrange(start.lowerBound...)
                break
            }
            result.removeSubrange(start.lowerBound ..< end.upperBound)
        }
        return result
    }
}

/// Renders the Terms of Use (title, headings, numbered items, bullets, inline links).
struct TermsDocumentView: View {
    let terms: TermsOfUse

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(terms.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .title(let text):
                    Text(inline(text)).font(.system(size: 22, weight: .bold))
                case .heading(let text):
                    Text(inline(text)).font(.system(size: 14, weight: .semibold)).padding(.top, 10)
                case .paragraph(let text):
                    Text(inline(text))
                case .numbered(let marker, let text):
                    item(marker, text)
                case .bullet(let text):
                    item("・", text)
                }
            }
        }
        .font(.system(size: 13))
        .lineSpacing(2)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func item(_ marker: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker).monospacedDigit().frame(minWidth: 18, alignment: .trailing)
            Text(inline(text)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Shown in the main window on first launch (and after the terms change). Nothing is
/// downloaded, loaded or translated until the user agrees.
struct TermsGateView: View {
    @Environment(AppModel.self) private var model
    /// Snapshot/README only: show the first-launch title even if older terms were accepted.
    var forceFirstLaunchTitle = false
    @State private var agreed = false
    @State private var shownLicense: LicenseDocument?

    private let terms = TermsOfUse.current

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(forceFirstLaunchTitle || model.settings.acceptedTermsHash.isEmpty ? "Mimiuchi へようこそ" : "利用規約が更新されました")
                        .font(.system(size: 20, weight: .bold))
                    Text("ご利用の前に、利用規約と翻訳モデルのライセンス（PLaMo Community License）をお読みください。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                BuiltWithPLaMoBadge()
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 16)

            Divider()
            ScrollView {
                Group {
                    if let terms {
                        TermsDocumentView(terms: terms)
                    } else {
                        Text("利用規約を読み込めませんでした。Mimiuchi を入れ直してください。").foregroundStyle(.red)
                    }
                }
                .padding(28)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("翻訳モデルのライセンス:").foregroundStyle(.secondary)
                    Button("PLaMo Community License を読む") { shownLicense = .plamoJapanese }
                    Button("English") { shownLicense = .plamoEnglish }
                }
                Toggle("Mimiuchi 利用規約と PLaMo Community License を読み、内容に同意します", isOn: $agreed)
                    .toggleStyle(.checkbox)
                    .disabled(terms == nil)
                HStack {
                    Spacer()
                    Button("同意しない（終了）") { NSApp.terminate(nil) }
                    Button("同意して始める") { model.acceptTerms() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brand)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!agreed || terms == nil)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $shownLicense) { LicenseTextView(document: $0) }
    }
}

/// Read-only Terms of Use (Settings > 情報).
struct TermsOfUseSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                if let terms = TermsOfUse.current {
                    TermsDocumentView(terms: terms).padding(16)
                } else {
                    Text("利用規約を読み込めませんでした。").foregroundStyle(.red).padding(16)
                }
            }
            .background(Color.paneBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
            HStack {
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 660, height: 580)
    }
}
