"""验证分块拼接几何：全覆盖、无重叠、无白边、位置不失真。

复刻 App/TileEngine.inferTile 的写入循环（tile=256, pad=32, crop=128, usable=768）。
"""
import numpy as np

TILE = 256
PAD = 32
CROP = PAD * 4          # 单侧丢弃的输出像素
USABLE = (TILE - 2 * PAD) * 4   # 768
STEP = TILE - 2 * PAD   # 192


def simulate(w, h):
    dst_w, dst_h = w * 4, h * 4
    counts = np.zeros((dst_h, dst_w), dtype=np.int32)
    cols = max(1, -(-w // STEP))
    rows = max(1, -(-h // STEP))
    # 记录每个目标像素 <-> 源像素 的映射一致性
    mapping = {}
    for row in range(rows):
        for col in range(cols):
            ox, oy = col * STEP, row * STEP
            for y in range(USABLE):
                dy = oy * 4 + y
                if dy >= dst_h:
                    break
                for x in range(USABLE):
                    dx = ox * 4 + x
                    if dx >= dst_w:
                        break
                    counts[dy, dx] += 1
                    # 采样点在输出块内的坐标
                    sy_out = y + CROP
                    sx_out = x + CROP
                    # 该输出坐标对应的源坐标
                    src_x = ox - PAD + sx_out // 4
                    src_y = oy - PAD + sy_out // 4
                    expect = (dy // 4, dx // 4)
                    got = (src_y, src_x)
                    if got != expect:
                        mapping[(dy, dx)] = (expect, got)
    return counts, mapping, cols, rows


cases = [(1, 1), (16, 9), (100, 80), (256, 256), (500, 333), (1024, 768),
         (1365, 1024), (2000, 1500)]
ok = True
for w, h in cases:
    counts, mapping, cols, rows = simulate(w, h)
    zero = int((counts == 0).sum())
    multi = int((counts > 1).sum())
    bad = len(mapping)
    status = "OK" if (zero == 0 and multi == 0 and bad == 0) else "FAIL"
    if status == "FAIL":
        ok = False
    print(f"{w}x{h:>5} tiles={cols}x{rows} dst={w*4}x{h*4} "
          f"未写像素={zero} 重复写={multi} 位置错={bad} -> {status}")

print()
print("结论:", "全部通过（无白边、无缝、无重复、坐标无偏移）" if ok else "存在问题")
