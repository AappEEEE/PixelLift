#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
PixelLift M7 鐢昏川鏍稿績 鈥斺�?绂荤嚎鏁板�奸獙璇?
鐢?numpy 閫愪綅澶嶅埢 QualityCore.swift 鐨勫畾鐐?娴�鐐硅繍绠楋紝瀵� 12 缁勫懡棰樺仛鏂�瑷�銆?鎵�鏈夊害閲忛兘鏄�銆岀浉瀵规瘮杈冦�嶏紙鏂?vs 鏃?/ 鏈?vs 鏃狅級锛屼笉渚濊禆鏄剧ず鍣ㄨ�傛劅銆?
  T1  鍙�鍒嗙�诲嵎绉�涓庢牳褰㈢姸锛氬彲鍒嗙�烩墶2D銆丯yquist 娉勬紡銆佸悇鍚戝悓鎬с�丏C 澧炵泭
  T2  纭�闃惰�?halo锛氭棫 3x3 USM vs 鏂版柟妗?vs 鍙栨秷閽冲埗
  T3  閿愬害鏈夋晥鎬э細鏌斿拰杈圭紭鐨?10鈥?0% 瀹藉害鏀剁缉 + 绾圭悊姊�搴︽彁鍗�
  T4  楂橀�戜繚鎶� / 闄嶅櫔锛歂yquist 妫嬬洏銆佸櫔澹版姂鍒跺�嶇巼銆佹亽绛夋�?  T5  鎶栧姩锛氭妸銆屾护娉㈡姽骞冲悗鍐嶉噺鍖栥�嶄骇鐢熺殑闀垮钩鍙版墦鏁?  T6  鍗曡皟鎬э細缂撴笎鍙樹笌鏌斿拰杈圭紭鏃犳尟閾?  T7  鑳介噺瀹堟亽锛欴C 鏃犲亸绉汇�佷寒搴︽潈閲嶅拰 256銆佺函鑹查�愪綅涓嶅彉
  T8  鐏伴樁淇濈湡锛氫腑鎬х伆浠嶄腑鎬с�佷笁閫氶亾澧為噺涓�鑷达紙涓嶄骇鐢熷僵杈癸級
  T9  缂╂斁鏍革細box / tent / lanczos3 鍦?4x 瓒呴噰鏍烽檷閲囨牱涓嬬殑 PSNR 涓庨�勬尟閾�
  T10 鍒嗘潯澶勭悊閫愪綅绛変簬鏁村抚澶勭悊
  T11 鏃跺簭铻嶅悎鏉冮噸锛氶潤姝㈠尯寮鸿瀺鍚堛�佽繍鍔ㄥ尯寮辫瀺鍚堛�佷寒搴︾獊鍙樿�╄�?  T12 姣忓抚鑰楁椂妯″瀷锛氭寜瀹炴祴鍍忕礌鍚炲悙浼扮畻 1080p / 4K 姣忓抚寮�閿�

杩愯�岋�?  C:\\Users\\ape\\.dsh\\dsh-runtimes\\dsh-primary-runtime\\dependencies\\python\\python.exe verify_quality_math.py
"""

import sys

import numpy as np

try:                                    # Windows 鎺у埗鍙伴粯璁?GBK锛屽己鍒?UTF-8 鎵嶈兘鐪嬩腑鏂?    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

np.set_printoptions(suppress=True, precision=6)

# ----------------------------------------------------------------------------
# 0. 甯搁噺锛堜笌 QualityCore.swift 涓�涓�瀵瑰簲锛?# ----------------------------------------------------------------------------

# 4x4 Bayer 绱㈠紩琛�锛屼�?SDRToHDR.writeP010 閲岄偅寮犻�愬瓧鐩稿悓
BAYER4 = np.array([0, 8, 2, 10,
                   12, 4, 14, 6,
                   3, 11, 1, 9,
                   15, 7, 13, 5], dtype=np.float64).reshape(4, 4)
BAYER_BIAS = 0.5          # (k + 0.5) / 16 - 0.5 鈫?鍧囧�肩簿纭�涓� 0

K3_BOX = np.array([1, 1, 1], dtype=np.float64)
K5_BIN = np.array([1, 4, 6, 4, 1], dtype=np.float64)

LUMA_R, LUMA_G, LUMA_B = 54, 183, 19
LUMA_SUM = LUMA_R + LUMA_G + LUMA_B          # 蹇呴』 = 256
EDGE_SCALE = 32.0                            # edgeGuard 褰掍竴鍖栧昂搴︼紙鐮佸�硷級

_results = []


def check(tag, ok, detail):
    _results.append((tag, bool(ok), detail))
    print("[%s] %-34s %s" % ("PASS" if ok else "FAIL", tag, detail))
    return ok


# ----------------------------------------------------------------------------
# 1. 鍩虹��绠楀瓙锛堝叏閮ㄥ�瑰簲涓�娆?vImage 璋冪敤锛?# ----------------------------------------------------------------------------

def conv_sep_float(img, k):
    """鍙�鍒嗙�讳竴缁存牳涓ら亶锛堟诞鐐癸級锛岃竟鐣屽�嶅�?= kvImageEdgeExtend銆?""
    k = np.asarray(k, dtype=np.float64)
    k = k / k.sum()
    r = len(k) // 2
    h, w = img.shape
    p = np.pad(img.astype(np.float64), r, mode="edge")
    tmp = np.zeros((h, w), dtype=np.float64)
    for i in range(len(k)):
        tmp += k[i] * p[r:r + h, i:i + w]
    p2 = np.pad(tmp, ((r, r), (0, 0)), mode="edge")
    out = np.zeros((h, w), dtype=np.float64)
    for i in range(len(k)):
        out += k[i] * p2[i:i + h, :]
    return out


def conv_sep_u8(img, k_int, divisor):
    """涓ら亶 8-bit 瀹氶暱鍗风Н锛屾瘡閬嶅洓鑸嶄簲鍏?= vImageConvolve_Planar8(divisor)銆?""
    h, w = img.shape
    k = np.asarray(k_int, dtype=np.int32)
    r = len(k) // 2
    p = np.pad(img.astype(np.int32), r, mode="edge")
    tmp = np.zeros((h, w), dtype=np.int32)
    for i in range(len(k)):
        tmp += k[i] * p[r:r + h, i:i + w]
    tmp = np.floor(tmp / divisor + 0.5).astype(np.int32)
    p2 = np.pad(tmp, ((r, r), (0, 0)), mode="edge")
    out = np.zeros((h, w), dtype=np.int32)
    for i in range(len(k)):
        out += k[i] * p2[i:i + h, :]
    out = np.floor(out / divisor + 0.5).astype(np.int32)
    return np.clip(out, 0, 255).astype(np.uint8)


def window_minmax(img, r=2):
    """(2r+1)^2 鐭╁舰缁撴瀯鍏冪殑鑵愯殌/鑶ㄨ儉 = vImageMin/Max_Planar8锛岃竟鐣屽�嶅埗銆?""
    h, w = img.shape
    p = np.pad(img.astype(np.int16), r, mode="edge")
    lo = np.full((h, w), 255, dtype=np.int16)
    hi = np.zeros((h, w), dtype=np.int16)
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            win = p[r + dy:r + dy + h, r + dx:r + dx + w]
            lo = np.minimum(lo, win)
            hi = np.maximum(hi, win)
    return lo, hi


def luma_plane(rgb):
    r = rgb[:, :, 0].astype(np.int32)
    g = rgb[:, :, 1].astype(np.int32)
    b = rgb[:, :, 2].astype(np.int32)
    return ((LUMA_R * r + LUMA_G * g + LUMA_B * b + 128) >> 8).astype(np.uint8)


def bayer_pm05(h, w, y_offset=0, on=True):
    """鍙犲姞鍦ㄦ诞鐐逛寒搴︿笂鐨勬姈鍔ㄩ」锛岃寖鍥?[-0.469, +0.469]锛?x4 鍐呭潎鍊间负 0銆?""
    if not on:
        return np.zeros((h, w), dtype=np.float64)
    yy = (np.arange(h)[:, None] + y_offset) & 3
    xx = np.arange(w)[None, :] & 3
    return (BAYER4[yy, xx] + BAYER_BIAS) / 16.0 - 0.5


def knee_curve(ad, t0, t1):
    """smoothstep 姝诲尯锛殀d|鈮�t0 鍒ゅ櫔澹帮紙0锛夛紝|d|鈮�t1 鍒ょ粏鑺傦紙1锛夈�?""
    x = np.clip((ad - t0) / max(1e-6, (t1 - t0)), 0.0, 1.0)
    return x * x * (3.0 - 2.0 * x)


def detail_denoise(rgb, amount, denoise, edge_guard, dither=True,
                   halo_guard=True, edge_weight=True, y_offset=0):
    """QualityCore.applyDetail 鐨勯�愪綅澶嶅埢锛?    浜�搴﹀�?鈫?5-tap 楂樻柉鍩哄簳 鈫?楂橀�?d 鈫?鏍稿寲/闄嶅櫔 鈫?淇濊竟澧炵泭 鈫?鏋佸�奸挸鍒?鈫?鎶栧姩銆?""
    h, w = rgb.shape[0], rgb.shape[1]
    L = luma_plane(rgb)
    base = conv_sep_u8(L, [1, 4, 6, 4, 1], 16)
    lo, hi = window_minmax(L, 2)

    t1 = 3.0 + 9.0 * float(denoise)
    t0 = 1.5 + 1.5 * float(denoise)
    guard_k = float(edge_guard) / (EDGE_SCALE * EDGE_SCALE)

    d = L.astype(np.float64) - base.astype(np.float64)
    knee = knee_curve(np.abs(d), t0, t1)
    m = 1.0 - float(denoise) * (1.0 - knee)      # 灏忔畫宸?= 鍣�澹� 鈫?鍓婂急

    rng = (hi.astype(np.float64) - lo.astype(np.float64))
    if edge_weight:                              # 澶у�规瘮搴﹀眬閮?= 杈圭紭 鈫?灏戦攼鍖?        ew = 1.0 / (1.0 + guard_k * rng * rng)
    else:
        ew = np.ones_like(rng)

    v = base.astype(np.float64) + d * m * (1.0 + float(amount) * ew)
    if halo_guard:                               # 鍐冲畾鎬х殑涓�姝ワ細涓嶅厑璁告柊鏋佸�?        v = np.clip(v, lo.astype(np.float64), hi.astype(np.float64))

    vq = np.clip(np.floor(v + bayer_pm05(h, w, y_offset, dither) + 0.5), 0, 255)
    delta = vq.astype(np.int32) - L.astype(np.int32)   # 涓夐�氶亾鍚屽姞 鈫?鏃犺壊鍋?
    out = np.empty_like(rgb)
    for c in range(3):
        ch = rgb[:, :, c].astype(np.int32) + delta
        out[:, :, c] = np.clip(ch, 0, 255).astype(np.uint8)
    return out


def usm_box3(rgb, amount):
    """鏃у疄鐜帮細3x3 鐩掑紡 USM锛團rameOps.unsharp 鐨勭瓑浠锋暟瀛︼紝浜�搴﹀煙鐗堟湰锛夈�?""
    L = luma_plane(rgb)
    base = conv_sep_u8(L, [1, 1, 1], 3)
    d = L.astype(np.float64) - base.astype(np.float64)
    v = np.round(L.astype(np.float64) + float(amount) * d)
    delta = v.astype(np.int32) - L.astype(np.int32)
    out = np.empty_like(rgb)
    for c in range(3):
        out[:, :, c] = np.clip(rgb[:, :, c].astype(np.int32) + delta,
                               0, 255).astype(np.uint8)
    return out


def gray_image(h, w, value):
    return np.full((h, w, 3), value, dtype=np.uint8)


def step_image(h, w, low, high, x_edge):
    img = np.zeros((h, w, 3), dtype=np.uint8)
    img[:, :x_edge, :] = low
    img[:, x_edge:, :] = high
    return img


def edge_width(row, low, high):
    """10%鈥?0% 杩囨浮瀹藉害锛堝瓙鍍忕礌绾挎�ф彃鍊硷級銆傝秺灏忚秺閿愩�?""
    r = row.astype(np.float64)
    out = []
    for lvl in (low + 0.1 * (high - low), low + 0.9 * (high - low)):
        for i in range(1, len(r)):
            if (r[i - 1] - lvl) * (r[i] - lvl) <= 0.0 and r[i] != r[i - 1]:
                out.append(i - 1 + (lvl - r[i - 1]) / (r[i] - r[i - 1]))
                break
    if len(out) != 2:
        return float("nan")
    return float(out[1] - out[0])


def longest_run(row):
    best = cur = 1
    for i in range(1, len(row)):
        if row[i] == row[i - 1]:
            cur += 1
            best = max(best, cur)
        else:
            cur = 1
    return best


# ----------------------------------------------------------------------------
# T1 鏍稿舰鐘朵笌棰戝搷
# ----------------------------------------------------------------------------

def t1_kernels():
    print("\n--- T1 鍙�鍒嗙�诲嵎绉�涓庢牳褰㈢�?---")
    k5_2d = np.outer(K5_BIN, K5_BIN) / 256.0
    k3_2d = np.outer(K3_BOX, K3_BOX) / 9.0

    img = np.random.RandomState(7).rand(32, 32) * 255.0
    sep = conv_sep_float(img, K5_BIN)
    two = np.zeros_like(img)
    p = np.pad(img, 2, mode="edge")
    for dy in range(5):
        for dx in range(5):
            two += k5_2d[dy, dx] * p[dy:dy + 32, dx:dx + 32]
    err = float(np.max(np.abs(sep - two)))
    check("T1.1 5x5 鍙�鍒嗙�?鈮?2D 鍗风Н", err < 1e-9, "max|螖| = %.2e" % err)

    u8 = np.random.RandomState(11).randint(0, 256, (64, 64)).astype(np.uint8)
    a = conv_sep_u8(u8, [1, 4, 6, 4, 1], 16).astype(np.float64)
    b = conv_sep_float(u8, K5_BIN)
    err8 = float(np.max(np.abs(a - b)))
    check("T1.2 8-bit 涓ら亶鍋忓樊 鈮?1 鐮佸�?, err8 <= 1.0,
          "max|螖| = %.2f LSB锛堣�� coring 姝诲尯 t0鈮?.5 鍚告敹锛? % err8)

    def resp1d(k, w):
        n = np.arange(len(k)) - (len(k) - 1) / 2.0
        return float(np.abs(np.sum(k * np.exp(-1j * w * n))) / np.sum(k))

    box_ny, bin_ny = resp1d(K3_BOX, np.pi), resp1d(K5_BIN, np.pi)
    check("T1.3 Nyquist 娉勬紡 binomial < box", bin_ny < box_ny,
          "box3=%.3f binomial5=%.2e锛堣秺灏忚秺涓嶆妸 Nyquist 鍣�澹板綋缁嗚妭锛�"
          % (box_ny, bin_ny))

    def aniso(k2d, omega):
        n = k2d.shape[0]
        ys, xs = np.mgrid[0:n, 0:n]
        c = (n - 1) / 2.0
        vals = []
        for ang in (0.0, np.pi / 8, np.pi / 4, 3 * np.pi / 8, np.pi / 2):
            th = np.cos(ang) * (xs - c) + np.sin(ang) * (ys - c)
            vals.append(abs(np.sum(k2d * np.exp(-1j * omega * th))))
        vals = np.array(vals)
        return float((vals.max() - vals.min()) / max(1e-12, vals.mean()))

    a_box = aniso(k3_2d, np.pi / 2)
    a_bin = aniso(k5_2d, np.pi / 2)
    check("T1.4 binomial 鏂瑰悜涓�鑷存�уソ浜?box", a_bin < a_box,
          "蠅=蟺/2 澶勭浉瀵硅捣浼忥細box3=%.3f binomial5=%.3f" % (a_box, a_bin))

    check("T1.5 涓ゆ牳 DC 澧炵泭鍧囦负 1",
          abs(k3_2d.sum() - 1.0) < 1e-12 and abs(k5_2d.sum() - 1.0) < 1e-12,
          "sum(box3)=%.12f sum(bin5)=%.12f" % (k3_2d.sum(), k5_2d.sum()))


# ----------------------------------------------------------------------------
# T2 纭�闃惰�?halo
# ----------------------------------------------------------------------------

def t2_halo():
    print("\n--- T2 纭�闃惰穬杈圭�?halo锛?-bit 鐮佸�硷級---")
    h, w = 48, 96
    worst_old = worst_nc = worst_new = 0.0
    print("  瀵规瘮搴?| 鏃?x3USM | 鏂?鏃犻挸鍒? | 鏂?閽冲埗)")
    for contrast in (16, 32, 64, 128, 200):
        low = 128 - contrast // 2
        high = 128 + contrast // 2
        img = step_image(h, w, low, high, 48)
        old = usm_box3(img, 0.40)
        nc = detail_denoise(img, 0.40, 0.0, 0.2, dither=False, halo_guard=False)
        new = detail_denoise(img, 0.40, 0.0, 0.2, dither=False, halo_guard=True)

        def over(o):
            g = o.astype(np.float64).mean(axis=2)
            return float(max(g.max() - high, low - g.min(), 0.0))

        o_old, o_nc, o_new = over(old), over(nc), over(new)
        worst_old = max(worst_old, o_old)
        worst_nc = max(worst_nc, o_nc)
        worst_new = max(worst_new, o_new)
        print("  %6d | %9.2f | %10.2f | %8.2f" % (contrast, o_old, o_nc, o_new))

    check("T2.1 鏃?3x3 USM 鏈夊彲瑙?halo", worst_old >= 3.0,
          "鏈�澶ц秺鐣?%.1f 鐮佸�硷紙瑙嗚�夐槇鍊肩害 2鈥?锛? % worst_old)
    check("T2.2 浠呮崲楂樻柉鍩哄簳涓嶈冻浠ユ秷 halo", worst_nc > 1.0,
          "鏃犻挸鍒舵椂鏈�澶ц秺鐣?%.1f 鐮佸�? % worst_nc)
    check("T2.3 鏋佸�奸挸鍒跺悗瓒婄晫 = 0", worst_new <= 0.0,
          "鏈�澶ц秺鐣?%.1f 鐮佸�硷紙鏁板�︿笂涓嶅彲鑳借秴鍑� 5x5 灞�閮ㄦ瀬鍊硷級" % worst_new)


# ----------------------------------------------------------------------------
# T3 閿愬害鏈夋晥鎬?# ----------------------------------------------------------------------------

def t3_acuity():
    print("\n--- T3 閿愬害鏈夋晥鎬?---")
    h, w = 16, 96
    x = np.arange(w)
    soft = np.round(100.0 + 80.0 / (1.0 + np.exp(-(x - 48.0) / 0.8)))
    img = np.repeat(np.repeat(soft[None, :, None], 3, axis=2), h, axis=0)
    img = img.astype(np.uint8)
    w_in = edge_width(img[8, :, 0], 100, 180)
    out = detail_denoise(img, 0.50, 0.0, 0.2, dither=False)
    w_new = edge_width(out[8, :, 0], 100, 180)
    old = usm_box3(img, 0.50)
    w_old = edge_width(old[8, :, 0], 100, 180)
    print("  蟽=0.8 杈圭紭 10鈥?0%% 瀹藉害锛氳緭鍏?%.2f 鈫?鏃?%.2f (脳%.2f) / 鏂?%.2f (脳%.2f)"
          % (w_in, w_old, w_in / w_old, w_new, w_in / w_new))
    check("T3.1 杈圭紭瀹藉害鏀剁缉 鈮?5%", w_in / w_new >= 1.05,
          "脳%.2f锛堥挸鍒舵妸鍙�鐢ㄧ殑閿愬寲閲忛檺鍒跺湪灞�閮ㄦ瀬鍊间互鍐咃級" % (w_in / w_new))
    # 鍏�骞虫瘮杈冿細閿愬害锛堣竟缂樺�藉害锛変笌鐧借竟锛堣秺鐣岀爜鍊硷級蹇呴』鎴愬�硅瘎浼般�?    # 鏃у疄鐜拌兘澶氶攼 1.5%锛屼唬浠锋槸鍚屼竴寮犲浘涓婂嚭鐜扮櫧杈癸紱鏂板疄鐜板湪鍚岀瓑閿愬害涓嬬櫧杈逛负 0銆?    halo_old = float(max(0.0, float(old[8, :, 0].max()) - 180.0))
    halo_new = float(max(0.0, float(out[8, :, 0].max()) - 180.0))
    check("T3.2 閿愬害涓庢棫瀹炵幇绛変环锛堝樊璺?鈮?%锛?, w_new <= w_old * 1.03,
          "鏂?%.2f px vs 鏃?%.2f px锛堝樊 %.1f%%锛夛紱鍚岀瓑閿愬害涓嬬櫧杈?鏃?%.1f 鐮?/ 鏂?%.1f 鐮?
          % (w_new, w_old, 100.0 * (w_new / w_old - 1.0), halo_old, halo_new))

    xs = np.arange(160)
    tex = 120.0 + 20.0 * np.sin(2 * np.pi * xs / 8.0)
    img2 = np.repeat(np.repeat(np.round(tex)[None, :, None], 3, axis=2), h, axis=0)
    img2 = img2.astype(np.uint8)
    sl = slice(8, 152)
    g0 = float(np.max(np.abs(np.diff(img2[8, sl, 0].astype(np.float64)))))
    out2 = detail_denoise(img2, 0.50, 0.0, 0.2, dither=False)
    g1 = float(np.max(np.abs(np.diff(out2[8, sl, 0].astype(np.float64)))))
    check("T3.3 8px 鍛ㄦ湡绾圭悊姊�搴︽彁鍗� 鈮?10%", g1 / g0 >= 1.10,
          "max|螖| %.2f 鈫?%.2f (脳%.2f)" % (g0, g1, g1 / g0))


# ----------------------------------------------------------------------------
# T4 楂橀�戜繚鎶や笌闄嶅�?# ----------------------------------------------------------------------------

def t4_highfreq():
    print("\n--- T4 楂橀�戜繚鎶� / 闄嶅櫔 ---")
    h, w = 64, 64
    yy, xx = np.mgrid[0:h, 0:w]

    nyq = np.stack([(((yy + xx) & 1) * 255)] * 3, axis=2).astype(np.uint8)
    out = detail_denoise(nyq, 0.60, 0.0, 0.2, dither=False)
    dmax = int(np.max(np.abs(out.astype(np.int32) - nyq.astype(np.int32))))
    check("T4.1 鍏ㄥ�规�?1px 妫嬬洏鍔犺兘閲?= 0", dmax == 0,
          "max|螖|=%d锛坋dgeGuard 鎶婂�炵泭鍘嬪�?~7%%锛? % dmax)

    mid = np.where(((yy + xx) & 1) == 1, 156, 100).astype(np.uint8)
    mid3 = np.stack([mid] * 3, axis=2)
    o_old = usm_box3(mid3, 0.60)[..., 0]
    o_new = detail_denoise(mid3, 0.60, 0.0, 0.2, dither=False)[..., 0]
    rng_old = int(o_old.max()) - int(o_old.min())
    rng_new = int(o_new.max()) - int(o_new.min())
    print("  涓�璋冩�嬬洏杈撳嚭鑼冨洿锛氭棫 [%d,%d] 瀹?%d / 鏂?[%d,%d] 瀹?%d"
          % (o_old.min(), o_old.max(), rng_old, o_new.min(), o_new.max(), rng_new))
    check("T4.2 涓�璋冩�嬬洏涓嶈秺鍑烘簮鏋佸�?, rng_new <= 56,
          "鏂板�藉�?%d 鈮?杈撳叆 56锛涙棫瀹藉害 %d锛堝�氬�?%d 鐮?halo锛?
          % (rng_new, rng_old, rng_old - 56))

    rs = np.random.RandomState(23)
    noisy = np.stack([np.clip(np.round(128.0 + rs.normal(0.0, 3.0, (h, w))),
                              0, 255)] * 3, axis=2).astype(np.uint8)
    si = float(noisy[8:-8, 8:-8, 0].std())

    def sig(amount, denoise):
        return float(detail_denoise(noisy, amount, denoise, 0.2,
                                    dither=False)[8:-8, 8:-8, 0].std())

    r00, r06, r10 = sig(0.0, 0.0), sig(0.0, 0.6), sig(0.0, 1.0)
    r56, r50 = sig(0.5, 0.6), sig(0.5, 0.0)
    print("  鍣�澹� 蟽=%.2f锛歛mount0/dn0 脳%.3f, dn0.6 脳%.3f, dn1.0 脳%.3f"
          % (si, r00 / si, r06 / si, r10 / si))
    print("            amount0.5/dn0.6 脳%.3f, amount0.5/dn0 脳%.3f"
          % (r56 / si, r50 / si))
    check("T4.3 amount=0 鏃剁�＄嚎涓烘亽绛�", abs(r00 - si) < 1e-9,
          "蟽 瀹屽叏涓嶅彉锛坢=1, d 涓?base 绮剧‘鎶垫秷锛?)
    check("T4.4 denoise=0.6 鎶婂櫔澹板帇鍒?鈮?0%", r06 / si <= 0.70,
          "脳%.2f" % (r06 / si))
    check("T4.5 denoise=1.0 鎶婂櫔澹板帇鍒?鈮?5%", r10 / si <= 0.45,
          "脳%.2f锛堟�ゆ椂杈撳�?= 绾�楂樻柉鍩哄簳锛屾渶骞虫粦锛? % (r10 / si))
    check("T4.6 閿愬寲+闄嶅櫔鍚屾椂寮�鍚�浠嶆湁鍑�闄嶅櫔", r56 / si <= 0.90,
          "脳%.2f锛堟瘮鍗曞紑 amount=0.5 鐨?脳%.2f 浣庯級" % (r56 / si, r50 / si))

    ids = detail_denoise_noop_check()
    check("T4.7 amount=denoise=0 閫愪綅鎭掔瓑", ids,
          "鍚�鎶栧姩寮�鍚�鏃朵篃閫愪綅鐩稿悓锛堟暣鏁?+ 鎶栧姩 < 1 LSB 涓嶄細杩涗綅锛?)


def detail_denoise_noop_check():
    rs = np.random.RandomState(29)
    img = rs.randint(0, 256, (40, 40, 3)).astype(np.uint8)
    out = detail_denoise(img, 0.0, 0.0, 0.2, dither=True)
    return bool(np.array_equal(img, out))


# ----------------------------------------------------------------------------
# T5 鎶栧姩
# ----------------------------------------------------------------------------

def t5_dither():
    print("\n--- T5 鎶栧姩涓?banding ---")
    # 鏈哄埗 1锛堟暟瀛︿簨瀹烇級锛歷 涓烘暣鏁版椂锛屄?.5 LSB 鐨勬湁搴忔姈鍔ㄤ笉鍙�鑳借法杩囪垗鍏ヨ竟鐣�
    #   |off| <= 0.469 < 0.5 涓?v 鈭?Z  鈬? round(v + off) == v  閫愪綅鎴愮珛銆?    # 鎺ㄨ�猴細鎶栧姩鍙�鑳芥墦鏁ｃ�岀�＄嚎鑷�宸变骇鐢熺殑灏忔暟 v銆嶏紝涓嶈兘淇�澶嶆簮鐗囧凡鏈夌�?8-bit 鑹插甫
    #       锛堣壊甯︽湰韬�灏辨槸鏁存暟骞冲彴锛夈�傝繖鏄�鏈�璁捐�＄殑杈圭晫锛屽啓娓呮�氫互鍏嶈繃搴︽壙璇恒�?    flat = np.full((16, 64, 3), 137, dtype=np.uint8)
    q_off = detail_denoise(flat, 0.0, 0.0, 0.2, dither=False)
    q_on = detail_denoise(flat, 0.0, 0.0, 0.2, dither=True)
    check("T5.1 鏁存暟 v 涓婃姈鍔ㄩ�愪綅鏃犳搷浣?, bool(np.array_equal(q_off, q_on)),
          "骞冲満 137锛氭姈鍔ㄥ紑/鍏宠緭鍑哄畬鍏ㄧ浉鍚岋紙鏃犳硶璺ㄨ繃 .5锛屾晠涓嶄細寮曞叆鍣�鐐癸�?)

    # 鏈哄埗 2锛歷 涓哄皬鏁版椂锛堥檷鍣�鍚庝粛鏈� 卤1 鐮佹畫宸�锛夛紝鎶栧姩鎶婇噺鍖栬��宸�杞�鎴愮┖闂村櫔澹帮�?    # 鍙�鏀瑰彉绾︿袱鎴愬儚绱� 卤1 鐮併�佸潎鍊间笉婕傘�佸箙搴︽亽 鈮? 鐮併�?    rs = np.random.RandomState(31)
    n = 512
    ideal = np.linspace(40.0, 62.0, n)             # 鏋佺紦娓愬彉锛堝ぉ绌猴級
    src = np.round(ideal + rs.normal(0.0, 1.2, n))
    img = np.repeat(np.repeat(src[None, :, None], 3, axis=2), 32, axis=0)
    img = np.clip(img, 0, 255).astype(np.uint8)
    on = detail_denoise(img, 0.0, 0.6, 0.2, dither=False)[16, :, 0]
    od = detail_denoise(img, 0.0, 0.6, 0.2, dither=True)[16, :, 0]
    d = od.astype(np.int32) - on.astype(np.int32)
    frac = float(np.mean(d != 0))
    dmean = float(np.mean(d))
    print("  闄嶅櫔鍚庢笎鍙橈紙鏂滅巼 %.3f 鐮?px锛夛細鎶栧姩鏀瑰彉 %.1f%% 鍍忕礌锛屽潎鍊兼紓绉?%+.3f 鐮?
          % ((62.0 - 40.0) / n, 100.0 * frac, dmean))
    check("T5.2 灏忔暟 v 涓婃妸閲忓寲璇�宸�杞�鎴愮┖闂村櫔澹�",
          0.05 <= frac <= 0.60 and int(np.abs(d).max()) <= 1 and abs(dmean) <= 0.15,
          "鏀瑰彉 %.1f%% 鍍忕礌锛宮ax|螖|=%d 鐮侊紝鍧囧�兼紓绉?%+.3f"
          % (100.0 * frac, int(np.abs(d).max()), dmean))
    rp, rd = longest_run(on.astype(np.int32)), longest_run(od.astype(np.int32))
    check("T5.3 鎶栧姩涓嶆媺闀垮钩鍙?, rd <= rp, "%d px 鈫?%d px" % (rp, rd))

    # 鍧囧�兼棤鍋?+ 骞呭害 鈮?卤0.5
    bias = float(np.mean(bayer_pm05(64, 64, 0, True)))
    amp = bayer_pm05(4, 4, 0, True)
    check("T5.4 鎶栧姩鍧囧�间负 0锛堜笉鏀瑰彉浜�搴︼�?, abs(bias) < 1e-12,
          "mean = %.2e" % bias)
    check("T5.5 鎶栧姩骞呭害 鈮?卤0.5 鐮佸�?,
          float(amp.min()) >= -0.5 and float(amp.max()) <= 0.5,
          "鑼冨洿 [%.3f, %.3f]" % (amp.min(), amp.max()))

    # 鐩稿叧鎬э細鐩搁偦鍍忕礌鐨勬姈鍔ㄥ�煎繀椤讳笉鍚岋紝鍚﹀垯绛変簬娌℃姈
    flat = ideal[0] * np.ones((8, 8))
    v0 = bayer_pm05(8, 8, 0, True)
    differ = float(np.mean(np.abs(v0[:, 1:] - v0[:, :-1]) > 1e-9))
    check("T5.6 鐩搁偦鍍忕礌鎶栧姩鍊间簰涓嶇浉鍚?, differ >= 0.9,
          "%.0f%% 鐨勭浉閭诲儚绱犲�逛笉鍚�" % (100.0 * differ))

    t0 = bayer_pm05(8, 8, 0, True)
    t1 = bayer_pm05(8, 8, 0, True)
    check("T5.7 鎶栧姩鍥炬�堜笉闅忔椂闂村彉鍖�", bool(np.array_equal(t0, t1)),
          "鍚屼竴鍧愭爣鎭掑畾 鈫?涓嶅紩鍏ユ椂闂村櫔澹帮紙涓?HDR 璺�寰勫悓椋庢牸锛�")


# ----------------------------------------------------------------------------
# T6 鍗曡皟鎬?# ----------------------------------------------------------------------------

def t6_monotone():
    print("\n--- T6 鍗曡皟鎬э紙鏃犳尟閾冿級---")
    h, w = 16, 256
    ramp = np.round(np.linspace(20.0, 235.0, w))
    img = np.repeat(np.repeat(ramp[None, :, None], 3, axis=2), h, axis=0).astype(np.uint8)
    out = detail_denoise(img, 0.60, 0.0, 0.0, dither=False)
    d = np.diff(out[8, :, 0].astype(np.int32))
    check("T6.1 缂撴笎鍙樹繚鎸佸崟璋?, bool(np.all(d >= 0)),
          "min(螖)=%d 鍙嶅悜鍍忕礌=%d" % (int(d.min()), int(np.sum(d < 0))))

    x = np.arange(w)
    soft = np.round(40.0 + 170.0 / (1.0 + np.exp(-(x - 128.0) / 6.0)))
    img2 = np.repeat(np.repeat(soft[None, :, None], 3, axis=2), h, axis=0).astype(np.uint8)
    out2 = detail_denoise(img2, 0.60, 0.0, 0.2, dither=False)
    r = out2[8, :, 0].astype(np.int32)
    d2 = np.diff(r)
    check("T6.2 鏌斿拰杈圭紭淇濇寔鍗曡皟", bool(np.all(d2 >= 0)),
          "min(螖)=%d 鍙嶅悜鍍忕礌=%d" % (int(d2.min()), int(np.sum(d2 < 0))))
    check("T6.3 杈撳嚭涓嶈秺鍑烘簮鐏板害鑼冨洿",
          int(r.min()) >= int(img2.min()) and int(r.max()) <= int(img2.max()),
          "[%d,%d] 鈯?[%d,%d]" % (r.min(), r.max(), img2.min(), img2.max()))


# ----------------------------------------------------------------------------
# T7 鑳介噺瀹堟亽
# ----------------------------------------------------------------------------

def t7_energy():
    print("\n--- T7 鑳介噺瀹堟亽 ---")
    rs = np.random.RandomState(3)
    g = rs.randint(20, 236, (96, 96))
    img = np.stack([g] * 3, axis=2).astype(np.uint8)
    L = luma_plane(img).astype(np.float64)
    base = conv_sep_u8(luma_plane(img), [1, 4, 6, 4, 1], 16).astype(np.float64)
    mean_d = float(np.mean(L - base))
    # 涓ら亶 8-bit 鑸嶅叆寮曞叆鐨勫浐鏈夊亸缃�锛氳繙灏忎�?1 鐮侊紝涓?amount=0 鏃惰�� d 涓?base 绮剧‘鎶垫秷
    # 锛堣�� T4.3/T4.7锛夛紝鏁呭彧闇�纭�璁ゃ�屽彲蹇界暐銆嶈�屼笉鏄�銆屼弗鏍间负 0銆嶃�?    check("T7.1 楂樻柉鍩哄簳鐩存祦鍋忕Щ < 0.15 鐮?, abs(mean_d) < 0.15,
          "mean(Y-G*Y) = %.4f 鐮佸�硷紙涓ら亶 8-bit 鑸嶅叆鐨勫浐鏈夊亸缃�锛�" % mean_d)
    check("T7.2 浜�搴︽潈閲嶅拰涓� 256", LUMA_SUM == 256,
          "%d+%d+%d = %d" % (LUMA_R, LUMA_G, LUMA_B, LUMA_SUM))

    flat = gray_image(32, 32, 137)
    out = detail_denoise(flat, 0.80, 0.0, 0.2, dither=True)
    dmax = int(np.max(np.abs(out.astype(np.int32) - flat.astype(np.int32))))
    check("T7.3 绾�鑹插潡閫愪綅涓嶅彉", dmax == 0,
          "max|螖|=%d锛坴=137 鎭颁负鏁存暟锛屄?.47 鎶栧姩涓嶄細璺ㄨ繃 .5锛? % dmax)


# ----------------------------------------------------------------------------
# T8 鐏伴樁淇濈湡 / 鏃犲僵杈?# ----------------------------------------------------------------------------

def t8_gray():
    print("\n--- T8 鐏伴樁淇濈湡 ---")
    rs = np.random.RandomState(5)
    gray = np.repeat(rs.randint(0, 256, (64, 64, 1)).astype(np.uint8), 3, axis=2)
    out = detail_denoise(gray, 0.50, 0.30, 0.2, dither=True)
    drg = int(np.max(np.abs(out[:, :, 0].astype(np.int32) - out[:, :, 1].astype(np.int32))))
    dgb = int(np.max(np.abs(out[:, :, 1].astype(np.int32) - out[:, :, 2].astype(np.int32))))
    check("T8.1 涓�鎬х伆浠嶄负涓�鎬х伆", drg == 0 and dgb == 0,
          "max|R-G|=%d max|G-B|=%d锛堜寒搴﹀煙澶勭悊 鈫?涓嶄細鍑哄僵杈癸級" % (drg, dgb))

    col = rs.randint(0, 256, (64, 64, 3)).astype(np.uint8)
    out2 = detail_denoise(col, 0.50, 0.0, 0.2, dither=True)
    delta = out2.astype(np.int32) - col.astype(np.int32)
    sat = (out2 >= 255) | (out2 <= 0)
    mask = ~sat.any(axis=2)
    spread = int(np.max((delta.max(axis=2) - delta.min(axis=2))[mask])) if mask.any() else 0
    check("T8.2 鏈�楗卞拰澶勪笁閫氶亾澧為噺涓�鑷?, spread == 0,
          "max(螖max-螖min)=%d 鐮佸�硷紙鎺掗櫎 %d 涓�楗卞拰鍍忕礌锛�"
          % (spread, int((~mask).sum())))


# ----------------------------------------------------------------------------
# T9 缂╂斁鏍?# ----------------------------------------------------------------------------

def upsample_catmull_rom(img, f):
    def kern(t):
        t = abs(t)
        if t < 1.0:
            return 1.5 * t ** 3 - 2.5 * t ** 2 + 1.0
        if t < 2.0:
            return -0.5 * t ** 3 + 2.5 * t ** 2 - 4.0 * t + 2.0
        return 0.0

    h, w = img.shape
    oh, ow = h * f, w * f
    tmp = np.zeros((h, ow), dtype=np.float64)
    for x in range(ow):
        cx = (x + 0.5) / f - 0.5
        i0 = int(np.floor(cx))
        acc, den = np.zeros(h), 0.0
        for t in range(i0 - 1, i0 + 3):
            wt = kern(cx - t)
            if wt == 0.0:
                continue
            acc += wt * img[:, min(w - 1, max(0, t))]
            den += wt
        tmp[:, x] = acc / max(1e-9, den)
    out = np.zeros((oh, ow), dtype=np.float64)
    for y in range(oh):
        cy = (y + 0.5) / f - 0.5
        j0 = int(np.floor(cy))
        acc, den = np.zeros(ow), 0.0
        for t in range(j0 - 1, j0 + 3):
            wt = kern(cy - t)
            if wt == 0.0:
                continue
            acc += wt * tmp[min(h - 1, max(0, t)), :]
            den += wt
        out[y, :] = acc / max(1e-9, den)
    return np.clip(out, 0.0, 255.0)


def ds_area(img, f):
    h, w = img.shape
    return img.reshape(h // f, f, w // f, f).mean(axis=(1, 3))


def _ds_generic(img, f, kern, support):
    h, w = img.shape
    oh, ow = h // f, w // f
    sup = int(np.ceil(support * f))
    tmp = np.zeros((h, ow), dtype=np.float64)
    for x in range(ow):
        cx = (x + 0.5) * f - 0.5
        lo, hi = int(np.floor(cx - sup)), int(np.ceil(cx + sup))
        num, den = 0.0, 0.0
        for t in range(lo, hi + 1):
            wt = kern((t - cx) / f)
            if wt == 0.0:
                continue
            num += wt * img[:, min(w - 1, max(0, t))]
            den += wt
        tmp[:, x] = num / max(1e-9, den)
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
        out[y, :] = num / max(1e-9, den)
    return out


def upsample_bilinear(img, f):
    """鍙岀嚎鎬ф斁澶э細鏃犺礋鐡ｃ�佹棤杩囧啿锛岀敤鏉ユā鎷熴�屾俯鍜屻�嶇殑 4x 閲嶅缓缁撴灉銆?""
    h, w = img.shape
    oh, ow = h * f, w * f
    mx = _bilinear_matrix(w, ow)
    my = _bilinear_matrix(h, oh)
    mid = img.dot(mx.T)
    return my.dot(mid)


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
        i1 = i0 + 1
        if i1 > n - 1:
            i1 = n - 1
        t = c - float(i0)
        m[i, i0] += 1.0 - t
        m[i, i1] += t
    return m


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
    print("\n--- T9 缂╂斁鏍革紙AI 4x 閲嶅缓 鈫?鐩�鏍囧昂瀵革�?--")
    f = 4
    h = w = 96
    yy, xx = np.mgrid[0:h, 0:w]
    gt = np.full((h, w), 40.0)
    gt += 30.0 * np.sin(2 * np.pi * xx / 9.0)
    gt[40:, :] += 120.0
    gt = np.clip(gt, 0.0, 255.0)
    # 鍏抽敭锛?x 鍐呭�圭�?bilinear 閫狅紙鏃犺礋鐡ｃ�佹棤杩囧啿锛夛紝杩欐牱娴嬪埌鐨勮繃鍐插彧鍙�鑳芥潵鑷�
    # 闄嶉噰鏍锋牳鏈�韬�锛岃�屼笉鏄�銆屾斁澶у櫒鎸�閾冭��闈㈢Н骞冲潎淇濈暀銆嶈繖绉嶄吉褰便�?    up = upsample_bilinear(gt, f)

    def psnr(a, b):
        mse = float(np.mean((a - b) ** 2))
        return 99.0 if mse <= 1e-12 else float(10.0 * np.log10(255.0 ** 2 / mse))

    # 绾�闃惰穬鍗曠嫭搴﹂噺棰勬尟閾冿紙绾圭悊鍖轰細鎶婃斁澶у櫒鎸�閾冨甫杩涙潵锛屾薄鏌撴寚鏍囷級
    step_gt = np.where(xx < 48, 40.0, 200.0)
    step_up = upsample_bilinear(step_gt, f)

    res = {}
    for name, fn in (("box(闈㈢Н骞冲潎)", ds_area),
                     ("tent(鎶楅敮榻夸笁瑙?", ds_tent),
                     ("lanczos3", ds_lanczos3)):
        dn = np.clip(np.round(fn(up, f)), 0, 255)
        sd = np.clip(np.round(fn(step_up, f)), 0, 255)
        ring = max(float(sd.max() - 200.0), float(40.0 - sd.min()), 0.0)
        res[name] = (psnr(dn, gt), ring)
        print("  %-18s PSNR %.2f dB / 绾�闃惰穬瓒婄�?%.2f 鐮?
              % (name, res[name][0], ring))

    box_p, box_r = res["box(闈㈢Н骞冲潎)"]
    ten_p, ten_r = res["tent(鎶楅敮榻夸笁瑙?"]
    lan_p, lan_r = res["lanczos3"]
    check("T9.1 闈㈢Н骞冲潎鏄?bilinear 鏀惧ぇ鐨勮繎浼肩簿纭�閫?, box_p >= 45.0,
          "PSNR %.2f dB锛堢悊鎯抽�嗗湪鍚屽昂瀵镐笅灏辨槸 gt 鏈�韬�锛? % box_p)
    check("T9.2 杞�鏍革紙box/tent锛夊湪闃惰穬涓婇浂瓒婄晫",
          box_r <= 0.5 and ten_r <= 0.5,
          "box %.2f / tent %.2f 鐮? % (box_r, ten_r))
    check("T9.3 lanczos3 鍦ㄩ樁璺冧笂棰勬尟閾?> 1 鐮?, lan_r > 1.0,
          "lanczos3 %.2f 鐮?vs box %.2f 鐮? % (lan_r, box_r))
    check("T9.4 tent 涓?box 鐨?PSNR 宸�璺� 鈮?2 dB锛堟崲鏍告敹鐩婃瀬灏忥級",
          abs(box_p - ten_p) <= 2.0,
          "box %.2f vs tent %.2f dB锛沴anczos3 %.2f dB"
          % (box_p, ten_p, lan_p))
    print("  缁撹�猴細闄嶉噰鏍锋牳涔嬮棿鏄�銆屾尟閾?vs 杞�鍖栥�嶇殑鍙栬垗锛孭SNR 涓?box鈮坱ent锛?
          "lanczos3 鐨勬尟閾冧細鍙犲湪 AI 宸茶繃鍐茬殑杈圭紭涓娿�傛晠涓嶆浛鎹?CGContext 缂╂斁锛?
          "鏀剁泭 鈮?%.1f dB锛屼唬浠锋槸閲嶅啓鑹插僵绌洪棿/棰勪箻/姝ラ暱銆?
          % abs(box_p - ten_p))


# ----------------------------------------------------------------------------
# T10 鍒嗘潯绛変环
# ----------------------------------------------------------------------------

def t10_strips():
    print("\n--- T10 鍒嗘潯 鈮?鏁村抚 ---")
    rs = np.random.RandomState(19)
    h, w = 160, 96
    img = rs.randint(0, 256, (h, w, 3)).astype(np.uint8)
    img[:, : w // 2, :] = np.clip(img[:, : w // 2, :] // 3 + 20, 0, 255)
    full = detail_denoise(img, 0.40, 0.30, 0.2, dither=True)

    pad, strip = 4, 32
    out = np.zeros_like(img)
    y = 0
    while y < h:
        y1 = min(h, y + strip)
        ys0, ys1 = max(0, y - pad), min(h, y1 + pad)
        proc = detail_denoise(img[ys0:ys1].copy(), 0.40, 0.30, 0.2,
                              dither=True, y_offset=ys0)
        out[y:y1] = proc[y - ys0:y1 - ys0]
        y = y1
    dmax = int(np.max(np.abs(full.astype(np.int32) - out.astype(np.int32))))
    check("T10.1 鍒嗘潯閫愪綅绛変簬鏁村抚", dmax == 0,
          "max|螖|=%d锛坧ad=4 瑕嗙洊楂樻柉 卤2 涓?5x5 鏋佸�肩獥锛涙姈鍔ㄩ敋瀹氬叏灞�琛屽彿锛? % dmax)


# ----------------------------------------------------------------------------
# T11 鏃跺簭铻嶅悎鏉冮噸
# ----------------------------------------------------------------------------

def temporal_k(af, flow_mag, diff):
    """QualityCore.temporalWeight 鐨勫�嶅埢銆?""
    still = 0.20 + 0.60 * af
    moving = 0.16 - 0.10 * af
    motion = min(1.0, flow_mag / 3.0)
    gate = 1.0 / (1.0 + (diff / 24.0) * (diff / 24.0))
    return (still + (moving - still) * motion) * gate


def t11_temporal():
    print("\n--- T11 鏃跺簭铻嶅悎鏉冮噸 ---")
    k_still = temporal_k(0.0, 0.0, 0.0)
    k_moving = temporal_k(0.0, 8.0, 0.0)
    k_cut = temporal_k(0.0, 0.0, 120.0)
    print("  闈欐�� k=%.3f / 杩愬姩 k=%.3f / 浜�搴︾獊鍙� k=%.3f" % (k_still, k_moving, k_cut))
    check("T11.1 闈欐�㈠尯寮鸿瀺鍚堬紙鈮�0.20锛?, k_still >= 0.20,
          "k=%.3f锛堢害 5 甯х瓑鏁堝钩鍧囷紝鍘诲櫔涓斾笉鎷栧奖锛? % k_still)
    check("T11.2 杩愬姩鍖哄急铻嶅悎锛堚墹0.16锛?, k_moving <= 0.16,
          "k=%.3f锛堟瘮闈欐�㈠急锛岄伩鍏嶈繍鍔ㄦ嫋褰憋�? % k_moving)
    check("T11.3 浜�搴︾獊鍙樻椂鍑犱箮涓嶈瀺鍚堬紙鈮�0.05锛?, k_cut <= 0.05,
          "k=%.3f锛堥伩鍏嶆畫褰?楝煎奖锛? % k_cut)
    check("T11.4 鏉冮噸鎭掑湪 [0, 1]", 
          all(0.0 <= temporal_k(a, m, d) <= 1.0
              for a in (0.0, 0.5, 1.0) for m in (0.0, 3.0, 99.0) for d in (0.0, 24.0, 255.0)),
          "鍏ㄥ弬鏁扮綉鏍兼壂鎻忔棤瓒婄晫")
    mono = all(temporal_k(0.0, m, 0.0) >= temporal_k(0.0, m + 1.0, 0.0) - 1e-12
               for m in np.arange(0.0, 12.0, 0.5))
    check("T11.5 鏉冮噸闅忚繍鍔ㄩ噺鍗曡皟涓嶅��", mono, "flow 瓒婂ぇ铻嶅悎瓒婂急")


# ----------------------------------------------------------------------------
# T12 鑰楁椂妯″瀷
# ----------------------------------------------------------------------------

def t12_cost():
    print("\n--- T12 姣忓抚鑰楁椂 / 鍐呭瓨妯″瀷锛堜及绠楋紝闈炲疄娴嬶級---")
    # 鏂规硶锛氭妸绠＄嚎鐪嬫垚銆屾瘡鍍忕礌鎼�杩愬�氬皯瀛楄妭銆嶏紝鍐嶉櫎浠?A15 绾у彲杈剧殑鏈夋晥甯﹀�姐�?    # 鏈夋晥甯﹀�� 6鈥?0 GB/s锛圠PDDR4X 鐞嗚�� 34 GB/s锛泇Image NEON 鏍稿彈鎸囦护鍚炲悙闄愬埗锛?    # 瀹炴祴閫氬父钀藉湪 8~12 GB/s 鍖洪棿锛岃繖閲屽彇 6 GB/s 浣滄偛瑙傜晫銆?0 GB/s 浣滀箰瑙傜晫锛夈�?    passes = [
        ("鈶?RGB鈫抣uma (Planar8)", 4 + 1),
        ("鈶?1x5 鍗风Н H", 2),
        ("鈶?5x1 鍗风Н V", 2),
        ("鈶?5x5 min (running)", 2),
        ("鈶?5x5 max (running)", 2),
        ("鈶?娈嬪樊/澧炵泭/閽冲埗/鎶栧姩/鍥炲啓锛堣瀺鍚堝惊鐜�锛�", 4 + 4 + 4),
    ]
    total_bpp = sum(p[1] for p in passes)
    for name, bpp in passes:
        print("  %-40s %2d B/px" % (name, bpp))
    print("  鍚堣�� %.0f B/px锛? 涓?pass锛涒懃 鎶婅�� luma/base/lo/hi + 璇绘簮 RGB + 鍐欑洰鏍?RGB 铻嶆垚涓�娆★級"
          % total_bpp)

    px1080 = 1920 * 1080
    px4k = 3840 * 2160
    lo_1080 = total_bpp * px1080 / 6e9
    hi_1080 = total_bpp * px1080 / 10e9
    lo_4k = total_bpp * px4k / 6e9
    hi_4k = total_bpp * px4k / 10e9
    print("  1080p锛?.1f鈥?.1f ms/甯э紱4K锛?.1f鈥?.1f ms/甯?
          % (lo_1080 * 1e3, hi_1080 * 1e3, lo_4k * 1e3, hi_4k * 1e3))
    print("  娉ㄦ剰锛氳繖鏄�瀵煎嚭绠＄嚎锛堝啓鏂囦欢锛夛紝涓嶆槸瀹炴椂棰勮�堬紝姣忓抚鍑犲崄姣�绉掑彧褰卞搷鎬诲�煎嚭鏃堕暱锛�"
          "鍚屼竴甯х殑 AI 4x 鎺ㄧ悊绾?100鈥?00 ms锛屾晠鏈�闃舵�靛崰 2鈥?%%銆?)
    check("T12.1 1080p 鎮茶�傜�?< 12 ms/甯?, lo_1080 < 0.012,
          "%.1f ms锛堝崰 AI 鎺ㄧ悊 100ms 鐨?%.1f%%锛?
          % (lo_1080 * 1e3, 100.0 * lo_1080 / 0.100))
    check("T12.2 4K 鎮茶�傜�?< 40 ms/甯?, lo_4k < 0.040,
          "%.1f ms锛?K 瀵煎嚭 30fps 姣忓皬鏃?108000 甯?鈫?棰濆�� %.0f 鍒嗛挓锛?
          % (lo_4k * 1e3, lo_4k * 108000 / 60.0))

    # 鍐呭瓨锛氬垎鏉″�勭悊锛屽嘲鍊煎彧涓庢潯楂樻湁鍏筹紝涓庡抚楂樻棤鍏炽�?    strip = 64
    per_px_bytes = 5 * 1 + 4          # 5 寮?Planar8 + 1 寮?RGBA scratch
    for name, w in (("1080p 鏉?, 1920), ("4K 鏉?, 3840)):
        mb = strip * w * per_px_bytes / 1e6
        print("  %s锛堥珮 %d锛夛細%.2f MB 宄板�? % (name, strip, mb))
    check("T12.3 鍒嗘潯宄板�煎唴瀛?< 16 MB", loop_mem(3840, strip, per_px_bytes) < 16.0,
          "4K 鏉?%.2f MB锛涙暣甯х紦鍐插垯闇� %.0f MB锛?K RGBA脳2锛?
          % (loop_mem(3840, strip, per_px_bytes),
             (2.0 * px4k * 4) / 1e6))


def loop_mem(w, strip, per_px_bytes):
    pad = 4
    return (strip + 2 * pad) * w * per_px_bytes / 1e6


# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

def main():
    print("=" * 78)
    print("PixelLift M7 路 QualityCore 绂荤嚎鏁板�奸獙璇?)
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
        print("SUMMARY: %d/%d PASS 鈥?ALL ASSERTIONS PASSED" % (passed, total))
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
