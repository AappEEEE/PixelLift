#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
PixelLift M6 · 动态模糊数学验证（离线，numpy）

本脚本不是"跑一下看看"，而是把 MotionBlurCore.swift 里的每一条公式与常量
逐条复刻，然后用可复算的断言把设计决策钉死。跑法：

    python verify_blur_math.py

验证内容（与 RESEARCH.md 的章节一一对应）：
  S1 快门窗几何     : W = (theta/360)/perPair，[t, t+W] 恒在 [0,1] 内，360° 无缝铺满
  S2 权重函数       : 矩形窗 vs 三角窗的等效曝光时长 / 二阶矩
  S3 线性光累积     : sRGB 域平均 vs 线性域平均的码值差、灰阶中性、能量守恒
  S4 sRGB LUT       : 4096 段解码 + 4096 段 sqrt 索引编码的误差与 256 码值往返
  S5 采样密度       : 沿轨迹离散采样的"阶梯"残差，验证 stepPixels=1 的准则
  S6 成本模型       : 块自适应 avgM 的上界与 costCeiling 行为

所有断言都打印实测数字，PASS 只表示"和 MotionBlurCore.swift 的假设一致"。
"""

import sys

import numpy as np

FAIL = []

try:
    _TRAP = np.trapezoid          # numpy >= 2.0
except AttributeError:            # pragma: no cover
    _TRAP = np.trapz             # numpy 1.x


def check(name, ok, detail):
    tag = "PASS" if ok else "FAIL"
    print("[%s] %-28s %s" % (tag, name, detail))
    if not ok:
        FAIL.append(name)


# --------------------------------------------------------------------------
# 与 Swift 侧一致的常量
# --------------------------------------------------------------------------
DECODE_SEGMENTS = 4096      # MotionBlurCore.decodeSegments
ENCODE_SEGMENTS = 4096      # MotionBlurCore.encodeSegments
STEP_PIXELS = 1.0           # MotionBlurCore.Plan.stepPixels
BLOCK_SIZE = 32             # MotionBlurCore.Plan.blockSize
MAX_SAMPLES = 32            # MotionBlurCore 内部硬上限


def srgb_eotf(v):
    """IEC 61966-2-1 sRGB 电光转换（与 SDRToHDR.eotf / MotionBlurCore.eotfExact 同式）。"""
    v = np.asarray(v, dtype=np.float64)
    low = v / 12.92
    high = np.power(np.clip((v + 0.055) / 1.055, 0.0, None), 2.4)
    return np.where(v <= 0.04045, low, high)


def srgb_oetf(y):
    """sRGB 光电转换（编码回码值）。"""
    y = np.asarray(y, dtype=np.float64)
    low = y * 12.92
    high = 1.055 * np.power(np.clip(y, 0.0, None), 1.0 / 2.4) - 0.055
    return np.where(y <= 0.0031308, low, high)


# --------------------------------------------------------------------------
# S1 快门窗几何
# --------------------------------------------------------------------------
def s1_window_geometry():
    ok_all = True
    worst_hi = 0.0
    for angle in (0.0, 90.0, 180.0, 270.0, 360.0):
        for per_pair in (1, 2, 3, 4, 5, 8, 16):
            width = (angle / 360.0) / float(per_pair)
            for j in range(per_pair):
                t = float(j) / float(per_pair)
                end = t + width
                worst_hi = max(worst_hi, end)
                if end > 1.0 + 1e-12:
                    ok_all = False
    check("S1 窗不越界", ok_all, "max(t+W) = %.6f (需 <= 1)" % worst_hi)

    # duty cycle = W * perPair = theta/360：180° 恰好一半，360° 恰好铺满
    duty = {}
    ok_duty = True
    for angle in (180.0, 270.0, 360.0):
        for per_pair in (1, 2, 4):
            width = (angle / 360.0) / float(per_pair)
            d = width * float(per_pair)
            duty[(angle, per_pair)] = d
            if abs(d - angle / 360.0) > 1e-12:
                ok_duty = False
    check("S1 duty cycle", ok_duty,
          "180°->%.3f 270°->%.3f 360°->%.3f" %
          (duty[(180.0, 4)], duty[(270.0, 4)], duty[(360.0, 4)]))

    # 360° 首尾相接：相邻窗 [t_i, t_i+W] 与 [t_{i+1}, t_{i+1}+W] 恰好无缝无重叠
    ok_tile = True
    gap_max = 0.0
    for per_pair in (1, 2, 4, 8):
        width = 1.0 / float(per_pair)
        edges = []
        for j in range(per_pair):
            t = float(j) / float(per_pair)
            edges.append((t, t + width))
        edges.sort()
        for i in range(len(edges) - 1):
            gap = edges[i + 1][0] - edges[i][1]
            gap_max = max(gap_max, abs(gap))
            if abs(gap) > 1e-12:
                ok_tile = False
    check("S1 360° 无缝铺满", ok_tile, "相邻窗间隙 max = %.3e" % gap_max)

    # 帧率归一化：outFps 翻倍 => perPair 翻倍 => W 减半（模糊量不随 fps 变化）
    w30 = (180.0 / 360.0) / 1.0
    w60 = (180.0 / 360.0) / 2.0
    check("S1 60fps 模糊=30fps 一半", abs(w60 - w30 * 0.5) < 1e-12,
          "W(30fps)=%.3f W(60fps)=%.3f 比值=%.3f" % (w30, w60, w60 / w30))


# --------------------------------------------------------------------------
# S2 权重函数：矩形（等权）vs 三角
# --------------------------------------------------------------------------
def s2_weights():
    n = 200001
    x = np.linspace(-0.5, 0.5, n)
    rect = np.ones(n)
    tri = 1.0 - np.abs(x) / 0.5

    # 归一化等效曝光时长 = integral(w) / max(w)，窗宽取 1 个单位
    eff_rect = _TRAP(rect, x) / rect.max()
    eff_tri = _TRAP(tri, x) / tri.max()
    ratio = eff_tri / eff_rect
    check("S2 三角窗等效时长=一半", abs(ratio - 0.5) < 1e-3,
          "rect=%.4f tri=%.4f ratio=%.4f" % (eff_rect, eff_tri, ratio))

    # 二阶矩（拖影的"软硬"）：矩形 = W^2/12，三角 = W^2/24
    var_rect = _TRAP(rect * x * x, x) / _TRAP(rect, x)
    var_tri = _TRAP(tri * x * x, x) / _TRAP(tri, x)
    check("S2 二阶矩比", abs(var_rect / var_tri - 2.0) < 1e-2,
          "var_rect=%.5f var_tri=%.5f 比=%.3f (理论 2.0)" %
          (var_rect, var_tri, var_rect / var_tri))

    # 峰值亮度：同一条亮条，三角窗把两端压暗到 0，(等权)矩形窗保持 1
    # 归一化后同一总能量下矩形的峰值低于三角（更"宽"），但两端不被压暗
    print("        -> 结论：三角权重 = 矩形窗再卷一个三角核，等效曝光时长减半，"
          "拖影亮度两端按 1-|x| 衰减；要补回同样的模糊量必须把窗宽加倍，"
          "而加倍后又会让模糊超出真实曝光窗。等权矩形才是快门。")


# --------------------------------------------------------------------------
# S3 线性光累积 vs sRGB 域累积
# --------------------------------------------------------------------------
def s3_linear_light():
    # 3.1 单一覆盖率 f：一个像素在曝光窗内被亮条覆盖的比例
    f = np.linspace(0.0, 1.0, 1025)
    code_linear = srgb_oetf(f) * 255.0        # 正确：先在线性域平均再编码
    code_naive = f * 255.0                    # 错误：直接平均码值
    delta = np.abs(code_linear - code_naive)
    idx = int(np.argmax(delta))
    check("S3 sRGB 平均最大偏差", delta.max() > 20.0,
          "max=%.1f 码 @ f=%.3f (正确 %.1f vs 直接 %.1f)" %
          (delta[idx], f[idx], code_linear[idx], code_naive[idx]))

    # 3.2 灰阶中性：三通道同值时，线性累积后仍同值（不偏色）
    gray = np.array([0.0, 7.0, 32.0, 64.0, 128.0, 200.0, 255.0])
    lin = srgb_eotf(gray / 255.0)
    back = srgb_oetf(lin) * 255.0
    rt = float(np.max(np.abs(back - gray)))
    # 真实累积路径：三通道各走一遍 decode -> 加权 -> encode
    weights = np.array([0.2, 0.3, 0.5])
    a3 = np.repeat(lin[:, None], 3, axis=1)          # (7,3) 三通道相同的灰
    acc3 = a3 * weights[0]
    acc3 = acc3 + a3 * weights[1]
    acc3 = acc3 + a3 * weights[2]
    acc3 = acc3 / float(weights.sum())
    out3 = srgb_oetf(acc3) * 255.0
    spread = float(np.max(np.ptp(out3, axis=1)))
    check("S3 灰阶不偏色", spread < 1e-12 and rt < 1e-6,
          "通道间差=%.3e 往返误差=%.3e 码" % (spread, rt))

    # 3.3 彩色亮条被快速拖影后的色相偏移
    bar = np.array([0.90, 0.35, 0.20])        # 橙红色（线性域）
    cover = 0.25                              # 每个像素只被覆盖 1/4 曝光
    lin_out = bar * cover
    code_true = srgb_oetf(lin_out) * 255.0
    code_bar = srgb_oetf(bar) * 255.0
    code_naive_rgb = code_bar * cover
    code_err = float(np.max(np.abs(code_true - code_naive_rgb)))
    hue_true = code_true / max(code_true.max(), 1e-9)
    hue_naive = code_naive_rgb / max(code_naive_rgb.max(), 1e-9)
    hue_err = float(np.max(np.abs(hue_true - hue_naive)))
    check("S3 拖影亮度+色相偏移", code_err > 40.0 and hue_err > 0.01,
          "最大码值差 %.1f / 归一化色相偏移 %.4f (真实 %s vs 直接 %s)" %
          (code_err, hue_err, np.round(hue_true, 3).tolist(),
           np.round(hue_naive, 3).tolist()))

    # 3.4 能量守恒：沿轨迹积分，(1/m)Σ 采样 的总和与 m 无关
    w = 256
    base = np.zeros(w)
    base[100:140] = 1.0                       # 40px 亮条
    energy_ref = base.sum()
    travel = 24.0                             # 窗内总位移（像素）
    errs = []
    for m in (1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64):
        acc = np.zeros(w)
        for j in range(m):
            frac = (j + 0.5) / m
            shift = travel * frac
            xs = np.arange(w, dtype=np.float64) - shift
            acc += np.interp(xs, np.arange(w, dtype=np.float64), base,
                             left=0.0, right=0.0)
        acc /= float(m)
        errs.append((m, abs(acc.sum() - energy_ref) / energy_ref))
    worst = max(e for _, e in errs)
    check("S3 能量守恒（任意 m）", worst < 2e-3,
          "m=1..64 相对能量误差 max=%.2e（与 m 无关）" % worst)


# --------------------------------------------------------------------------
# S4 sRGB LUT 精度（与 Swift 侧逐行对应）
# --------------------------------------------------------------------------
def build_decode_table():
    n = DECODE_SEGMENTS
    table = np.zeros(n + 1, dtype=np.float64)
    for i in range(n + 1):
        code = float(i) * (255.0 / float(n))
        table[i] = float(srgb_eotf(code / 255.0))
    return table


def build_encode_table():
    n = ENCODE_SEGMENTS
    table = np.zeros(n + 1, dtype=np.float64)
    for i in range(n + 1):
        u = float(i) / float(n)
        y = u * u
        table[i] = float(srgb_oetf(y))
    return table


DECODE_TABLE = build_decode_table()
ENCODE_TABLE = build_encode_table()


def decode_srgb(code):
    """与 MotionBlurCore.decodeSRGB 等价：code in [0,255] -> 线性 [0,1]。"""
    n = float(DECODE_SEGMENTS)
    pos = code * (n / 255.0)
    if not (pos >= 0.0):
        pos = 0.0
    if pos > n:
        pos = n
    i = int(pos)
    if i > DECODE_SEGMENTS - 1:
        i = DECODE_SEGMENTS - 1
    frac = pos - float(i)
    lo = DECODE_TABLE[i]
    hi = DECODE_TABLE[i + 1]
    return lo + (hi - lo) * frac


def encode_srgb(linear):
    """与 MotionBlurCore.encodeSRGB 等价：线性 [0,1] -> [0,1] 码值比例。"""
    n = float(ENCODE_SEGMENTS)
    y = linear
    if not (y >= 0.0):
        y = 0.0
    if y > 1.0:
        y = 1.0
    root = np.sqrt(y)
    pos = root * n
    if not (pos >= 0.0):
        pos = 0.0
    if pos > n:
        pos = n
    i = int(pos)
    if i > ENCODE_SEGMENTS - 1:
        i = ENCODE_SEGMENTS - 1
    frac = pos - float(i)
    lo = ENCODE_TABLE[i]
    hi = ENCODE_TABLE[i + 1]
    return lo + (hi - lo) * frac


def s4_lut():
    # 4.1 解码精度：所有 8-bit 码值
    codes = np.arange(0, 256, dtype=np.float64)
    exact = srgb_eotf(codes / 255.0)
    got = np.array([decode_srgb(float(c)) for c in codes])
    err_code = float(np.max(np.abs(got - exact))) * 255.0
    check("S4 解码 LUT 误差", err_code < 0.01,
          "4096 段 最大 %.5f 码" % err_code)

    # 4.2 编码精度：连续扫描（含 knee 附近）
    ys = np.linspace(0.0, 1.0, 200001)
    exact_o = srgb_oetf(ys)
    got_o = np.array([encode_srgb(float(y)) for y in ys[::200]])
    ref_o = exact_o[::200]
    err_o = float(np.max(np.abs(got_o - ref_o))) * 255.0
    check("S4 编码 LUT 误差", err_o < 0.01,
          "4096 段 sqrt 索引 最大 %.5f 码" % err_o)

    # 4.3 256 码值往返：必须逐字节复原
    rt = np.zeros(256, dtype=np.int64)
    for c in range(256):
        lin = decode_srgb(float(c))
        out = encode_srgb(lin) * 255.0
        rt[c] = int(round(out))
    bad = int(np.count_nonzero(rt != np.arange(256)))
    check("S4 往返 256 码值精确", bad == 0, "不一致码值数 = %d" % bad)

    # 4.4 编码单调性（LUT 不能出现反转，否则出现色带/极性噪声）
    ys2 = np.linspace(0.0, 1.0, 50001)
    seq = np.array([encode_srgb(float(y)) for y in ys2])
    dec = int(np.count_nonzero(np.diff(seq) < -1e-12))
    check("S4 编码单调", dec == 0, "降序段数 = %d" % dec)

    # 4.5 全帧码值扫描下的最大往返误差（0..255 输入，多次累积不漂移）
    acc = np.zeros(256)
    for _ in range(8):
        acc += np.array([decode_srgb(float(c)) for c in range(256)])
    acc /= 8.0
    back = np.array([encode_srgb(float(v)) * 255.0 for v in acc])
    worst = float(np.max(np.abs(np.round(back) - np.arange(256))))
    check("S4 8 次累积不漂移", worst == 0.0, "最大偏差 %.3f 码" % worst)


# --------------------------------------------------------------------------
# S5 采样密度：沿轨迹的离散积分 vs 连续积分
# --------------------------------------------------------------------------
def s5_sampling():
    w = 512
    grid = np.arange(w, dtype=np.float64)

    def step_scene(xs):
        # 场景：x < 200 为 1，其余为 0（一条竖直边缘在 x=200）
        return np.where(xs < 200.0, 1.0, 0.0)

    travel = 20.0            # 窗内总位移 20px
    center = 200.0
    ref = np.zeros(w)
    samples = 4000           # 连续参考（数值积分）
    for j in range(samples):
        frac = (j + 0.5) / samples
        ref += np.interp(grid - center - travel * frac, grid, step_scene(grid),
                         left=0.0, right=0.0)
    ref /= float(samples)

    rows = []
    for m in (2, 4, 5, 10, 20, 40, 80):
        acc = np.zeros(w)
        for j in range(m):
            frac = (j + 0.5) / m
            # 双线性采样 = 对场景做 1px 宽的 tent 积分（与 FrameOps.sample 一致）
            acc += np.interp(grid - center - travel * frac, grid, step_scene(grid),
                             left=0.0, right=0.0)
        acc /= float(m)
        err = float(np.max(np.abs(acc - ref))) * 255.0
        m_per_px = m / travel
        rows.append((m, m_per_px, err))

    for m, per_px, err in rows:
        print("        m=%3d (%.2f 样本/px) 边缘阶梯最大残差 %.2f 码" %
              (m, per_px, err))

    # 准则：样本间距 <= 1px（即 m >= travel/stepPixels = travel）时残差应 < 1 码
    ok_rule = True
    for m, per_px, err in rows:
        if per_px >= 1.0 - 1e-9 and err > 1.0:
            ok_rule = False
    m_ok = [r for r in rows if r[1] >= 1.0]
    check("S5 stepPixels=1 准则", ok_rule,
          "m>=travel 时残差 max=%.3f 码" % max(r[2] for r in m_ok))

    # 反例：样本间距 4px 时残差多大（说明 stepPixels 不能放粗）
    m_bad = [r for r in rows if abs(r[1] - 0.25) < 1e-9]
    if m_bad:
        check("S5 粗采样会露台阶", m_bad[0][2] > 5.0,
              "m=%d (0.25 样本/px) 残差 %.1f 码" % (m_bad[0][0], m_bad[0][2]))

    # 长拖影外推：travel=64px 时 m=64 是否仍平滑
    travel2 = 64.0
    ref2 = np.zeros(w)
    for j in range(samples):
        frac = (j + 0.5) / samples
        ref2 += np.interp(grid - center - travel2 * frac, grid, step_scene(grid),
                          left=0.0, right=0.0)
    ref2 /= float(samples)
    acc2 = np.zeros(w)
    m2 = 64
    for j in range(m2):
        frac = (j + 0.5) / m2
        acc2 += np.interp(grid - center - travel2 * frac, grid, step_scene(grid),
                          left=0.0, right=0.0)
    acc2 /= float(m2)
    err2 = float(np.max(np.abs(acc2 - ref2))) * 255.0
    check("S5 64px 长拖影", err2 < 1.0, "m=64 残差 %.3f 码" % err2)


# --------------------------------------------------------------------------
# S6 成本模型
# --------------------------------------------------------------------------
def s6_cost():
    # 4K 帧按 32x32 分块
    w, h = 3840, 2160
    bx = (w + BLOCK_SIZE - 1) // BLOCK_SIZE
    by = (h + BLOCK_SIZE - 1) // BLOCK_SIZE
    blocks = bx * by
    areas = []
    for j in range(by):
        y0 = j * BLOCK_SIZE
        hh = min(BLOCK_SIZE, h - y0)
        for i in range(bx):
            xx = min(BLOCK_SIZE, w - i * BLOCK_SIZE)
            areas.append(xx * hh)
    areas = np.array(areas, dtype=np.float64)
    check("S6 分块覆盖", abs(areas.sum() - w * h) < 1e-6 and len(areas) == blocks,
          "%dx%d 块, 覆盖 %d px" % (bx, by, int(areas.sum())))

    # 典型素材：20% 的块在动（D 均匀 0..10），其余静止
    rng = np.random.default_rng(7)
    moving = rng.random(blocks) < 0.20
    need = np.ones(blocks)
    need[moving] = np.ceil(rng.random(int(moving.sum())) * 10.0)
    avg = float((need * areas).sum() / areas.sum())
    check("S6 典型 avgM", 1.2 < avg < 3.5, "avgM = %.2f" % avg)

    # costCeiling 生效：avg 被压到 ceiling 附近，且只降精度不降模糊量。
    # 注意：每块至少 1 个样本 => avg >= 1，单次比例缩放无法精确落到 ceiling，
    # 实测最多超出 6%（下面按 7% 容差断言，并在 RESEARCH.md 里如实记录）。
    for ceiling in (1.5, 2.0, 10.0, 20.0):
        factor = min(1.0, ceiling / avg)
        scaled = np.maximum(1.0, np.floor(need * factor))
        avg2 = float((scaled * areas).sum() / areas.sum())
        ok = avg2 <= ceiling * 1.07
        check("S6 ceiling=%.1f" % ceiling, ok,
              "avgM %.2f -> %.2f (factor %.3f, 最大块 m=%d)" %
              (avg, avg2, factor, int(scaled.max())))

    # 最坏情况：全屏快摇 D=48，ceiling=10
    need_bad = np.full(blocks, 48.0)
    avg_bad = float((need_bad * areas).sum() / areas.sum())
    factor = min(1.0, 10.0 / avg_bad)
    scaled = np.maximum(1.0, np.minimum(MAX_SAMPLES, np.floor(need_bad * factor)))
    avg_bad2 = float((scaled * areas).sum() / areas.sum())
    check("S6 最坏情况被夹住", avg_bad2 <= 10.0 * 1.07,
          "D=48 avgM %.0f -> %.1f (m=%d, 阶梯 %.1f px)" %
          (avg_bad, avg_bad2, int(scaled[0]), 48.0 / scaled[0]))


# --------------------------------------------------------------------------
def main():
    print("PixelLift M6 / MotionBlurCore 数值验证")
    print("numpy %s / python %s" % (np.__version__, sys.version.split()[0]))
    print("-" * 78)
    s1_window_geometry()
    s2_weights()
    s3_linear_light()
    s4_lut()
    s5_sampling()
    s6_cost()
    print("-" * 78)
    if FAIL:
        print("FAILED: %s" % ", ".join(FAIL))
        return 1
    print("PASS: 快门窗几何 / 权重 / 线性光 / sRGB LUT / 采样密度 / 成本模型 全部断言通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
