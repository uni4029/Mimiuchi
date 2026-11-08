import Foundation

/// A downloadable PLaMo 3 Translate model (official MLX 4-bit builds by Preferred Networks).
public struct PlamoModelDescriptor: Identifiable, Hashable, Sendable, Codable {
    /// Hugging Face repository id, e.g. `pfnet/plamo-3-translate-0.8b-MLX-4bit`.
    public let id: String
    /// Parameter size label, e.g. `0.8B`.
    public let sizeLabel: String
    public let parameterBillions: Double
    /// Approximate total download size (weights + tokenizer).
    public let downloadBytes: Int64
    /// Unified memory recommended to run comfortably alongside other apps.
    public let recommendedMemoryGB: Int
    /// Japanese one-line description for the model store.
    public let summary: String

    public var displayName: String { "PLaMo 3 Translate \(sizeLabel)" }
    public var formatLabel: String { "MLX 4bit" }
    public var repositoryURL: URL { URL(string: "https://huggingface.co/\(id)")! }
    public var directoryName: String { id.replacingOccurrences(of: "/", with: "--") }
}

public enum PlamoModelCatalog {
    public static let all: [PlamoModelDescriptor] = [
        PlamoModelDescriptor(
            id: "pfnet/plamo-3-translate-0.8b-MLX-4bit", sizeLabel: "0.8B", parameterBillions: 0.8,
            downloadBytes: 981_000_000, recommendedMemoryGB: 8,
            summary: "最小・最速。オーバーレイ翻訳など軽快さを重視する場合に。"),
        PlamoModelDescriptor(
            id: "pfnet/plamo-3-translate-2b-MLX-4bit", sizeLabel: "2B", parameterBillions: 2,
            downloadBytes: 2_416_000_000, recommendedMemoryGB: 8,
            summary: "速度と品質のバランスが良い標準モデル。"),
        PlamoModelDescriptor(
            id: "pfnet/plamo-3-translate-8b-MLX-4bit", sizeLabel: "8B", parameterBillions: 8,
            downloadBytes: 6_071_000_000, recommendedMemoryGB: 16,
            summary: "高品質。16GB以上のメモリを推奨。"),
        PlamoModelDescriptor(
            id: "pfnet/plamo-3-translate-31b-MLX-4bit", sizeLabel: "31B", parameterBillions: 31,
            downloadBytes: 18_662_000_000, recommendedMemoryGB: 36,
            summary: "最高品質。36GB以上のメモリを推奨。"),
    ]

    public static func descriptor(id: String) -> PlamoModelDescriptor? {
        all.first { $0.id == id }
    }

    /// Smallest model; the default choice.
    public static var defaultModel: PlamoModelDescriptor { all[0] }

    public static let licenseURL = URL(string: "https://plamo.preferredai.jp/info/plamo-community-license-ja")!
    /// PFN's registration form for free commercial use (PLaMo Community License, Article 3).
    public static let commercialRegistrationURL = URL(string: "https://forms.gle/mTL8tBLrMYXKNZD56")!
}
