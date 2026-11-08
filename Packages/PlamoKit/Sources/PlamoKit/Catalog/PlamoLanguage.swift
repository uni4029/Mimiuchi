import Foundation

/// A language supported by PLaMo 3 Translate (53 languages + Easy Japanese).
public struct PlamoLanguage: Identifiable, Hashable, Sendable, Codable {
    /// PFML3 language code (lowercase, e.g. `ja`, `zh-hans`, `ja-easy`).
    public let code: String
    public let japaneseName: String
    public let englishName: String
    /// Only usable as a translation target.
    public let targetOnly: Bool

    public var id: String { code }

    public init(code: String, japaneseName: String, englishName: String, targetOnly: Bool = false) {
        self.code = code
        self.japaneseName = japaneseName
        self.englishName = englishName
        self.targetOnly = targetOnly
    }

    public static let japanese = PlamoLanguage(code: "ja", japaneseName: "日本語", englishName: "Japanese")
    public static let english = PlamoLanguage(code: "en", japaneseName: "英語", englishName: "English")

    /// Ordered for menus: frequently used languages first, the rest in Japanese reading order.
    public static let all: [PlamoLanguage] = [
        .japanese,
        .english,
        PlamoLanguage(code: "ja-easy", japaneseName: "やさしい日本語", englishName: "Easy Japanese", targetOnly: true),
        PlamoLanguage(code: "zh-hans", japaneseName: "中国語（簡体字）", englishName: "Chinese (Simplified)"),
        PlamoLanguage(code: "zh-hant", japaneseName: "中国語（繁体字）", englishName: "Chinese (Traditional)"),
        PlamoLanguage(code: "ko", japaneseName: "韓国語", englishName: "Korean"),
        PlamoLanguage(code: "fr", japaneseName: "フランス語", englishName: "French"),
        PlamoLanguage(code: "de", japaneseName: "ドイツ語", englishName: "German"),
        PlamoLanguage(code: "es", japaneseName: "スペイン語", englishName: "Spanish"),
        PlamoLanguage(code: "it", japaneseName: "イタリア語", englishName: "Italian"),
        PlamoLanguage(code: "ru", japaneseName: "ロシア語", englishName: "Russian"),
        PlamoLanguage(code: "vi", japaneseName: "ベトナム語", englishName: "Vietnamese"),
        PlamoLanguage(code: "th", japaneseName: "タイ語", englishName: "Thai"),
        PlamoLanguage(code: "id", japaneseName: "インドネシア語", englishName: "Indonesian"),
        PlamoLanguage(code: "ar", japaneseName: "アラビア語", englishName: "Arabic"),
        PlamoLanguage(code: "nl", japaneseName: "オランダ語", englishName: "Dutch"),
        PlamoLanguage(code: "az", japaneseName: "アゼルバイジャン語", englishName: "Azerbaijani"),
        PlamoLanguage(code: "hy", japaneseName: "アルメニア語", englishName: "Armenian"),
        PlamoLanguage(code: "uz", japaneseName: "ウズベク語", englishName: "Uzbek"),
        PlamoLanguage(code: "ur", japaneseName: "ウルドゥー語", englishName: "Urdu"),
        PlamoLanguage(code: "et", japaneseName: "エストニア語", englishName: "Estonian"),
        PlamoLanguage(code: "kk", japaneseName: "カザフ語", englishName: "Kazakh"),
        PlamoLanguage(code: "ca", japaneseName: "カタルーニャ語", englishName: "Catalan"),
        PlamoLanguage(code: "gu", japaneseName: "グジャラート語", englishName: "Gujarati"),
        PlamoLanguage(code: "km", japaneseName: "クメール語", englishName: "Khmer"),
        PlamoLanguage(code: "hr", japaneseName: "クロアチア語", englishName: "Croatian"),
        PlamoLanguage(code: "ka", japaneseName: "ジョージア語", englishName: "Georgian"),
        PlamoLanguage(code: "jv", japaneseName: "ジャワ語", englishName: "Javanese"),
        PlamoLanguage(code: "si", japaneseName: "シンハラ語", englishName: "Sinhala"),
        PlamoLanguage(code: "sw", japaneseName: "スワヒリ語", englishName: "Swahili"),
        PlamoLanguage(code: "sk", japaneseName: "スロバキア語", englishName: "Slovak"),
        PlamoLanguage(code: "sl", japaneseName: "スロベニア語", englishName: "Slovenian"),
        PlamoLanguage(code: "sr", japaneseName: "セルビア語", englishName: "Serbian"),
        PlamoLanguage(code: "ceb", japaneseName: "セブアノ語", englishName: "Cebuano"),
        PlamoLanguage(code: "tl", japaneseName: "タガログ語", englishName: "Tagalog"),
        PlamoLanguage(code: "ta", japaneseName: "タミル語", englishName: "Tamil"),
        PlamoLanguage(code: "te", japaneseName: "テルグ語", englishName: "Telugu"),
        PlamoLanguage(code: "ne", japaneseName: "ネパール語", englishName: "Nepali"),
        PlamoLanguage(code: "eu", japaneseName: "バスク語", englishName: "Basque"),
        PlamoLanguage(code: "hu", japaneseName: "ハンガリー語", englishName: "Hungarian"),
        PlamoLanguage(code: "pa", japaneseName: "パンジャブ語", englishName: "Punjabi"),
        PlamoLanguage(code: "hi", japaneseName: "ヒンディー語", englishName: "Hindi"),
        PlamoLanguage(code: "my", japaneseName: "ビルマ語", englishName: "Burmese"),
        PlamoLanguage(code: "bg", japaneseName: "ブルガリア語", englishName: "Bulgarian"),
        PlamoLanguage(code: "he", japaneseName: "ヘブライ語", englishName: "Hebrew"),
        PlamoLanguage(code: "fa", japaneseName: "ペルシア語", englishName: "Persian"),
        PlamoLanguage(code: "bn", japaneseName: "ベンガル語", englishName: "Bengali"),
        PlamoLanguage(code: "be", japaneseName: "ベラルーシ語", englishName: "Belarusian"),
        PlamoLanguage(code: "pl", japaneseName: "ポーランド語", englishName: "Polish"),
        PlamoLanguage(code: "ml", japaneseName: "マラヤーラム語", englishName: "Malayalam"),
        PlamoLanguage(code: "mr", japaneseName: "マラーティー語", englishName: "Marathi"),
        PlamoLanguage(code: "ms", japaneseName: "マレー語", englishName: "Malay"),
        PlamoLanguage(code: "lv", japaneseName: "ラトビア語", englishName: "Latvian"),
        PlamoLanguage(code: "lt", japaneseName: "リトアニア語", englishName: "Lithuanian"),
    ]

    public static let sourceLanguages: [PlamoLanguage] = all.filter { !$0.targetOnly }

    public static func language(code: String) -> PlamoLanguage? {
        all.first { $0.code == code }
    }

    /// Maps a BCP-47 tag (e.g. from NaturalLanguage: `zh-Hans`, `pt-BR`) to a supported language.
    public static func matching(bcp47 tag: String) -> PlamoLanguage? {
        let lower = tag.lowercased()
        if let exact = language(code: lower) { return exact }
        if lower.hasPrefix("zh") {
            return language(code: lower.contains("hant") || lower.contains("tw") || lower.contains("hk") ? "zh-hant" : "zh-hans")
        }
        let base = String(lower.split(separator: "-").first ?? "")
        switch base {
        case "iw": return language(code: "he")
        case "fil": return language(code: "tl")
        case "nb", "no": return nil
        default: return language(code: base)
        }
    }

    /// Only Japanese supports the plain/polite style option.
    public var supportsFormality: Bool { code == "ja" }
}
