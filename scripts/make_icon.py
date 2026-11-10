"""生成 App 图标（1024x1024, RGB, 无 alpha）"""
import math
import os
from PIL import Image, ImageDraw

S = 1024
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "App", "Assets.xcassets", "AppIcon.appiconset")

img = Image.new("RGB", (S, S), (16, 18, 32))
d = ImageDraw.Draw(img)

# 竖向渐变：深靛 -> 紫
top = (26, 28, 58)
bot = (92, 46, 168)
for y in range(S):
    t = y / (S - 1)
    c = tuple(round(top[i] + (bot[i] - top[i]) * t) for i in range(3))
    d.line([(0, y), (S, y)], fill=c)

# 背景柔和光晕
glow = Image.new("RGB", (S, S), (0, 0, 0))
gd = ImageDraw.Draw(glow)
for r in range(420, 0, -6):
    a = int(48 * (1 - r / 420) ** 2)
    gd.ellipse([S * 0.72 - r, S * 0.18 - r, S * 0.72 + r, S * 0.18 + r],
               fill=(120, 200, 255) if a else (0, 0, 0))
img = Image.blend(img, Image.new("RGB", (S, S), (60, 140, 240)), 0.10)
d = ImageDraw.Draw(img)

# 三级"像素阶梯"，从左下到右上，尺寸递增 == 放大
base_x, base_y = 176, 848
steps = [(0, 0, 168), (208, -208, 208), (416, -416, 248)]
colors = [(255, 255, 255), (210, 226, 255), (140, 196, 255)]
for (dx, dy, size), col in zip(steps, colors):
    x = base_x + dx
    y = base_y + dy
    d.rounded_rectangle([x, y - size, x + size, y], radius=size // 9, fill=col,
                        outline=(255, 255, 255) if col != (255, 255, 255) else None, width=6)

# 右上角细箭头，暗示"提升"
ax, ay = 812, 236
d.line([(ax - 118, ay + 118), (ax, ay)], fill=(120, 235, 210), width=26)
d.line([(ax - 96, ay), (ax, ay)], fill=(120, 235, 210), width=26)
d.line([(ax, ay), (ax, ay + 96)], fill=(120, 235, 210), width=26)

os.makedirs(OUT, exist_ok=True)
p = os.path.join(OUT, "AppIcon-1024.png")
img.save(p, "PNG")
print(p, img.size, img.mode)
