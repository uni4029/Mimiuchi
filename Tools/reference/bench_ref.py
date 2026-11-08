import sys, time
import mlx.core as mx
from mlx_lm import load
from mlx_lm.generate import generate_step
model, tok = load(sys.argv[1], trust_remote_code=True, tokenizer_config={"trust_remote_code": True})
text = "機械翻訳の品質は近年大きく向上しましたが、短い文や専門用語を含む文章では依然として誤訳が発生することがあります。" * 6
prompt = tok.apply_chat_template([{"role": "user", "content": text}], target_lang="en", add_generation_prompt=True, tokenize=False)
ids = tok._tokenizer.encode(prompt, add_special_tokens=False)
for _ in range(2):
    t0 = time.time(); n = 0; tfirst = None
    for t, _ in generate_step(mx.array(ids), model, max_tokens=400, sampler=lambda x: mx.argmax(x, axis=-1)):
        if tfirst is None: tfirst = time.time()
        if int(t) in (1, 16): break
        n += 1
    t1 = time.time()
    print(f"prompt {len(ids)} prefill {tfirst-t0:.3f}s | gen {n} tok {n/(t1-tfirst):.1f} tok/s")
