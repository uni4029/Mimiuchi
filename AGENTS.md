# Repository Guidelines

## Project Structure & Module Organization

Mimiuchi is an on-device translation app for Apple silicon and macOS 26+.

- `Mimiuchi/`: SwiftUI/AppKit app; `App/` handles startup and shared state, `Services/` integrates translation and shortcuts, `Views/` contains UI, `Models/` stores settings/history, and `Resources/` holds assets.
- `Packages/MimiuchiCore/`: UI-independent shortcut detection and language routing.
- `Packages/PlamoKit/`: tokenizer, MLX inference engine, model catalog/downloader, and `plamo-cli`.
- Package tests live in `Packages/*/Tests/`; tokenizer fixtures are in `PlamoTokenizerTests/Resources/`.
- `Scripts/` contains build/test/signing helpers; `Tools/` contains reference-data generators and the keyboard E2E harness.

## Build, Test, and Development Commands

Use Xcode 26+ with the Metal Toolchain, Swift 6.2 package support, and XcodeGen.

- `xcodegen generate`: regenerate `Mimiuchi.xcodeproj` from `project.yml`; edit project configuration in the YAML first.
- `Scripts/build.sh --no-install`: build and sign Release without installing. Signing may create a local certificate on first use.
- `Scripts/build.sh`: build and install into `~/Applications`, restarting an existing instance.
- `open Mimiuchi.xcodeproj`: open Xcode; run the `Mimiuchi` scheme for Debug development.
- `Scripts/test.sh`: run MimiuchiCore and tokenizer tests.
- `swift test --package-path Packages/MimiuchiCore`: run core tests independently.
- `Tools/e2e-cmdcc.sh`: verify double-copy translation with an unlocked screen, installed model, and granted Input Monitoring/Accessibility permissions.

## Coding Style & Naming Conventions

Follow existing Swift style: four-space indentation, `UpperCamelCase` types, `lowerCamelCase` members, and descriptive filenames such as `TranslationSession.swift`. Preserve actor isolation and Swift concurrency checks; keep reusable logic in packages. Match the existing Japanese UI wording. No formatter or linter configuration is checked in.

## Testing Guidelines

Tests use XCTest, `*Tests.swift` files, and descriptive `test...` methods. Add regression tests for changed behavior; no coverage percentage is configured. Tokenizer tests require `tokenizer.jsonl`: install the default 0.8B model or set `PLAMO_MODEL_DIR`. Missing tokenizer data skips tests, so check for skips. For inference changes, compare `plamo-cli golden` output using `Tools/reference/README.md`.

## Commit & Pull Request Guidelines

History contains one descriptive `Mimiuchi:` commit, so no recurring convention is established. Use concise, scoped subjects. PRs should explain behavior changes, link relevant issues, report validation and skipped tests, and include screenshots for UI changes.

## Configuration & Repository Hygiene

Keep model weights, virtual environments, build output, and signing credentials out of commits. Preserve bundled notices. Changes to `TermsOfUse.md` body trigger renewed user consent.
