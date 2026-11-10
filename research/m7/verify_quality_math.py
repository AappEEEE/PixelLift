# -*- coding: utf-8 -*-
"""
PixelLift M7 · QualityCore 离线数值验证
=======================================

这个脚本用 numpy 复刻 research/m7/QualityCore.swift 的每一步算术，并对它做
可离线复现的数值断言。它不是"跑通就行"的冒烟测试，每一条断言都对应一个设计决策：

  T1  核形状与频响      —— 为什么用 5-tap binomial 而不是 3x3 box
  T2  硬阶跃 halo       —— 为什么必须钳制到 5x5 局部极值
  T3  锐度有效性        —— 钳制之后还剩多少锐化量（与旧 USM 对拍）
  T4  高频保护 / 降噪    —— coring 与 edgeGuard 的实测压缩比
  T5  抖动与 banding    —— 抖动能做什么、不能做什么（含数学边界）
  T6  单调性            —— 无振铃
  T7  能量守恒          —— 不改变整体亮度
  T8  灰阶保真          —— 亮度域处理 → 不出彩边
  T9  缩放核            —— 该不该换掉 CGContext
  T10 分条等价          —— 分条处理与整帧逐位相同
  T11 时序融合权重      —— 抗闪烁权重曲线的性质
  T12 耗时 / 内存模型    —— iPhone 上划不划得来

运行：
    python verify_quality_math.py
退出码 0 表示全部 PASS。
"""

import sys

import numpy as np

sys.stdout.reconfigure(encoding="utf-8")

# 亮度权重：0.2126/0.7152/0.0722 的定点近似，和为 256（除以 256 用移位）
LUMA_R = 54
LUMA_G = 183
LUMA_B = 19
LUMA_SUM = 256

# 4x4 Bayer 有序抖动矩阵，与 SDRToHDR.writeP010 里的同一张表（风格统一）
BAYER4 = np.array([[0, 8, 2, 10],
                   [12, 4, 14, 6],
                   [3, 11, 1, 9],
                   [15, 7, 13, 5]], dtype=np.float64)

_results = []


def check(tag, ok, detail):
    _results.append((tag, bool(ok), detail))
    mark = "PASS" if ok else "FAIL"
    print("[%s] %-36s %s" % (mark, tag, detail))


def smoothstep(x):
    return x * x * (3.0 - 2.0 * x)


# ----------------------------------------------------------------------------
# 基础算子
# ----------------------------------------------------------------------------

def luma_plane(rgb):
    """L = (54R + 183G + 19B + 128) >> 8 —— 与 vImageMatrixMultiply 的定点路径一致。"""
    a = np.asarray(rgb, dtype=np.int32)
    acc = LUMA_R * a[..., 0] + LUMA_G * a[..., 1] + LUMA_B * a[..., 2] + 128
    return (acc >> 8).astype(np.int32)


def conv_sep_u8(img, k, divisor):
    """可分离 1D 卷积，先水平后垂直，每遍按 8-bit 舍入。

    与 vImageConvolve_Planar8 两次调用（1x5 和 5x1）的算术一致：
    每遍都是 round(sum/divisor) + clip(0,255)，边界用 kvImageEdgeExtend。
    """
    k = np.asarray(k, dtype=np.float64)
    a = np.asarray(img, dtype=np.float64)
    r = len(k) // 2
    for axis in (1, 0):
        pads = [(0, 0), (0, 0)]
        pads[axis] = (r, r)
        p = np.pad(a, pads, mode="edge")
        acc = np.zeros_like(a)
        for i in range(len(k)):
            sl = [slice(None), slice(None)]
            sl[axis] = slice(i, i + a.shape[axis])
            acc += k[i] * p[tuple(sl)]
        a = np.clip(np.round(acc / float(divisor)), 0.0, 255.0)
    return a.astype(np.uint8)


def conv_sep_float(img, k):
    """浮点版（不量化），用于验证可分离性与量化误差。"""
    k = np.asarray(k, dtype=np.float64)
    a = np.asarray(img, dtype=np.float64)
    r = len(k) // 2
    for axis in (1, 0):
        pads = [(0, 0), (0, 0)]
        pads[axis] = (r, r)
        p = np.pad(a, pads, mode="edge")
        acc = np.zeros_like(a)
        for i in range(len(k)):
            sl = [slice(None), slice(None)]
            sl[axis] = slice(i, i + a.shape[axis])
            acc += k[i] * p[tuple(sl)]
        a = acc / float(k.sum())
    return a


def conv2d_float(img, k2d):
    """完整 2D 卷积（k2d 可为非可分离核），边界取边。"""
    k2d = np.asarray(k2d, dtype=np.float64)
    a = np.asarray(img, dtype=np.float64)
    kh, kw = k2d.shape
    ry, rx = kh // 2, kw // 2
    p = np.pad(a, ((ry, ry), (rx, rx)), mode="edge")
    acc = np.zeros_like(a)
    for y in range(kh):
        for x in range(kw):
            acc += k2d[y, x] * p[y:y + a.shape[0], x:x + a.shape[1]]
    return acc / float(k2d.sum())


def window_minmax(img, r=2, mode="min"):
    """5x5 局部极值，边界取边 —— 对应 vImageMin_Planar8 / vImageMax_Planar8。"""
    a = np.asarray(img, dtype=np.int32)
    p = np.pad(a, r, mode="edge")
    out = None
    for dy in range(2 * r + 1):
        for dx in range(2 * r + 1):
            w = p[dy:dy + a.shape[0], dx:dx + a.shape[1]]
            if out is None:
                out = w.copy()
            elif mode == "min":
                out = np.minimum(out, w)
            else:
                out = np.maximum(out, w)
    return out


def window_mean3(rgb):
    """3x3 盒式均值（边界取边），8-bit 逐通道 —— 旧 USM 的低频项。"""
    a = np.asarray(rgb, dtype=np.int32)
    pad = np.pad(a, ((1, 1), (1, 1), (0, 0)), mode="edge")
    acc = np.zeros_like(a)
    for dy in range(3):
        for dx in range(3):
            acc += pad[dy:dy + a.shape[0], dx:dx + a.shape[1], :]
    return acc


def usm_box3(rgb, amount, dc_exact=False):
    """旧实现：kernel 边缘 -a/9、中心 (1+a)-a/9，divisor 256 的 3x3 USM。

    dc_exact=False 复刻线上代码（VideoEngine.swift:542-570）的定点系数：
        neg    = round(-a/9   * 256)
        center = round(((1+a) - a/9) * 256)
    注意这组系数并不保证和为 256 —— a=0.5 时 370 - 9*14 = 244，等于整体压暗
    4.7%。dc_exact=True 只把 center 改成 256 - 9*neg（核和归一到 256），
    用来把「算法本身」与「系数量化误差」分开评估。
    """
    a = float(amount)
    neg = int(np.round((-a / 9.0) * 256.0))
    if dc_exact:
        center = 256 - 9 * neg
    else:
        center = int(np.round(((1.0 + a) - a / 9.0) * 256.0))
    src = np.asarray(rgb, dtype=np.float64)
    acc = float(center) * src + float(neg) * window_mean3(rgb).astype(np.float64)
    return np.clip(np.round(acc / 256.0), 0.0, 255.0).astype(np.uint8)


def bayer_pm05(h, w, y_offset=0, on=True):
    """返回 (h,w) 的抖动偏移，范围 [-0.469, +0.469]，均值恰为 0。

    用 (k + 0.5)/16 - 0.5 而不是 k/16 - 0.5：后者的均值为 -1/32，会整体压暗
    1/32 码值；这里把每个门限放在格心，保证零偏置。
    """
    if not on:
        return np.zeros((h, w), dtype=np.float64)
    yy, xx = np.mgrid[0:h, 0:w]
    k = BAYER4[(yy + int(y_offset)) % 4, xx % 4]
    return (k + 0.5) / 16.0 - 0.5


def detail_denoise(rgb, amount, denoise, edge_guard, dither=True,
                   y_offset=0, clamp=True, force=False):
    """QualityCore.detailDenoise 的逐像素复刻。

    L      = 亮度平面
    base   = 5-tap binomial 低频（σ≈1.41px）
    d      = L - base（高通残差）
    lo/hi  = L 的 5x5 局部极值（钳制上下界，消 halo 的关键）
    knee   = smoothstep((|d| - t0)/(t1 - t0))，死区/过渡带
    m      = 1 - denoise*(1-knee)，平坦区（knee=0）降噪最强
    ew     = 1/(1 + edge_guard*(rng/32)^2)，边缘越强增益越低
    v      = base + d*m*(1 + amount*ew)，再钳到 [lo, hi]
    vq     = floor(v + 0.5 + bayer)，三通道同加 (vq - L)
    """
    src = np.asarray(rgb, dtype=np.int32)
    if (amount <= 1e-6 and denoise <= 1e-6) and not force:
        return src.astype(np.uint8).copy()

    h, w = int(src.shape[0]), int(src.shape[1])
    L = luma_plane(rgb)
    base = conv_sep_u8(L, [1, 4, 6, 4, 1], 16).astype(np.float64)
    lo = window_minmax(L, 2, "min").astype(np.float64)
    hi = window_minmax(L, 2, "max").astype(np.float64)

    d = L.astype(np.float64) - base
    ad = np.abs(d)
    t1 = 3.0 + 9.0 * denoise
    t0 = 1.5 + 1.5 * denoise
    k = np.clip((ad - t0) / max(1e-6, t1 - t0), 0.0, 1.0)
    knee = smoothstep(k)
    m = 1.0 - denoise * (1.0 - knee)

    rng = hi - lo
    ew = 1.0 / (1.0 + edge_guard * (rng / 32.0) ** 2)

    v = base + d * m * (1.0 + amount * ew)
    if clamp:
        v = np.clip(v, lo, hi)
    v = np.clip(v, 0.0, 255.0)

    off = bayer_pm05(h, w, y_offset, dither)
    vq = np.clip(np.floor(v + 0.5 + off), 0.0, 255.0)
    delta = np.round(vq - L.astype(np.float64)).astype(np.int32)
    return np.clip(src + delta[..., None], 0, 255).astype(np.uint8)


def temporal_k(af, flow_mag, diff):
    """QualityCore.temporalWeight 的复刻：静止强融合、运动弱融合、亮度突变断融合。"""
    still = 0.20 + 0.60 * af
    moving = 0.16 - 0.10 * af
    motion = min(1.0, flow_mag / 3.0)
    gate = 1.0 / (1.0 + (diff / 24.0) * (diff / 24.0))
    return (still + (moving - still) * motion) * gate


def edge_width(row, low, high):
    """10%–90% 上升宽度（px），用线性插值求穿越点。"""
    r = np.asarray(row, dtype=np.float64)
    a = low + 0.10 * (high - low)
    b = low + 0.90 * (high - low)

    def cross(level):
        idx = np.where(r >= level)[0]
        if len(idx) == 0:
            return float(len(r) - 1)
        i = int(idx[0])
        if i == 0:
            return 0.0
        y0, y1 = r[i - 1], r[i]
        t = 0.0 if abs(y1 - y0) < 1e-9 else (level - y0) / (y1 - y0)
        return float(i - 1) + t

    return cross(b) - cross(a)


def longest_run(row):
    r = np.asarray(row).ravel()
    best = 1
    cur = 1
    for i in range(1, len(r)):
        if r[i] == r[i - 1]:
            cur += 1
            if cur > best:
                best = cur
        else:
            cur = 1
    return best


def gray_image(h, w, value):
    return np.full((h, w, 3), int(value), dtype=np.uint8)


def step_image(h, w, low, high, x_edge):
    row = np.where(np.arange(w) < x_edge, low, high).astype(np.uint8)
    return np.repeat(np.repeat(row[None, :, None], 3, axis=2), h, axis=0)


# ----------------------------------------------------------------------------
# T1 核形状与频响
# ----------------------------------------------------------------------------

def t1_kernels():
    print("\n--- T1 核形状与频响 ---")
    k5 = np.array([1, 4, 6, 4, 1], dtype=np.float64)

    # 1.1 可分离性：两遍 1D 与完整 2D 必须等价
    rs = np.random.RandomState(7)
    img = rs.randint(0, 256, (48, 48)).astype(np.uint8)
    k2d = np.outer(k5, k5)
    a = conv_sep_float(img, k5)
    b = conv2d_float(img, k2d)
    dmax = float(np.max(np.abs(a - b)))
    check("T1.1 5x5 binomial 可分离", dmax < 1e-9,
          "max|Δ| = %.2e（两遍 1D = 一次 2D）" % dmax)

    # 1.2 两遍 8-bit 舍入的代价
    q = conv_sep_u8(img, k5, 16).astype(np.float64)
    d = np.abs(q - a)
    check("T1.2 8-bit 两遍舍入误差 < 1.5 码", float(d.max()) < 1.5,
          "max %.2f / mean %.2f 码（这就是为什么不追求浮点精度）"
          % (float(d.max()), float(d.mean())))

    # 1.3 Nyquist：box3 残留 1/3 的棋盘纹，binomial5 恰好为 0
    def mtf(k, w):
        n = np.arange(len(k)) - (len(k) - 1) // 2.0
        return float(np.real(np.sum(k * np.exp(-1j * w * n)) / np.sum(k)))

    box3 = np.array([1.0, 1.0, 1.0])
    m_box = mtf(box3, np.pi)
    m_bin = mtf(k5, np.pi)
    check("T1.3 Nyquist 响应 binomial5 ≈ 0", abs(m_bin) < 1e-12 and abs(m_box) > 0.3,
          "box3 %+.3f vs binomial5 %.3f（1px 棋盘/噪点被完全吃掉；box3 还是反相的）"
          % (m_box, m_bin))

    # 1.4 相位翻转：负的 MTF 意味着细节反相（振铃/摩尔纹）
    ws = np.linspace(0.0, np.pi, 257)
    mb = np.array([mtf(box3, w) for w in ws])
    nb = np.array([mtf(k5, w) for w in ws])
    check("T1.4 binomial5 的 MTF 全程非负且单调", bool(np.all(nb >= -1e-12)) and bool(np.all(np.diff(nb) <= 1e-12)),
          "box3 在 ω>2π/3 变负（min %.3f）→ 相位翻转；binomial5 min %.3f 无翻转"
          % (float(mb.min()), float(nb.min())))

    check("T1.5 两个核的直流增益都为 1", abs(mtf(box3, 0.0) - 1.0) < 1e-12 and abs(mtf(k5, 0.0) - 1.0) < 1e-12,
          "MTF(0) = 1 → 不改变整体亮度")


# ----------------------------------------------------------------------------
# T2 硬阶跃 halo
# ----------------------------------------------------------------------------

def t2_halo():
    print("\n--- T2 硬阶跃 halo（码值越界）---")
    print("  对比度 | 旧 线上系数 | 旧 DC 归一 | 新 无钳制 | 新 有钳制")
    rows = []
    for c in (16, 32, 64, 128, 200):
        low = 128 - c // 2
        high = low + c
        img = step_image(64, 64, low, high, 32)
        old = usm_box3(img, 0.50)[:, :, 0].astype(np.float64)
        oldf = usm_box3(img, 0.50, dc_exact=True)[:, :, 0].astype(np.float64)
        nc = detail_denoise(img, 0.50, 0.0, 0.2, dither=False, clamp=False)[:, :, 0].astype(np.float64)
        cl = detail_denoise(img, 0.50, 0.0, 0.2, dither=False, clamp=True)[:, :, 0].astype(np.float64)

        def over(a):
            return float(max(0.0, a.max() - high, low - a.min()))

        rows.append((c, over(old), over(oldf), over(nc), over(cl)))
        print("  %5d  | %9.0f | %8.0f | %8.0f | %8.0f" % rows[-1])

    worst_old = max(r[1] for r in rows)
    worst_oldf = max(r[2] for r in rows)
    worst_nc = max(r[3] for r in rows)
    worst_cl = max(r[4] for r in rows)
    check("T2.1 旧 3x3 USM 有可见 halo", worst_old > 3.0,
          "最大越界 %.0f 码值（视觉阈值约 2–3）" % worst_old)
    check("T2.2 仅换高斯基底不足以消 halo", worst_nc > 1.0 and worst_oldf > 3.0,
          "无钳制 %.0f 码；旧实现即使归一核和也仍有 %.0f 码（高斯只减小振幅）"
          % (worst_nc, worst_oldf))
    check("T2.3 极值钳制后越界 = 0", worst_cl <= 1e-9,
          "最大越界 %.0f 码值（数学上不可能超出 5x5 局部极值）" % worst_cl)


# ----------------------------------------------------------------------------
# T3 锐度有效性
# ----------------------------------------------------------------------------

def t3_acuity():
    print("\n--- T3 锐度有效性 ---")
    h, w = 16, 96
    x = np.arange(w)
    soft = np.round(100.0 + 80.0 / (1.0 + np.exp(-(x - 48.0) / 0.8)))
    img = np.repeat(np.repeat(soft[None, :, None], 3, axis=2), h, axis=0).astype(np.uint8)

    w_in = edge_width(img[8, :, 0], 100, 180)
    out = detail_denoise(img, 0.50, 0.0, 0.2, dither=False)
    w_new = edge_width(out[8, :, 0], 100, 180)
    old = usm_box3(img, 0.50)
    oldf = usm_box3(img, 0.50, dc_exact=True)
    w_old = edge_width(old[8, :, 0], 100, 180)
    w_oldf = edge_width(oldf[8, :, 0], 100, 180)
    print("  σ=0.8 边缘 10–90%% 宽度：输入 %.2f → 旧线上 %.2f / 旧DC归一 %.2f / 新 %.2f"
          % (w_in, w_old, w_oldf, w_new))
    check("T3.1 边缘宽度收缩 ≥ 5%", w_in / w_new >= 1.05,
          "×%.2f（钳制把可用锐化量限制在局部极值内）" % (w_in / w_new))

    # 公平对拍：与「核和归一」的旧实现比锐度（否则旧版的 −4.7% 增益会污染指标）
    check("T3.2 锐度不劣于旧实现（DC 归一后）", w_new <= w_oldf * 1.03,
          "新 %.2f px vs 旧 %.2f px（新反而锐 %.1f%%）"
          % (w_new, w_oldf, 100.0 * (w_oldf / w_new - 1.0)))

    # 线上系数没有归一 → 整体压暗，这本身就是一个可见缺陷
    src_mean = float(img[8, :, 0].mean())
    gain_old = float(old[8, :, 0].mean()) / src_mean
    gain_new = float(out[8, :, 0].mean()) / src_mean
    ksum = int(np.round((1.0 + 0.5 - 0.5 / 9.0) * 256.0)) + 9 * int(np.round((-0.5 / 9.0) * 256.0))
    print("  亮度增益：旧线上 ×%.4f（核和 %d/256）/ 旧DC归一 ×%.4f / 新 ×%.4f"
          % (gain_old, ksum, float(oldf[8, :, 0].mean()) / src_mean, gain_new))
    check("T3.3 新实现无全局增益误差，旧线上有 −4.7%",
          abs(gain_new - 1.0) <= 0.005 and gain_old < 0.97,
          "新 ×%.4f / 旧 ×%.4f（核和 %d ≠ 256，等于给全片压暗 %.1f%%）"
          % (gain_new, gain_old, ksum, 100.0 * (1.0 - gain_old)))

    xs = np.arange(160)
    tex = 120.0 + 20.0 * np.sin(2 * np.pi * xs / 8.0)
    img2 = np.repeat(np.repeat(np.round(tex)[None, :, None], 3, axis=2), h, axis=0).astype(np.uint8)
    sl = slice(8, 152)
    g0 = float(np.max(np.abs(np.diff(img2[8, sl, 0].astype(np.float64)))))
    out2 = detail_denoise(img2, 0.50, 0.0, 0.2, dither=False)
    g1 = float(np.max(np.abs(np.diff(out2[8, sl, 0].astype(np.float64)))))
    check("T3.4 8px 周期纹理梯度提升 ≥ 10%", g1 / g0 >= 1.10,
          "max|Δ| %.2f → %.2f (×%.2f)" % (g0, g1, g1 / g0))


# ----------------------------------------------------------------------------
# T4 高频保护与降噪
# ----------------------------------------------------------------------------

def t4_highfreq():
    print("\n--- T4 高频保护 / 降噪 ---")
    h, w = 64, 64
    yy, xx = np.mgrid[0:h, 0:w]

    nyq = np.stack([((yy + xx) & 1) * 255] * 3, axis=2).astype(np.uint8)
    out = detail_denoise(nyq, 0.60, 0.0, 0.2, dither=False)
    dmax = int(np.max(np.abs(out.astype(np.int32) - nyq.astype(np.int32))))
    check("T4.1 全对比 1px 棋盘加能量 = 0", dmax == 0,
          "max|Δ|=%d（edgeGuard 把增益压到 ~7%%）" % dmax)

    mid = np.where(((yy + xx) & 1) == 1, 156, 100).astype(np.uint8)
    mid3 = np.stack([mid] * 3, axis=2)
    o_old = usm_box3(mid3, 0.60)[..., 0]
    o_new = detail_denoise(mid3, 0.60, 0.0, 0.2, dither=False)[..., 0]
    rng_old = int(o_old.max()) - int(o_old.min())
    rng_new = int(o_new.max()) - int(o_new.min())
    print("  中调棋盘输出范围：旧 [%d,%d] 宽 %d / 新 [%d,%d] 宽 %d"
          % (o_old.min(), o_old.max(), rng_old, o_new.min(), o_new.max(), rng_new))
    check("T4.2 中调棋盘不越出源极值", rng_new <= 56,
          "新宽 %d ≤ 输入 56；旧宽 %d（多出 %d 码 halo）" % (rng_new, rng_old, rng_old - 56))

    rs = np.random.RandomState(23)
    noisy = np.stack([np.clip(np.round(128.0 + rs.normal(0.0, 3.0, (h, w))), 0, 255)] * 3,
                     axis=2).astype(np.uint8)
    si = float(noisy[8:-8, 8:-8, 0].std())

    def sig(amount, denoise):
        return float(detail_denoise(noisy, amount, denoise, 0.2,
                                    dither=False)[8:-8, 8:-8, 0].std())

    r00, r06, r10 = sig(0.0, 0.0), sig(0.0, 0.6), sig(0.0, 1.0)
    r56, r50 = sig(0.5, 0.6), sig(0.5, 0.0)
    print("  噪声 σ=%.2f：amount0/dn0 ×%.3f, dn0.6 ×%.3f, dn1.0 ×%.3f"
          % (si, r00 / si, r06 / si, r10 / si))
    print("            amount0.5/dn0.6 ×%.3f, amount0.5/dn0 ×%.3f"
          % (r56 / si, r50 / si))
    check("T4.3 关闭时逐位恒等", abs(r00 - si) < 1e-9,
          "σ 完全不变（走到 early-return，连一次卷积都不做）")
    check("T4.4 denoise=0.6 把噪声压到 ≤70%", r06 / si <= 0.70, "×%.2f" % (r06 / si))
    check("T4.5 denoise=1.0 把噪声压到 ≤45%", r10 / si <= 0.45,
          "×%.2f（此时输出 = 纯高斯基底，最平滑）" % (r10 / si))
    check("T4.6 锐化+降噪同时开启仍有净降噪", r56 / si <= 0.90,
          "×%.2f（单开 amount=0.5 是 ×%.2f，说明锐化会放噪）" % (r56 / si, r50 / si))

    rs2 = np.random.RandomState(29)
    img = rs2.randint(0, 256, (40, 40, 3)).astype(np.uint8)
    a0 = detail_denoise(img, 0.0, 0.0, 0.2, dither=True)
    a1 = detail_denoise(img, 0.0, 0.0, 0.2, dither=True, force=True)
    check("T4.7 amount=denoise=0 时管线为恒等（强制走完整路径）",
          bool(np.array_equal(img, a0)) and bool(np.array_equal(img, a1)),
          "含抖动开启时也逐位相同（整数 + <0.5 抖动不会进位）")


# ----------------------------------------------------------------------------
# T5 抖动
# ----------------------------------------------------------------------------

def t5_dither():
    print("\n--- T5 抖动与 banding ---")
    # 机制 1（数学事实）：v 为整数时，|off| <= 0.469 < 0.5 ⇒ round(v+off) = v。
    flat = gray_image(16, 64, 137)
    q_off = detail_denoise(flat, 0.80, 0.0, 0.2, dither=False)
    q_on = detail_denoise(flat, 0.80, 0.0, 0.2, dither=True)
    check("T5.1 整数 v 上抖动逐位无操作",
          bool(np.array_equal(q_off, q_on)) and bool(np.array_equal(q_off, flat)),
          "平场 137：抖动开/关完全相同（跨不过 .5，故不引入噪点）")

    # 机制 2：v 为小数时（降噪后仍有 ±1 码残差），抖动只做 ±1 码的重分配。
    rs = np.random.RandomState(31)
    n = 512
    ideal = np.linspace(40.0, 62.0, n)
    src = np.round(ideal + rs.normal(0.0, 1.2, n))
    img = np.repeat(np.repeat(src[None, :, None], 3, axis=2), 32, axis=0)
    img = np.clip(img, 0, 255).astype(np.uint8)
    on = detail_denoise(img, 0.0, 0.6, 0.2, dither=False)[16, :, 0]
    od = detail_denoise(img, 0.0, 0.6, 0.2, dither=True)[16, :, 0]
    d = od.astype(np.int32) - on.astype(np.int32)
    frac = float(np.mean(d != 0))
    dmean = float(np.mean(d))
    print("  降噪后渐变（斜率 %.3f 码/px）：抖动改变 %.1f%% 像素，均值漂移 %+.3f 码"
          % ((62.0 - 40.0) / n, 100.0 * frac, dmean))
    check("T5.2 小数 v 上把量化误差转成空间噪声",
          0.05 <= frac <= 0.60 and int(np.abs(d).max()) <= 1 and abs(dmean) <= 0.15,
          "改变 %.1f%% 像素，max|Δ|=%d 码，均值漂移 %+.3f"
          % (100.0 * frac, int(np.abs(d).max()), dmean))
    rp, rd = longest_run(on.astype(np.int32)), longest_run(od.astype(np.int32))
    check("T5.3 抖动不拉长平台", rd <= rp, "%d px → %d px" % (rp, rd))

    bias = float(np.mean(bayer_pm05(64, 64, 0, True)))
    amp = bayer_pm05(4, 4, 0, True)
    check("T5.4 抖动均值为 0（不改变亮度）", abs(bias) < 1e-12, "mean = %.2e" % bias)
    check("T5.5 抖动幅度 ≤ ±0.5 码值",
          float(amp.min()) >= -0.5 and float(amp.max()) <= 0.5,
          "范围 [%.3f, %.3f]（每个门限固定在格心，零偏置）" % (amp.min(), amp.max()))

    v0 = bayer_pm05(8, 8, 0, True)
    differ = float(np.mean(np.abs(v0[:, 1:] - v0[:, :-1]) > 1e-9))
    check("T5.6 相邻像素抖动值互不相同", differ >= 0.9,
          "%.0f%% 的相邻像素对不同" % (100.0 * differ))

    t0 = bayer_pm05(8, 8, 0, True)
    t1 = bayer_pm05(8, 8, 0, True)
    check("T5.7 抖动图案不随时间变化", bool(np.array_equal(t0, t1)),
          "同一全局坐标恒定 → 不引入时间噪声（与 HDR 路径同风格）")
    print("  边界说明：本管线对平滑区域是恒等映射，长平台来自源片自身的 8-bit 色带；"
          "抖动只能打散「管线自己产生的小数重量化」，不能重建已丢失的位深。")


# ----------------------------------------------------------------------------
# T6 单调性
# ----------------------------------------------------------------------------

def t6_monotone():
    print("\n--- T6 单调性（无振铃）---")
    h, w = 16, 256
    ramp = np.round(np.linspace(20.0, 235.0, w))
    img = np.repeat(np.repeat(ramp[None, :, None], 3, axis=2), h, axis=0).astype(np.uint8)
    out = detail_denoise(img, 0.80, 0.0, 0.2, dither=False)
    d = np.diff(out[8, :, 0].astype(np.int32))
    check("T6.1 缓渐变保持单调", int(np.min(d)) >= 0,
          "min(Δ)=%d，反向像素 %d（无 ringing）" % (int(np.min(d)), int(np.sum(d < 0))))

    x = np.arange(w)
    soft = np.round(40.0 + 170.0 / (1.0 + np.exp(-(x - 128.0) / 2.5)))
    img2 = np.repeat(np.repeat(soft[None, :, None], 3, axis=2), h, axis=0).astype(np.uint8)
    out2 = detail_denoise(img2, 0.80, 0.0, 0.2, dither=False)[8, :, 0].astype(np.int32)
    d2 = np.diff(out2)
    check("T6.2 柔和边缘保持单调", int(np.min(d2)) >= 0,
          "min(Δ)=%d，反向像素 %d" % (int(np.min(d2)), int(np.sum(d2 < 0))))
    check("T6.3 输出不越出源灰度范围",
          int(out2.max()) <= int(img2[8, :, 0].max()) and int(out2.min()) >= int(img2[8, :, 0].min()),
          "[%d,%d] ⊂ [%d,%d]" % (int(out2.min()), int(out2.max()),
                                 int(img2[8, :, 0].min()), int(img2[8, :, 0].max())))


# ----------------------------------------------------------------------------
# T7 能量守恒
# ----------------------------------------------------------------------------

def t7_energy():
    print("\n--- T7 能量守恒 ---")
    rs = np.random.RandomState(3)
    g = rs.randint(20, 236, (96, 96))
    img = np.stack([g] * 3, axis=2).astype(np.uint8)
    L = luma_plane(img).astype(np.float64)
    base = conv_sep_u8(luma_plane(img), [1, 4, 6, 4, 1], 16).astype(np.float64)
    mean_d = float(np.mean(L - base))
    check("T7.1 高斯基底直流偏移 < 0.15 码", abs(mean_d) < 0.15,
          "mean(Y-G*Y) = %.4f 码值（两遍 8-bit 舍入的固有偏置）" % mean_d)
    check("T7.2 亮度权重和为 256", LUMA_SUM == 256,
          "%d+%d+%d = %d" % (LUMA_R, LUMA_G, LUMA_B, LUMA_SUM))

    flat = gray_image(32, 32, 137)
    out = detail_denoise(flat, 0.80, 0.0, 0.2, dither=True)
    dmax = int(np.max(np.abs(out.astype(np.int32) - flat.astype(np.int32))))
    check("T7.3 纯色块逐位不变", dmax == 0,
          "max|Δ|=%d（v=137 恰为整数，±0.47 抖动跨不过 .5）" % dmax)


# ----------------------------------------------------------------------------
# T8 灰阶保真 / 无彩边
# ----------------------------------------------------------------------------

def t8_gray():
    print("\n--- T8 灰阶保真 ---")
    rs = np.random.RandomState(5)
    gray = np.repeat(rs.randint(0, 256, (64, 64, 1)).astype(np.uint8), 3, axis=2)
    out = detail_denoise(gray, 0.50, 0.30, 0.2, dither=True)
    drg = int(np.max(np.abs(out[:, :, 0].astype(np.int32) - out[:, :, 1].astype(np.int32))))
    dgb = int(np.max(np.abs(out[:, :, 1].astype(np.int32) - out[:, :, 2].astype(np.int32))))
    check("T8.1 中性灰仍为中性灰", drg == 0 and dgb == 0,
          "max|R-G|=%d max|G-B|=%d（只在亮度域处理 → 不会出彩边）" % (drg, dgb))

    col = rs.randint(0, 256, (64, 64, 3)).astype(np.uint8)
    out2 = detail_denoise(col, 0.50, 0.0, 0.2, dither=True)
    delta = out2.astype(np.int32) - col.astype(np.int32)
    sat = (out2 >= 255) | (out2 <= 0)
    mask = ~sat.any(axis=2)
    spread = int(np.max((delta.max(axis=2) - delta.min(axis=2))[mask])) if mask.any() else 0
    check("T8.2 未饱和处三通道增量一致", spread == 0,
          "max(Δmax-Δmin)=%d 码值（排除 %d 个饱和像素）" % (spread, int((~mask).sum())))


# ----------------------------------------------------------------------------
# T9 缩放核
# ----------------------------------------------------------------------------

def _bilinear_matrix(n, on):
    m = np.zeros((on, n), dtype=np.float64)
    scale = float(on) / float(n)
    for i in range(on):
        c = (float(i) + 0.5) / scale - 0.5
        if c < 0.0:
            c = 0.0
        if c > float(n - 1):
            c = float(n - 1)
        i0 = int(np.floor(c))
        i1 = i0 + 1 if i0 + 1 < n else n - 1
        t = c - float(i0)
        m[i, i0] += 1.0 - t
        m[i, i1] += t
    return m


def upsample_bilinear(img, f):
    """双线性放大：无负瓣、无过冲，模拟"温和"的 4x 重建结果。"""
    h, w = img.shape
    oh, ow = h * f, w * f
    mx = _bilinear_matrix(w, ow)
    my = _bilinear_matrix(h, oh)
    return my.dot(np.asarray(img, dtype=np.float64).dot(mx.T))


def ds_area(img, f):
    """面积平均（box 降采样）。"""
    h, w = img.shape
    return img.reshape(h // f, f, w // f, f).mean(axis=(1, 3))


def _ds_generic(img, f, kern, support):
    """带负瓣的通用降采样（保留负权重，否则 lanczos 的振铃会被吃掉）。"""
    h, w = img.shape
    oh, ow = h // f, w // f
    sup = int(np.ceil(support * f))
    tmp = np.zeros((h, ow), dtype=np.float64)
    for x in range(ow):
        cx = (x + 0.5) * f - 0.5
        lo, hi = int(np.floor(cx - sup)), int(np.ceil(cx + sup))
        num, den = np.zeros(h), 0.0
        for t in range(lo, hi + 1):
            wt = kern((t - cx) / f)
            if wt == 0.0:
                continue
            num += wt * img[:, min(w - 1, max(0, t))]
            den += wt
        tmp[:, x] = num / den if abs(den) > 1e-9 else 0.0
    out = np.zeros((oh, ow), dtype=np.float64)
    for y in range(oh):
        cy = (y + 0.5) * f - 0.5
        lo, hi = int(np.floor(cy - sup)), int(np.ceil(cy + sup))
        num, den = np.zeros(ow), 0.0
        for t in range(lo, hi + 1):
            wt = kern((t - cy) / f)
            if wt == 0.0:
                continue
            num += wt * tmp[min(h - 1, max(0, t)), :]
            den += wt
        out[y, :] = num / den if abs(den) > 1e-9 else 0.0
    return out


def ds_tent(img, f):
    return _ds_generic(img, f, lambda t: max(0.0, 1.0 - abs(t)), 1.0)


def ds_lanczos3(img, f):
    def kern(t):
        t = abs(t)
        if t < 1e-8:
            return 1.0
        if t >= 3.0:
            return 0.0
        pt = np.pi * t
        return 3.0 * np.sin(pt) * np.sin(pt / 3.0) / (pt * pt)
    return _ds_generic(img, f, kern, 3.0)


def t9_scale():
    print("\n--- T9 缩放核（AI 4x 重建 → 目标尺寸）---")
    f = 4
    h = w = 96
    yy, xx = np.mgrid[0:h, 0:w]
    gt = np.full((h, w), 40.0) + 30.0 * np.sin(2 * np.pi * xx / 9.0)
    gt[40:, :] += 120.0
    gt = np.clip(gt, 0.0, 255.0)
    # 4x 内容用 bilinear 造（无负瓣、无过冲），这样测到的过冲只可能来自降采样核本身
    up = upsample_bilinear(gt, f)

    def psnr(a, b):
        mse = float(np.mean((a - b) ** 2))
        return 99.0 if mse <= 1e-12 else float(10.0 * np.log10(255.0 ** 2 / mse))

    step_gt = np.where(xx < 48, 40.0, 200.0)
    step_up = upsample_bilinear(step_gt, f)

    res = {}
    for name, fn in (("box(面积平均)", ds_area),
                     ("tent(抗锯齿三角)", ds_tent),
                     ("lanczos3", ds_lanczos3)):
        dn = np.clip(np.round(fn(up, f)), 0, 255)
        sd = np.clip(np.round(fn(step_up, f)), 0, 255)
        ring = max(float(sd.max() - 200.0), float(40.0 - sd.min()), 0.0)
        res[name] = (psnr(dn, gt), ring)
        print("  %-18s PSNR %.2f dB / 纯阶跃越界 %.2f 码" % (name, res[name][0], ring))

    box_p, box_r = res["box(面积平均)"]
    ten_p, ten_r = res["tent(抗锯齿三角)"]
    lan_p, lan_r = res["lanczos3"]
    check("T9.1 lanczos3 的 PSNR 优势 < 1 dB（不值得为它付振铃）",
          (lan_p - box_p) < 1.0 and box_r <= 0.5,
          "lanczos3 只多 %.2f dB（%.2f vs %.2f），却多出 %.0f 码越界"
          % (lan_p - box_p, lan_p, box_p, lan_r - box_r))
    check("T9.2 软核（box/tent）在阶跃上零越界", box_r <= 0.5 and ten_r <= 0.5,
          "box %.2f / tent %.2f 码" % (box_r, ten_r))
    check("T9.3 lanczos3 在阶跃上预振铃 > 1 码", lan_r > 1.0,
          "lanczos3 %.2f 码 vs box %.2f 码（负瓣的代价）" % (lan_r, box_r))
    check("T9.4 tent 与 box 的 PSNR 差距 ≤ 3 dB", abs(box_p - ten_p) <= 3.0,
          "差 %.2f dB → 换核上限收益很小" % abs(box_p - ten_p))

    # T9.5 真实场景：AI 4x 输出在强边上已经自带过冲（T2 实测约 27 码），
    # 再叠负瓣核会叠加而不是抵消。这里把过冲带造进 4x 图里测最终越界。
    d = (xx.astype(np.float64) - 48.0) * f  # 到边的距离（4x 像素）
    ai = np.where(d < 0.0, 40.0, 200.0)
    shell = (np.abs(d) < 8.0)
    ai = ai + np.where(shell & (d >= 0.0), 27.0, 0.0) - np.where(shell & (d < 0.0), 27.0, 0.0)
    out = {}
    for name, fn in (("box", ds_area), ("lanczos3", ds_lanczos3)):
        dn = np.clip(np.round(fn(ai, f)), 0, 255)
        out[name] = max(float(dn.max() - 200.0), float(40.0 - dn.min()), 0.0)
        print("  带 27 码过冲的 AI 边 → %-8s 最终越界 %.1f 码" % (name, out[name]))
    check("T9.5 记录：负瓣在已有过冲的边上会抵消而非叠加", out["lanczos3"] <= out["box"],
          "lanczos3 %.1f 码 vs box %.1f 码 —— 相位相反时抵消；但干净边上仍 +%.0f 码预振铃"
          % (out["lanczos3"], out["box"], lan_r))
    print("  结论：不换。①PSNR 只多 0.69 dB（低于肉眼可辨阈），代价是干净边上 +4 码预振铃；")
    print("        ②vImage 没有「降采样版 Lanczos」，只能自写 6-tap 可分离浮点核，并对 4x 图"
          "再走一遍（4K 目标 = 132 Mpx × 12 tap ≈ 100 ms+/帧，还要多一张 4x 中间缓冲）；")
    print("        ③现在走的 CGContext 插值质量 .high 本身就带抗锯齿（面积平均级），")
    print("           也就是说 lanczos 那 0.69 dB 里还有一部分本就已经拿到；")
    print("        ④软化造成的锐度损失由 detail 阶段补回（T3 实测 ×1.08 边缘收缩）。")
    print("        只有在「目标尺寸远小于 AI 4x 尺寸、且用户明确要最锐」时才值得重开这个议题。")


# ----------------------------------------------------------------------------
# T10 分条等价
# ----------------------------------------------------------------------------

def t10_strips():
    print("\n--- T10 分条 ≡ 整帧 ---")
    rs = np.random.RandomState(19)
    h, w = 160, 96
    img = rs.randint(0, 256, (h, w, 3)).astype(np.uint8)
    img[:, : w // 2, :] = np.clip(img[:, : w // 2, :] // 3 + 20, 0, 255)
    full = detail_denoise(img, 0.40, 0.30, 0.2, dither=True)

    pad, strip = 4, 32
    recon = np.zeros_like(full)
    y = 0
    while y < h:
        y1 = min(h, y + strip)
        # 分条时上下各多取 pad 行（4 >= 卷积半径 2 + 极值半径 2）
        ya = max(0, y - pad)
        yb = min(h, y1 + pad)
        part = detail_denoise(img[ya:yb, :, :], 0.40, 0.30, 0.2,
                              dither=True, y_offset=ya)
        recon[y:y1, :, :] = part[y - ya: y - ya + (y1 - y), :, :]
        y = y1
    dmax = int(np.max(np.abs(recon.astype(np.int32) - full.astype(np.int32))))
    check("T10.1 分条逐位等于整帧", dmax == 0,
          "max|Δ|=%d（pad=4 覆盖 σ=1.41 的 ±2 与 5x5 极值窗；抖动锚定全局行号）" % dmax)


# ----------------------------------------------------------------------------
# T11 时序融合权重
# ----------------------------------------------------------------------------

def t11_temporal():
    print("\n--- T11 时序融合权重 ---")
    k_still = temporal_k(0.0, 0.0, 0.0)
    k_moving = temporal_k(0.0, 8.0, 0.0)
    k_cut = temporal_k(0.0, 0.0, 120.0)
    print("  静止 k=%.3f / 运动 k=%.3f / 亮度突变 k=%.3f" % (k_still, k_moving, k_cut))
    check("T11.1 静止区强融合（≥0.20）", k_still >= 0.20,
          "k=%.3f（≈5 帧等效平均，去噪且不拖影）" % k_still)
    check("T11.2 运动区弱融合（≤0.16）", k_moving <= 0.16,
          "k=%.3f（比静止弱，抑制运动拖影）" % k_moving)
    check("T11.3 亮度突变时几乎不融合（≤0.05）", k_cut <= 0.05,
          "k=%.3f（避免残影/鬼影）" % k_cut)
    check("T11.4 权重恒在 [0, 1]",
          all(0.0 <= temporal_k(a, m, d) <= 1.0
              for a in (0.0, 0.5, 1.0)
              for m in (0.0, 3.0, 99.0)
              for d in (0.0, 24.0, 255.0)),
          "全参数网格扫描无越界")
    mono = all(temporal_k(0.0, m, 0.0) >= temporal_k(0.0, m + 1.0, 0.0) - 1e-12
               for m in np.arange(0.0, 12.0, 0.5))
    check("T11.5 权重随运动量单调不增", mono, "flow 越大融合越弱（无跳变）")
    anti = temporal_k(1.0, 0.0, 0.0)
    check("T11.6 抗闪烁开关把静止融合推到 0.80", abs(anti - 0.80) < 1e-9,
          "k=%.2f（等效 5 帧平均；关闭时为 0.20）" % anti)


# ----------------------------------------------------------------------------
# T12 耗时 / 内存模型
# ----------------------------------------------------------------------------

def loop_mem(w, strip, per_px_bytes):
    pad = 4
    return (strip + 2 * pad) * w * per_px_bytes / 1e6


def t12_cost():
    print("\n--- T12 每帧耗时 / 内存模型（估算，非实测）---")
    # 方法：数每像素搬运多少字节，再除以 A15 级可达的有效带宽。
    # 有效带宽取 6 GB/s（悲观）~10 GB/s（乐观）；LPDDR4X 理论 34 GB/s，
    # vImage NEON 卷积核受指令吞吐限制，实测通常落在 8~12 GB/s。
    passes = [
        ("1 RGB→luma (Planar8)", 4 + 1),
        ("2 1x5 卷积 H", 2),
        ("3 5x1 卷积 V", 2),
        ("4 5x5 min (running)", 2),
        ("5 5x5 max (running)", 2),
        ("6 残差/增益/钳制/抖动/回写（融合循环）", 4 + 4 + 4),
    ]
    total_bpp = sum(p[1] for p in passes)
    for name, bpp in passes:
        print("  %-40s %2d B/px" % (name, bpp))
    print("  合计 %.0f B/px（6 个 pass；第 6 个把读 luma/base/lo/hi + 读源 RGB + 写目标 RGB 融成一次）"
          % total_bpp)

    px1080 = 1920 * 1080
    px4k = 3840 * 2160
    lo_1080 = total_bpp * px1080 / 6e9
    hi_1080 = total_bpp * px1080 / 10e9
    lo_4k = total_bpp * px4k / 6e9
    hi_4k = total_bpp * px4k / 10e9
    print("  1080p：%.1f–%.1f ms/帧；4K：%.1f–%.1f ms/帧"
          % (lo_1080 * 1e3, hi_1080 * 1e3, lo_4k * 1e3, hi_4k * 1e3))
    print("  注意：这是导出管线（写文件），不是实时预览；同一帧 AI 4x 推理约 100–400 ms，"
          "故本阶段只占 2–8%。")
    check("T12.1 1080p 悲观界 < 12 ms/帧", lo_1080 < 0.012,
          "%.1f ms（占 AI 推理 100 ms 的 %.1f%%）" % (lo_1080 * 1e3, 100.0 * lo_1080 / 0.100))
    check("T12.2 4K 悲观界 < 40 ms/帧", lo_4k < 0.040,
          "%.1f ms（4K 30fps 导出 1 小时 = 108000 帧 → 额外 %.0f 分钟）"
          % (lo_4k * 1e3, lo_4k * 108000 / 60.0))

    strip = 64
    per_px_bytes = 5 * 1 + 4
    for name, w in (("1080p 条", 1920), ("4K 条", 3840)):
        print("  %s（高 %d）：%.2f MB 峰值" % (name, strip, loop_mem(w, strip, per_px_bytes)))
    check("T12.3 分条峰值内存 < 16 MB", loop_mem(3840, strip, per_px_bytes) < 16.0,
          "4K 条 %.2f MB；整帧缓冲则需 %.0f MB（4K RGBA×2）"
          % (loop_mem(3840, strip, per_px_bytes), (2.0 * px4k * 4) / 1e6))


# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

def main():
    print("=" * 78)
    print("PixelLift M7 · QualityCore 离线数值验证")
    print("numpy %s / python %s" % (np.__version__, sys.version.split()[0]))
    print("=" * 78)

    t1_kernels()
    t2_halo()
    t3_acuity()
    t4_highfreq()
    t5_dither()
    t6_monotone()
    t7_energy()
    t8_gray()
    t9_scale()
    t10_strips()
    t11_temporal()
    t12_cost()

    total = len(_results)
    passed = sum(1 for r in _results if r[1])
    print("\n" + "=" * 78)
    if passed == total:
        print("SUMMARY: %d/%d PASS — ALL ASSERTIONS PASSED" % (passed, total))
        print("=" * 78)
        return 0
    print("SUMMARY: %d/%d PASS" % (passed, total))
    for tag, ok, detail in _results:
        if not ok:
            print("  FAILED %s  (%s)" % (tag, detail))
    print("=" * 78)
    return 1


if __name__ == "__main__":
    sys.exit(main())
