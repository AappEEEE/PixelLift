#!/usr/bin/env python3
"""把 Real-ESRGAN 的现成权重转成 Core ML（零训练）。

模型：SRVGGNetCompact（realesr-general-x4v3 / realesr-animevideov3），原生 4x。
架构照抄上游 realesrgan/archs/srvgg_arch.py，不依赖 basicsr（避免 CI 上的安装地雷）。

用法: python scripts/convert_coreml.py --out Models [--tile 256]
"""

import argparse
import os
import sys
import urllib.request

import torch
from torch import nn
from torch.nn import functional as F

# name -> (权重直链, num_conv)
WEIGHTS = {
    "RealESRGANGeneral": (
        "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth",
        32,
    ),
    "RealESRGANAnime": (
        "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-animevideov3.pth",
        16,
    ),
}


class SRVGGNetCompact(nn.Module):
    def __init__(self, num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=32, upscale=4, act_type="prelu"):
        super().__init__()
        self.upscale = upscale
        body = [nn.Conv2d(num_in_ch, num_feat, 3, 1, 1)]
        act = nn.PReLU(num_parameters=num_feat) if act_type == "prelu" else nn.ReLU(inplace=True)
        body.append(act)
        for _ in range(num_conv):
            body.append(nn.Conv2d(num_feat, num_feat, 3, 1, 1))
            body.append(nn.PReLU(num_parameters=num_feat) if act_type == "prelu" else nn.ReLU(inplace=True))
        body.append(nn.Conv2d(num_feat, num_out_ch * upscale * upscale, 3, 1, 1))
        self.body = nn.ModuleList(body)
        self.upsampler = nn.PixelShuffle(upscale)

    def forward(self, x):
        out = x
        for layer in self.body:
            out = layer(out)
        out = self.upsampler(out)
        out += F.interpolate(x, scale_factor=self.upscale, mode="nearest")
        return out


def fetch(url: str, path: str) -> str:
    if os.path.isfile(path):
        print(f"[skip] 已存在 {path}")
        return path
    os.makedirs(os.path.dirname(path), exist_ok=True)
    print(f"[get ] {url}")
    urllib.request.urlretrieve(url, path)
    print(f"[ok  ] {path} ({os.path.getsize(path) / 1e6:.1f} MB)")
    return path


def load_state(pth: str):
    raw = torch.load(pth, map_location="cpu", weights_only=False)
    for key in ("params_ema", "params", "state_dict"):
        if isinstance(raw, dict) and key in raw:
            return raw[key]
    return raw


def convert(name: str, url: str, num_conv: int, out_dir: str, tile: int):
    import coremltools as ct

    print(f"=== {name} (num_conv={num_conv}) ===")
    pth = fetch(url, os.path.join("weights", os.path.basename(url)))
    model = SRVGGNetCompact(num_conv=num_conv, upscale=4, act_type="prelu")
    model.load_state_dict(load_state(pth), strict=True)
    model.eval()

    example = torch.rand(1, 3, tile, tile)
    with torch.no_grad():
        traced = torch.jit.trace(model, example, strict=False)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input", shape=example.shape)],
        outputs=[ct.TensorType(name="output")],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT32,
        compute_units=ct.ComputeUnit.ALL,
        convert_to="mlprogram",
    )
    mlmodel.short_description = f"{name}: Real-ESRGAN x4 (SRVGGNetCompact)"
    mlmodel.input_description["input"] = f"RGB 0..1, 1x3x{tile}x{tile}"
    mlmodel.output_description["output"] = f"RGB 0..1, 1x3x{tile * 4}x{tile * 4}"

    dst = os.path.join(out_dir, f"{name}.mlpackage")
    if os.path.isdir(dst):
        import shutil

        shutil.rmtree(dst)
    mlmodel.save(dst)
    print(f"[ok  ] {dst}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="Models")
    ap.add_argument("--tile", type=int, default=256)
    ap.add_argument("--only", default=None, help="只转某个模型名")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    todo = [(k, v) for k, v in WEIGHTS.items() if args.only in (None, k)]
    if not todo:
        sys.exit(f"未知模型 {args.only}，可选 {list(WEIGHTS)}")

    failed = []
    for name, (url, num_conv) in todo:
        try:
            convert(name, url, num_conv, args.out, args.tile)
        except Exception as exc:  # noqa: BLE001 - CI 里要把原因原样打出来
            import traceback

            print(f"[FAIL] {name}: {exc}")
            traceback.print_exc()
            failed.append(name)

    print("--- 产物 ---")
    for f in sorted(os.listdir(args.out)):
        p = os.path.join(args.out, f)
        if os.path.isdir(p):
            size = sum(os.path.getsize(os.path.join(r, x)) for r, _, fs in os.walk(p) for x in fs)
            print(f"{f}: {size / 1e6:.1f} MB")

    if len(failed) == len(todo):
        sys.exit("所有模型转换失败，见上面的 traceback")


if __name__ == "__main__":
    main()
