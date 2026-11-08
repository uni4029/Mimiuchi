"""Reference translations (official runtime) for a broader parity check.

Usage: python -I eval_set.py <model_dir> <out_json>
"""
import json
import sys

import mlx.core as mx
from mlx_lm import load
from mlx_lm.generate import generate_step

SENTENCES = [
    ("ja", "en", "本日の会議資料を共有します。ご確認のほどよろしくお願いいたします。"),
    ("ja", "en", "このアプリはオフラインでも動作し、データは端末の外に送信されません。"),
    ("ja", "en", "猫が窓辺で日向ぼっこをしている。"),
    ("ja", "en", "締め切りが迫っているので、今日中にレビューを終わらせてください。"),
    ("ja", "en", "彼は医者になるために一生懸命勉強した。"),
    ("ja", "en", "東京駅から新大阪駅までは新幹線で約2時間30分です。"),
    ("ja", "en", "申し訳ありませんが、その件については担当者から改めてご連絡いたします。"),
    ("ja", "en", "量子コンピュータは特定の問題を古典的なコンピュータより高速に解くことができる。"),
    ("ja", "en", "雨が降りそうだから、傘を持って行ったほうがいいよ。"),
    ("ja", "en", "新機能のリリースは来月を予定しています。"),
    ("en", "ja", "Please make sure to back up your files before installing the update."),
    ("en", "ja", "The quick brown fox jumps over the lazy dog."),
    ("en", "ja", "Our quarterly revenue grew by 12% year over year, driven by strong demand in Asia."),
    ("en", "ja", "If you have any questions, feel free to reach out to our support team."),
    ("en", "ja", "Machine learning models can inherit biases present in their training data."),
    ("en", "ja", "I'm running a little late, but I'll be there in ten minutes."),
    ("en", "ja", "The museum is closed on Mondays and national holidays."),
    ("en", "ja", "Swift is a powerful and intuitive programming language for Apple platforms."),
    ("en", "ja", "She decided to take a gap year to travel around South America."),
    ("en", "ja", "Click the button below to verify your email address."),
    ("en", "zh-hans", "Thank you for your patience while we resolve this issue."),
    ("ja", "ko", "明日の天気は晴れのち曇りでしょう。"),
    ("en", "fr", "The conference will take place in Lyon next September."),
    ("en", "de", "Please close the door when you leave the room."),
    ("ja", "en", "第一章では、研究の背景と目的について述べる。\n第二章では、関連研究を整理する。"),
    ("en", "ja", "Error: the file could not be opened because you don't have permission to view it."),
    ("ja", "en", "お世話になっております。先日ご依頼いただいた見積書を添付いたします。"),
    ("en", "ja", "Photosynthesis converts light energy into chemical energy stored in glucose."),
    ("ja", "en", "この度は弊社製品をご購入いただき、誠にありがとうございます。"),
    ("en", "ja", "Turn left at the second traffic light and the station will be on your right."),
]

model_dir, out_path = sys.argv[1], sys.argv[2]
model, tok = load(model_dir, trust_remote_code=True, tokenizer_config={"trust_remote_code": True})
hf = tok._tokenizer
out = []
for src, tgt, text in SENTENCES:
    prompt = tok.apply_chat_template([{"role": "user", "content": text}], target_lang=tgt, add_generation_prompt=True, tokenize=False)
    ids = hf.encode(prompt, add_special_tokens=False)
    toks = []
    for t, _ in generate_step(mx.array(ids), model, max_tokens=256, sampler=lambda x: mx.argmax(x, axis=-1)):
        t = int(t)
        if t in (1, 16):
            break
        toks.append(t)
    out.append({"case": {"messages": [{"role": "user", "content": text}], "target_lang": tgt}, "tokens": toks, "text": hf.decode(toks)})
json.dump({"generations": out}, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print("wrote", len(out))
