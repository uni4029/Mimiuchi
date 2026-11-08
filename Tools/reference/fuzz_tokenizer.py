"""Generate random tokenizer test cases with PFN's reference tokenizer.

Usage: python -I fuzz_tokenizer.py <model_dir> <out_json> [count]
"""
import json
import random
import sys

from transformers import AutoTokenizer

model_dir, out_path = sys.argv[1], sys.argv[2]
count = int(sys.argv[3]) if len(sys.argv) > 3 else 3000
tok = AutoTokenizer.from_pretrained(model_dir, trust_remote_code=True)

rng = random.Random(1234)
POOLS = [
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,;:!?'\"()-_/\\@#$%^&*+=<>[]{}|~`",
    "あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをんがぎぐげござじずぜぞっゃゅょー",
    "アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲンガギグゲゴャュョッー",
    "日本語翻訳会議来週月曜変更機械学習自然言語処理東京大阪今日天気散歩行政府国民経済社会文化",
    "中文简体繁體天氣很好我们他们这个那个說話说话學習学习",
    "한국어문장입니다안녕하세요감사합니다",
    "Русскийтекстпривет мир",
    "العربيةمرحبا",
    "हिन्दीनमस्ते",
    "ภาษาไทยสวัสดี",
    "ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÑÒÓÔÕÖØÙÚÛÜÝßàáâãäåæçèéêëìíîïñòóôõöøùúûüýÿœŒ",
    "😀😃😄😁😆😅🤣😂🙂🙃😉😊😇🥰😍🤩👍👎🏽🏻‍♀️♂️🇯🇵🇺🇸👨‍👩‍👧",
    "𠮷𩸽𪚲𡈽𠀋𤭢",
    "\t\n\r 　  ​\u0000\u0001\u001f\u007f\u0085",
    "「」『』（）【】、。・…—–“”‘’！？",
]
SPECIALS = ["<|plamo:tag|>", "<|plamo:msg|>", "<|plamo:key|>", "<|plamo:val|>", "<|plamo:bos|>",
            "<|plamo:index|>", "<|plamo:item|>", "<|plamo:fake|>", "<|plamo:bad token|>", "<|plamo:|>",
            "<|plamo:" + "x" * 64 + "|>", "<|plamo:" + "y" * 65 + "|>", "<|plamo:begin_", ":plamo|>", "<|plamo:tag|", "|>"]
WORDS = ["the", "meeting", "translation", "model", "Apple", "Mac", "翻訳", "モデル", "です", "ます", "これは", "ペン",
         "hello", "world", "PLaMo", "DeepL", "https://example.com", "1,000", "3.14"]


def piece():
    r = rng.random()
    if r < 0.08:
        return rng.choice(SPECIALS)
    if r < 0.18:
        ch = rng.choice(rng.choice(POOLS))
        return ch * rng.randint(2, 9)
    if r < 0.25:
        return " " * rng.randint(1, 6)
    if r < 0.45:
        return rng.choice(WORDS) + rng.choice(["", " ", "\n", "。", ", "])
    pool = rng.choice(POOLS)
    return "".join(rng.choice(pool) for _ in range(rng.randint(1, 12)))


cases = []
for i in range(count):
    text = "".join(piece() for _ in range(rng.randint(0, 12)))
    ids = tok.encode(text, add_special_tokens=False)
    cases.append({"text": text, "ids": ids})

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(cases, f, ensure_ascii=False)
print("wrote", len(cases), "cases to", out_path)
