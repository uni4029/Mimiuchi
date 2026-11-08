# PlamoKit — third-party notices

PlamoKit contains Swift ports of files distributed with Preferred Networks' PLaMo 3 Translate
models (https://huggingface.co/pfnet, e.g. `pfnet/plamo-3-translate-0.8b-MLX-4bit`):

| PlamoKit | Ported from |
| --- | --- |
| `Sources/PlamoTokenizer/PlamoTokenizer.swift` | `tokenization_plamo.py` |
| `Sources/PlamoTokenizer/PFML3Prompt.swift` | `chat_template.jinja` (prompt format) |
| `Sources/PlamoKit/Model/Plamo3Model.swift`, `Plamo3Configuration.swift` | `modeling_plamo_mlx.py` |

These files are derived from PLaMo's model code and tokenizer (Copyright © Preferred Networks, Inc.) and
are subject to the **PLaMo Community License** (`Licenses/PLaMo-Community-License-ja.txt`,
`Licenses/PLaMo-Community-License-en.txt`, https://plamo.preferredai.jp/info/plamo-community-license-en).
Anyone who provides PlamoKit (or an app built with it) to third parties must, per Article 4:

1. provide a copy of the PLaMo Community License and require compliance with it,
2. state "Built with PLaMo" on a related website, user interface, blog post, product page or
   documentation, and
3. include "PLaMo" in the name of any AI model created with it.

Commercial use requires prior registration with PFN (revenue ≤ JPY 1 billion) or a separate
license (Article 3).

`modeling_plamo_mlx.py` is adapted from mlx-lm. Its header reads: "Portions Copyright © 2026
Apple Inc. (mlx-lm, MIT License; see LICENSE.mlx-lm). Modifications Copyright © 2026 Preferred
Networks, Inc." `KVCache.swift` and the generation loop in `PlamoTranslator.swift` also follow
mlx-lm. mlx-lm is Copyright © 2023 Apple Inc. and licensed under the MIT License
(`Licenses/mlx-lm.txt`).

The JSON files in `Tests/PlamoTokenizerTests/Resources/` (and `Tools/reference/`) were generated
with PFN's official PLaMo 3 Translate runtime: they are outputs of PLaMo 3 Translate (Article 5)
and are subject to the PLaMo Community License.

The rest of PlamoKit is part of Mimiuchi and licensed under the Apache License 2.0 (repository
`LICENSE` and `NOTICE`).

PlamoKit links MLX Swift (MIT); see `Licenses/README.md` for all bundled third-party licenses.
