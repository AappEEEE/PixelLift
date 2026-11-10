import math

MAXEDGE = 8192
MAXPIX = 24_000_000
AICAP = 2048
BUDGET = 2_400_000
STEP = 192


def target(w0, h0, scale):
    tw = int(round(w0 * scale))
    th = int(round(h0 * scale))
    if tw > MAXEDGE or th > MAXEDGE or tw * th > MAXPIX:
        k = min(MAXEDGE / max(tw, th), math.sqrt(MAXPIX / (tw * th)))
        tw = int(tw * k)
        th = int(th * k)
    return tw, th


def ai_old(w0, h0):
    e = min(1024, max(w0, h0))
    if w0 * h0 > 1_048_576:
        e = min(e, int(max(w0, h0) * math.sqrt(1_048_576 / (w0 * h0))))
    return e


def ai_new(w0, h0, tw, th):
    e = min(AICAP, max(w0, h0))
    ideal = int(round(max(tw, th) / 4))
    if ideal > e:
        e = min(AICAP, ideal)

    def px(edge):
        k = edge / max(w0, h0)
        return w0 * k * h0 * k

    while e > 320 and px(e) > BUDGET:
        e = int(e * 0.93)
    return e


cases = [("blackboard", 4031, 2272), ("game", 2560, 1440),
         ("laptop", 4032, 3024), ("monitor", 4032, 3024)]

print(f'{"image":11s} {"source":>10s} {"target4x":>12s} {"aiOLD":>6s} '
      f'{"aiNEW":>6s} {"aiOut":>11s} {"scale":>7s} {"bufMB":>6s} {"tiles":>5s}')
for name, w0, h0 in cases:
    tw, th = target(w0, h0, 4)
    ao = ai_old(w0, h0)
    an = ai_new(w0, h0, tw, th)
    ih = int(round(an * h0 / w0))
    ow, oh = an * 4, ih * 4
    ratio = max(tw / ow, th / oh)
    buf = ow * oh * 4 / 1e6
    tiles = math.ceil(an / STEP) * math.ceil(ih / STEP)
    print(f'{name:11s} {w0}x{h0:<5d} {tw}x{th:<7d} {ao:6d} {an:6d} '
          f'{ow}x{oh:<7d} {ratio:6.2f}x {buf:6.0f} {tiles:5d}')
