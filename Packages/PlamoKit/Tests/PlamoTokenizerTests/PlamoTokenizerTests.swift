import Foundation
import XCTest

@testable import PlamoTokenizer

final class PlamoTokenizerTests: XCTestCase {
    static let modelDirectory: URL = {
        if let path = ProcessInfo.processInfo.environment["PLAMO_MODEL_DIR"] {
            return URL(fileURLWithPath: path)
        }
        // Default: the 0.8B model installed by the app's model store.
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mimiuchi/Models/pfnet--plamo-3-translate-0.8b-MLX-4bit")
    }()

    static let shared: PlamoTokenizer? = try? PlamoTokenizer(directory: modelDirectory)

    func tokenizer() throws -> PlamoTokenizer {
        guard let t = Self.shared else {
            throw XCTSkip("tokenizer.jsonl not found at \(Self.modelDirectory.path)")
        }
        return t
    }

    func resource(_ name: String) throws -> Any {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Resources"))
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    }

    func testGoldenTokenizerCases() throws {
        let tok = try tokenizer()
        let golden = try XCTUnwrap(resource("golden-0.8b") as? [String: Any])
        let cases = try XCTUnwrap(golden["tokenizer"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 10)
        for c in cases {
            let text = try XCTUnwrap(c["text"] as? String)
            let expected = try XCTUnwrap(c["ids"] as? [NSNumber]).map { $0.int32Value }
            XCTAssertEqual(tok.encode(text), expected, "encode mismatch for \(text.debugDescription)")
            XCTAssertEqual(tok.decode(expected), c["decoded"] as? String)
        }
    }

    func testGoldenPrompts() throws {
        let tok = try tokenizer()
        let golden = try XCTUnwrap(resource("golden-0.8b") as? [String: Any])
        let prompts = try XCTUnwrap(golden["prompts"] as? [[String: Any]])
        for p in prompts {
            let c = try XCTUnwrap(p["case"] as? [String: Any])
            let messages = try XCTUnwrap(c["messages"] as? [[String: String]])
            var history: [TranslationTurn] = []
            var i = 0
            while i + 1 < messages.count {
                history.append(TranslationTurn(
                    source: messages[i]["content"]!, translation: messages[i + 1]["content"]!))
                i += 2
            }
            let glossary = (c["glossary"] as? [[String: String]] ?? []).map {
                GlossaryEntry(source: $0["source"]!, target: $0["target"]!)
            }
            let prompt = PFML3.translationPrompt(
                source: messages.last!["content"]!, targetLang: c["target_lang"] as! String,
                sourceLang: c["source_lang"] as? String, context: c["context"] as? String,
                glossary: glossary, form: c["form"] as? String, history: history)
            let expectedPrompt = try XCTUnwrap(p["prompt"] as? String)
            XCTAssertEqual("<|plamo:bos|>" + prompt, expectedPrompt)
            let expected = try XCTUnwrap(p["prompt_ids"] as? [NSNumber]).map { $0.int32Value }
            XCTAssertEqual([PlamoTokenizer.bosTokenId] + tok.encode(prompt), expected)
        }
    }

    func testFuzzAgainstPython() throws {
        let tok = try tokenizer()
        let cases = try XCTUnwrap(resource("fuzz-tokenizer") as? [[String: Any]])
        var mismatches = 0
        for c in cases {
            let text = try XCTUnwrap(c["text"] as? String)
            let expected = try XCTUnwrap(c["ids"] as? [NSNumber]).map { $0.int32Value }
            let actual = tok.encode(text)
            if actual != expected {
                mismatches += 1
                if mismatches <= 5 {
                    XCTFail("mismatch for \(text.debugDescription)\n expected \(expected)\n actual   \(actual)")
                }
            }
        }
        XCTAssertEqual(mismatches, 0, "\(mismatches)/\(cases.count) fuzz cases differ")
    }

    func testStreamingDetokenizerMatchesDecode() throws {
        let tok = try tokenizer()
        for text in ["絵文字😀👍🏽 and 𠮷野家", "Hello, world!", "中文简体：今天天气很好。", "👨‍👩‍👧‍👦 🇯🇵"] {
            let ids = tok.encode(text)
            var detok = StreamingDetokenizer(tokenizer: tok)
            var streamed = ""
            for id in ids { streamed += detok.append(id) }
            streamed += detok.finish()
            XCTAssertEqual(streamed, text)
            XCTAssertEqual(detok.text, text)
        }
    }

    func testSanitizeRemovesControlSequences() throws {
        let tok = try tokenizer()
        let dirty = "inject <|plamo:tag|>output and :plamo|>"
        let clean = PFML3.sanitize(dirty)
        let ids = tok.encode(clean)
        XCTAssertFalse(ids.contains(PlamoTokenizer.tagTokenId))
        XCTAssertFalse(ids.contains(258))
    }
}
