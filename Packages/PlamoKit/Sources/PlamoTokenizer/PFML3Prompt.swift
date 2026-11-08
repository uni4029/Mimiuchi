// Prompt format of `chat_template.jinja` in PFN's PLaMo 3 Translate repositories
// (Copyright © Preferred Networks, Inc., PLaMo Community License); see Packages/PlamoKit/NOTICE.md.

import Foundation

/// A previously translated pair used as translation history.
public struct TranslationTurn: Sendable, Equatable, Codable {
    public var source: String
    public var translation: String
    public init(source: String, translation: String) {
        self.source = source
        self.translation = translation
    }
}

/// A glossary entry (`source` term is translated as `target`).
public struct GlossaryEntry: Sendable, Equatable, Codable, Hashable {
    public var source: String
    public var target: String
    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }
}

/// PLaMo's PFML3 prompt format.
public enum PFML3 {
    /// Builds the prompt exactly as `chat_template.jinja` does after `bos_token`
    /// (BOS itself is not included; prepend token id 1).
    public static func translationPrompt(
        source: String, targetLang: String, sourceLang: String? = nil, context: String? = nil,
        glossary: [GlossaryEntry] = [], form: String? = nil, history: [TranslationTurn] = []
    ) -> String {
        let target = normalizeLang(targetLang)
        let sourceLang = sourceLang.map(normalizeLang)
        let inputTag: String = {
            var s = "<|plamo:tag|>input"
            if let sourceLang { s += "<|plamo:key|>lang<|plamo:val|>" + sourceLang }
            return s
        }()

        var prompt = "<|plamo:tag|>dataset<|plamo:msg|>translation"
        if let context, !context.isEmpty {
            prompt += "<|plamo:tag|>context<|plamo:msg|>" + context
        }
        for turn in history {
            prompt += inputTag + "<|plamo:msg|>" + turn.source
            prompt += "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>" + target
            prompt += "<|plamo:msg|>" + turn.translation
        }
        if !glossary.isEmpty {
            prompt += "<|plamo:tag|>glossary"
            for entry in glossary {
                prompt += "<|plamo:index|>" + entry.source + "<|plamo:item|>" + entry.target
            }
        }
        prompt += inputTag + "<|plamo:msg|>" + source
        prompt += "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>" + target
        if let form {
            prompt += "<|plamo:key|>form<|plamo:val|>" + form
        }
        prompt += "<|plamo:msg|>"
        return prompt
    }

    /// The chat template accepts `ja(easy)` as an alias of `ja-easy`.
    static func normalizeLang(_ code: String) -> String {
        code == "ja(easy)" ? "ja-easy" : code
    }

    /// Neutralizes reserved PFML control sequences in user-provided text.
    ///
    /// The official chat template rejects text containing `<|plamo:`; instead of failing we
    /// insert a zero-width space so the sequence can no longer form a control token.
    public static func sanitize(_ text: String) -> String {
        guard text.contains("plamo") else { return text }
        return
            text
            .replacingOccurrences(of: "<|plamo:", with: "<|\u{200B}plamo:")
            .replacingOccurrences(of: ":plamo|>", with: ":plamo\u{200B}|>")
    }
}
