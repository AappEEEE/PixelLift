"""对比原图与超分输出的质量：清晰度指标 + 同区域对照图。

配对来自用户提供的 8 张图：147/148、149/152、150/154、151/153。
"""
import os
import numpy as np
from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "docs", "quality")
os.makedirs(OUT, exist_ok=True)

PAIRS = [
    ("blackboard", "微信图片_20261110113603_147_53.jpg", "微信图片_20261110113637_148_53.png",
     [(0.06, 0.42, 0.30, 0.62)]),
    ("game", "微信图片_20261110122947_149_53.png", "微信图片_20261110122947_152_53.png",
     [(0.38, 0.55, 0.60, 0.72)]),
    ("laptop", "微信图片_20261110122947_150_53.jpg", "微信图片_20261110122947_154_53.png",
     [(0.35, 0.32, 0.55, 0.47)]),
    ("monitor", "微信图片_20261110122947_151_53.jpg", "微信图片_20261110122947_153_53.png",
     [(0.45, 0.35, 0.62, 0.48)]),
]


def gray(a):
    return np.asarray(Image.fromarray(a).convert("L"), dtype=np.float32)


def lap_var(g):
    k = np.array([[0, 1, 0], [1, -4, 1], [0, 1, 0]], np.float32)
    h, w = g.shape
    o = np.zeros((h - 2, w - 2), np.float32)
    for dy in range(3):
        for dx in range(3):
            o += k[dy, dx] * g[dy:dy + h - 2, dx:dx + w - 2]
    return float(o.var())


def grad(g):
    return float((np.abs(np.diff(g, axis=0)).mean() + np.abs(np.diff(g, axis=1)).mean()) / 2)


def hf(a, blur=1.2):
    g = gray(a)
    b = gray(np.asarray(Image.fromarray(a).filter(ImageFilter.GaussianBlur(blur))))
    return float(np.abs(g - b).mean() / (np.abs(g).mean() + 1e-6) * 1000)


def load(n):
    return np.asarray(Image.open(os.path.join(ROOT, n)).convert("RGB"))


def sheet(name, orig, out, box, tile=440):
    ho, wo = orig.shape[:2]
    hx, wx = out.shape[:2]
    x0, y0, x1, y1 = box
    ox0, oy0, ox1, oy1 = int(x0 * wo), int(y0 * ho), int(x1 * wo), int(y1 * ho)
    sx, sy = wx / wo, hx / ho
    px0, py0, px1, py1 = int(ox0 * sx), int(oy0 * sy), int(ox1 * sx), int(oy1 * sy)

    a = Image.fromarray(orig[oy0:oy1, ox0:ox1])
    b = Image.fromarray(out[py0:py1, px0:px1])

    # 左：原图裁块放大到 tile；中：输出对应区域缩到同尺寸；右：输出 1:1 原生像素
    a_show = a.resize((tile, tile), Image.LANCZOS)
    b_show = b.resize((tile, tile), Image.LANCZOS)
    b_native = b.resize((tile, int(tile * b.height / b.width)), Image.LANCZOS)

    sh = Image.new("RGB", (tile * 3 + 32, tile + 46), (16, 16, 18))
    sh.paste(a_show, (0, 40))
    sh.paste(b_show, (tile + 16, 40))
    sh.paste(b_native, (tile * 2 + 32, 40))
    p = os.path.join(OUT, f"cmp2_{name}.png")
    sh.save(p)
    return p


rows = []
for name, on, pn, boxes in PAIRS:
    orig, out = load(on), load(pn)
    down = np.asarray(Image.fromarray(out).resize((orig.shape[1], orig.shape[0]), Image.LANCZOS))
    row = dict(
        name=name,
        src=f"{orig.shape[1]}x{orig.shape[0]}",
        dst=f"{out.shape[1]}x{out.shape[0]}",
        ratio=out.shape[1] / orig.shape[1],
        lap_o=lap_var(gray(orig)),
        lap_d=lap_var(gray(down)),
        grad_o=grad(gray(orig)),
        grad_d=grad(gray(down)),
        hf_o=hf(orig),
        hf_d=hf(down),
    )
    rows.append(row)
    print(f"{name:11s} {row['src']:>10s} -> {row['dst']:>10s} ({row['ratio']:.2f}x)  "
          f"Laplacian {row['lap_o']:6.1f} -> {row['lap_d']:6.1f} ({row['lap_d']/row['lap_o']*100:5.1f}%)  "
          f"梯度 {row['grad_o']:.3f} -> {row['grad_d']:.3f}  "
          f"高频‰ {row['hf_o']:.1f} -> {row['hf_d']:.1f}")
    for i, box in enumerate(boxes):
        print("   对照图:", os.path.relpath(sheet(f"{name}_{i+1}", orig, out, box), ROOT))
