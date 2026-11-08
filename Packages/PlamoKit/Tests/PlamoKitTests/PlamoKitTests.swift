import XCTest

@testable import PlamoKit

final class PlamoKitTests: XCTestCase {
    func testCatalogHasFourSizesSmallestFirst() {
        XCTAssertEqual(PlamoModelCatalog.all.map(\.sizeLabel), ["0.8B", "2B", "8B", "31B"])
        XCTAssertEqual(PlamoModelCatalog.defaultModel.id, "pfnet/plamo-3-translate-0.8b-MLX-4bit")
    }

    func testLanguagesCoverPlamoCodes() {
        // 53 languages + Easy Japanese (target only).
        XCTAssertEqual(PlamoLanguage.all.count, 54)
        XCTAssertEqual(Set(PlamoLanguage.all.map(\.code)).count, 54)
        XCTAssertEqual(PlamoLanguage.matching(bcp47: "zh-Hant")?.code, "zh-hant")
        XCTAssertEqual(PlamoLanguage.matching(bcp47: "zh-Hans")?.code, "zh-hans")
        XCTAssertEqual(PlamoLanguage.matching(bcp47: "en-US")?.code, "en")
        XCTAssertNil(PlamoLanguage.matching(bcp47: "xx"))
    }

    func testDownloadFileFilter() {
        XCTAssertTrue(ModelStore.isNeeded("model-00001-of-00003.safetensors"))
        XCTAssertTrue(ModelStore.isNeeded("tokenizer.jsonl"))
        XCTAssertTrue(ModelStore.isNeeded("LICENSE/ja"))
        XCTAssertFalse(ModelStore.isNeeded("figures/benchmark_en.png"))
        XCTAssertFalse(ModelStore.isNeeded("modeling_plamo_mlx.py"))
    }

    func testWindowedMask() {
        let mask = Plamo3Attention.windowedCausalMask(n: 3, offset: 2, window: 2)
        XCTAssertEqual(mask.shape, [3, 5])
        let values = mask.asArray(Bool.self)
        // query positions 2,3,4 attend to keys (p-1, p)
        XCTAssertEqual(values, [false, true, true, false, false,
                                false, false, true, true, false,
                                false, false, false, true, true])
    }
}
