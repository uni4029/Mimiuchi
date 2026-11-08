"""Generate golden reference data from PFN's official mlx-lm runtime.

Usage: python -I reference.py <model_dir> <out_json> [--gen]
"""
import json
import sys
import time

import mlx.core as mx
from mlx_lm import load
from mlx_lm.generate import generate_step

model_dir, out_path = sys.argv[1], sys.argv[2]
do_gen = "--gen" in sys.argv

model, tokenizer = load(model_dir, trust_remote_code=True, tokenizer_config={"trust_remote_code": True})
hf = tokenizer._tokenizer

TOKENIZER_CASES = [
    "",
    "Hello, world!",
    "会議は来週の月曜日に変更されました。",
    "The meeting has been rescheduled for next Monday.",
    "  leading and trailing spaces  ",
    "multiple    spaces\tand\ttabs\nnew\nlines\r\nCRLF",
    "aaaaaaa bbbb ccc!!!!!! ????",
    "\n\n\n\n\n",
    "ーーーーー長音",
    "絵文字😀👍🏽 and 𠮷野家 and \u0000\u0001 controls",
    "Ünïcödé façade naïve café — “quotes” ‘single’ …",
    "中文简体：今天天气很好。繁體中文：今天天氣很好。",
    "한국어 문장입니다. Русский текст. العربية. हिन्दी. ภาษาไทย",
    "<|plamo:tag|>dataset<|plamo:msg|>translation<|plamo:tag|>input<|plamo:msg|>テスト<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>en<|plamo:msg|>",
    "<|plamo:unknowntoken|> and <|plamo:bad token|> and <|plamo:|>",
    "code: `for (int i = 0; i < n; ++i) { sum += a[i]; }`",
    "URL https://example.com/path?q=1&r=2#frag",
    "1234567890 3.14159 1,000,000 ¥1,000 $5.00 50%",
    "　全角スペース　　　　です",
    "x" * 70,
    "Emoji ZWJ 👨‍👩‍👧‍👦 flag 🇯🇵 keycap 1️⃣",
]

def encode(text):
    return hf.encode(text, add_special_tokens=False)

result = {"tokenizer": [], "prompts": [], "generations": []}
for t in TOKENIZER_CASES:
    ids = encode(t)
    result["tokenizer"].append({"text": t, "ids": ids, "decoded": hf.decode(ids)})

GEN_CASES = [
    {"messages": [{"role": "user", "content": "会議は来週の月曜日に変更されました。"}], "target_lang": "en"},
    {"messages": [{"role": "user", "content": "The meeting has been rescheduled for next Monday."}], "target_lang": "ja"},
    {"messages": [{"role": "user", "content": "This system is convenient."}], "target_lang": "ja", "form": "plain"},
    {"messages": [{"role": "user", "content": "かみを切りました。"}], "target_lang": "en", "context": "工作で折り紙を作っています。"},
    {"messages": [{"role": "user", "content": "プロジェクトの管理画面を開いてください。"}], "target_lang": "en",
     "glossary": [{"source": "管理画面", "target": "dashboard"}, {"source": "プロジェクト", "target": "project"}]},
    {"messages": [{"role": "user", "content": "Machine translation has improved dramatically.\n\nHowever, ambiguity remains a challenge, especially for short texts without context."}], "target_lang": "ja", "source_lang": "en"},
    {"messages": [{"role": "user", "content": "今日はいい天気ですね。散歩に行きましょう。"}], "target_lang": "zh-hans"},
]

for case in GEN_CASES:
    kwargs = {k: v for k, v in case.items() if k != "messages"}
    prompt = tokenizer.apply_chat_template(case["messages"], add_generation_prompt=True, tokenize=False, **kwargs)
    ids = hf.encode(prompt, add_special_tokens=not prompt.startswith(hf.bos_token))
    entry = {"case": case, "prompt": prompt, "prompt_ids": ids}
    result["prompts"].append(entry)
    if do_gen:
        tokens = []
        first_logits = None
        t0 = time.time()
        for n, (tok, logprobs) in enumerate(generate_step(mx.array(ids), model, max_tokens=256, sampler=lambda x: mx.argmax(x, axis=-1))):
            tok = int(tok)
            if n == 0:
                top = mx.argsort(-logprobs)[:5]
                first_logits = {"top_ids": [int(i) for i in top.tolist()], "top_logprobs": [float(logprobs[i]) for i in top.tolist()]}
            if tok in (1, 16):
                break
            tokens.append(tok)
        dt = time.time() - t0
        entry_gen = {"case": case, "tokens": tokens, "text": hf.decode(tokens), "first": first_logits, "seconds": dt}
        result["generations"].append(entry_gen)
        print(json.dumps({"text": entry_gen["text"], "n": len(tokens), "sec": round(dt, 2)}, ensure_ascii=False))

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(result, f, ensure_ascii=False, indent=1)
print("wrote", out_path)
