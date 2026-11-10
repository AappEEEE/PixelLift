import numpy as np
TILE,PAD=256,32
CROP=PAD*4; USABLE=(TILE-2*PAD)*4; STEP=TILE-2*PAD
def sim(w,h,shift):
    dw,dh=w*4,h*4
    c=np.zeros((dh,dw),np.int32)
    cols=max(1,-(-w//STEP)); rows=max(1,-(-h//STEP))
    off = CROP if shift else 0
    for r in range(rows):
        for k in range(cols):
            ox,oy=k*STEP,r*STEP
            for y in range(USABLE):
                dy=oy*4+off+y
                if dy>=dh: break
                for x in range(USABLE):
                    dx=ox*4+off+x
                    if dx>=dw: break
                    c[dy,dx]+=1
    return int((c==0).sum()), int((c>1).sum())
for w,h in [(100,80),(1024,768),(500,333)]:
    print(f"{w}x{h} old(shift) -> unwritten={sim(w,h,True)[0]} dup={sim(w,h,True)[1]} | new -> unwritten={sim(w,h,False)[0]} dup={sim(w,h,False)[1]}")
