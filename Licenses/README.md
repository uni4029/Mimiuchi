# ライセンス

Mimiuchi に含まれる、または Mimiuchi が使うソフトウェアのライセンス文です。アプリにも同梱しています（設定 > 情報）。

**Built with PLaMo** — Mimiuchi は Preferred Networks の PLaMo 3 Translate を使っています。Mimiuchi は個人が開発したアプリで、Preferred Networks の公式製品ではありません。

| 対象 | ライセンス | ファイル |
| --- | --- | --- |
| Mimiuchi 本体（PFN のコードから移植した部分を除く。例外の一覧はリポジトリの `NOTICE`） | Apache License 2.0 | `Mimiuchi.txt`（リポジトリの `LICENSE` と `NOTICE`） |
| 翻訳モデル PLaMo 3 Translate（アプリには含まれず、モデルストアで Hugging Face から直接ダウンロード） | PLaMo Community License | `PLaMo-Community-License-ja.txt`, `PLaMo-Community-License-en.txt` |
| PlamoKit のうち PFN のトークナイザ・プロンプト形式・モデルコードを移植した部分（`Packages/PlamoKit/NOTICE.md`） | PLaMo Community License | 同上 |
| MLX LM（PLaMo 3 のモデルコードの元） | MIT License | `mlx-lm.txt` |
| MLX Swift | MIT License | `mlx-swift.txt` |
| MLX | MIT License | `mlx.txt` |
| MLX C | MIT License | `mlx-c.txt` |
| PocketFFT（MLX に同梱） | BSD 3-Clause License | `PocketFFT.txt` |
| metal-cpp（MLX に同梱） | Apache License 2.0 | `metal-cpp.txt` |
| {fmt}（MLX に同梱） | MIT License | `fmt.txt` |
| JSON for Modern C++（MLX に同梱） | MIT License | `nlohmann-json.txt` |
| Swift Numerics | Apache License 2.0（Runtime Library Exception 付き） | `swift-numerics.txt` |

依存ライブラリを追加・更新したときは、このフォルダと `Mimiuchi/Views/AboutView.swift` の `LicenseDocument.openSource` を更新してください。
