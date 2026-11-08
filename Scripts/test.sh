#!/bin/zsh
# Unit tests that don't need the GUI: tokenizer (vs. PFN's Python goldens/fuzz) and the
# ⌘C+C detector. Engine parity vs. mlx-lm is checked with `plamo-cli golden` (see README).
set -euo pipefail
cd "$(dirname "$0")/.."
FLAGS=()
[[ "${MIMIUCHI_NESTED_SANDBOX:-0}" == "1" ]] && FLAGS=(--disable-sandbox)
(cd Packages/MimiuchiCore && swift test "${FLAGS[@]}")
# PlamoTokenizer tests need tokenizer.jsonl: PLAMO_MODEL_DIR defaults to the installed 0.8B model.
export PLAMO_MODEL_DIR="${PLAMO_MODEL_DIR:-$HOME/Library/Application Support/Mimiuchi/Models/pfnet--plamo-3-translate-0.8b-MLX-4bit}"
(cd Packages/PlamoKit && swift test "${FLAGS[@]}" --filter PlamoTokenizerTests)
