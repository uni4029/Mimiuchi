# Reference data (PFN official mlx-lm runtime)

Golden outputs used to validate the Swift port. The JSON files are outputs of PLaMo 3 Translate
(© Preferred Networks, Inc.), generated with PFN's official runtime, and are subject to the PLaMo
Community License (see `NOTICE`). Regenerate with PFN's pinned runtime:

```sh
uv venv venv --python 3.12
VIRTUAL_ENV=$PWD/venv uv pip install "mlx==0.32.3" "mlx-lm==0.32.0" "transformers==5.19.0" "numba==0.68.0"
hf download pfnet/plamo-3-translate-0.8b-MLX-4bit --local-dir model-0.8b
./venv/bin/python -I reference.py model-0.8b golden-0.8b.json --gen   # tokenizer + 7 generations
./venv/bin/python -I eval_set.py  model-0.8b eval-0.8b.json           # 30 sentences
./venv/bin/python -I fuzz_tokenizer.py model-0.8b fuzz.json 3000     # tokenizer fuzz cases
plamo-cli golden 0.8b golden-0.8b.json                                # compare with the Swift engine
```
