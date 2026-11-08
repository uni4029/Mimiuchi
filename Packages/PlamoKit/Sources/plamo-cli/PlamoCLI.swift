import Foundation
import PlamoKit

// Minimal command line front-end used to test the engine and the model store.
//
//   plamo-cli list
//   plamo-cli download <0.8b|2b|8b|31b>
//   plamo-cli delete <size>
//   plamo-cli translate <size|dir> <target> [--from xx] [--form plain|polite] [--context ...] text...
//   plamo-cli golden <size|dir> <golden.json> [--prefill N]
//   plamo-cli bench <size|dir>

@main
struct PlamoCLI {
    nonisolated(unsafe) static var args = Array(CommandLine.arguments.dropFirst())
    static let store = ModelStore()

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
        exit(1)
    }

    static func descriptor(_ size: String) -> PlamoModelDescriptor? {
        PlamoModelCatalog.all.first { $0.sizeLabel.lowercased() == size.lowercased() }
    }

    static func modelDirectory(_ spec: String) -> URL {
        if let d = descriptor(spec) {
            guard store.isInstalled(d) else { fail("\(d.displayName) is not installed (run: download \(spec))") }
            return store.directory(for: d)
        }
        return URL(fileURLWithPath: spec)
    }

    static func option(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        let value = args[i + 1]
        args.removeSubrange(i ... i + 1)
        return value
    }

    static func load(_ spec: String) async throws -> PlamoTranslator {
        let t0 = Date()
        let translator = try PlamoTranslator(modelDirectory: modelDirectory(spec))
        print(String(format: "[loaded in %.2fs]", Date().timeIntervalSince(t0)))
        return translator
    }

    static func main() async throws {
        let formatter = ByteCountFormatter()
        guard let command = args.first else {
            fail("usage: plamo-cli list|download|delete|translate|golden|bench ...")
        }
        args.removeFirst()

        switch command {
        case "list":
            print("root: \(store.rootDirectory.path)  free: \(formatter.string(fromByteCount: store.availableDiskSpace()))")
            for m in PlamoModelCatalog.all {
                let installed = store.isInstalled(m)
                print("\(m.sizeLabel.padding(toLength: 5, withPad: " ", startingAt: 0)) \(m.id)  \(installed ? "installed (\(formatter.string(fromByteCount: store.diskUsage(for: m))))" : "-")")
            }

        case "download":
            guard let size = args.first, let d = descriptor(size) else { fail("download <size>") }
            let t0 = Date()
            nonisolated(unsafe) var lastPrint = Date.distantPast
            try await store.download(d) { p in
                if Date().timeIntervalSince(lastPrint) > 1 || p.phase == .finished || p.phase == .verifying {
                    lastPrint = Date()
                    let f = ByteCountFormatter()
                    print(String(format: "%@ %5.1f%% %@/%@ %@/s %@", p.phase.rawValue, p.fraction * 100,
                        f.string(fromByteCount: p.completedBytes), f.string(fromByteCount: p.totalBytes),
                        f.string(fromByteCount: Int64(p.bytesPerSecond)), p.currentFile))
                }
            }
            print(String(format: "done in %.1fs -> %@", Date().timeIntervalSince(t0), store.directory(for: d).path))

        case "delete":
            guard let size = args.first, let d = descriptor(size) else { fail("delete <size>") }
            try store.delete(d)
            print("deleted \(d.id)")

        case "translate":
            let from = option("--from")
            let form = option("--form")
            let context = option("--context")
            guard args.count >= 3 else { fail("translate <size|dir> <target> text...") }
            let translator = try await load(args[0])
            let request = TranslationRequest(
                text: args[2...].joined(separator: " "), sourceLanguage: from, targetLanguage: args[1],
                form: form, context: context)
            for try await event in translator.translate(request) {
                switch event {
                case .text(let t):
                    print(t, terminator: "")
                    fflush(stdout)
                case .finished(let s):
                    print(String(format: "\n[prompt %d tok, prefill %.3fs | %d tok, %.1f tok/s, %@]",
                        s.promptTokens, s.prefillSeconds, s.generatedTokens, s.tokensPerSecond, s.stopReason.rawValue))
                case .prefilled:
                    break
                }
            }

        case "golden":
            let prefill = Int(option("--prefill") ?? "2048") ?? 2048
            guard args.count >= 2 else { fail("golden <size|dir> <golden.json>") }
            let translator = try await load(args[0])
            await translator.setPrefillStepSize(prefill)
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [String: Any]
            let gens = json["generations"] as! [[String: Any]]
            var passed = 0
            for g in gens {
                let c = g["case"] as! [String: Any]
                let messages = c["messages"] as! [[String: String]]
                let glossary = (c["glossary"] as? [[String: String]] ?? []).map { GlossaryEntry(source: $0["source"]!, target: $0["target"]!) }
                let request = TranslationRequest(
                    text: messages.last!["content"]!, sourceLanguage: c["source_lang"] as? String,
                    targetLanguage: c["target_lang"] as! String, form: c["form"] as? String,
                    context: c["context"] as? String, glossary: glossary, maxTokens: 256)
                let expectedIds = (g["tokens"] as! [NSNumber]).map { $0.int32Value }
                let expected = g["text"] as! String
                let (text, stats) = try await translator.translateText(request)
                let ok = text == expected && stats.generatedTokens == expectedIds.count
                if ok { passed += 1 }
                print("\(ok ? "OK  " : "DIFF") \(text.debugDescription)\(ok ? "" : "\n     expected \(expected.debugDescription)")  [\(stats.generatedTokens) tok, \(String(format: "%.1f", stats.tokensPerSecond)) tok/s]")
            }
            print("\(passed)/\(gens.count) match the mlx-lm reference")
            if passed != gens.count { exit(2) }

        case "profile":
            guard let spec = args.first else { fail("profile <size|dir>") }
            let translator = try await load(spec)
            for _ in 0 ..< 3 {
                let r = await translator.profileDecode(steps: 64)
                print(String(format: "decode step: build %.2fms, total %.2fms (%.1f tok/s sync)", r.buildMs, r.totalMs, 1000 / r.totalMs))
            }

        case "bench":
            guard let spec = args.first else { fail("bench <size|dir>") }
            let translator = try await load(spec)
            let text = String(repeating: "機械翻訳の品質は近年大きく向上しましたが、短い文や専門用語を含む文章では依然として誤訳が発生することがあります。", count: 6)
            for target in ["en", "en"] {
                let (out, s) = try await translator.translateText(TranslationRequest(text: text, targetLanguage: target))
                print(String(format: "prompt %d tok prefill %.3fs (%.0f tok/s) | gen %d tok %.1f tok/s | %@…",
                    s.promptTokens, s.prefillSeconds, Double(s.promptTokens) / max(s.prefillSeconds, 1e-6),
                    s.generatedTokens, s.tokensPerSecond, String(out.prefix(60))))
            }

        default:
            fail("unknown command \(command)")
        }
    }
}
