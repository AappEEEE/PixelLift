#!/usr/bin/env python3
"""Numerical checks for PixelLift SDR-to-HLG Rec.2020 conversion."""
import math

def eotf(x):
    return x/12.92 if x <= 0.04045 else ((x+0.055)/1.055)**2.4

def hlg(e):
    a,b,c=0.17883277,0.28466892,0.55991073
    return math.sqrt(3*e) if e <= 1/12 else a*math.log(12*e-b)+c

def convert(rgb8,strength):
    r,g,b=(eotf(v/255) for v in rgb8)
    y=.2126*r+.7152*g+.0722*b
    u=min(1,max(0,(y-.70)/.30)); knee=u*u*(3-2*u)
    mapped=y+min(1,max(0,strength))*.30*knee*knee
    gain=mapped/y if y>1e-6 else 1
    r,g,b=r*gain*.75,g*gain*.75,b*gain*.75
    r20=.627404*r+.329283*g+.043313*b
    g20=.069097*r+.919540*g+.011362*b
    b20=.016391*r+.088013*g+.895595*b
    return tuple(hlg(v) for v in (r20,g20,b20))

def codes(rgb):
    r,g,b=rgb; y=.2627*r+.6780*g+.0593*b
    cb=min(.5,max(-.5,(b-y)/(2*(1-.0593))))
    cr=min(.5,max(-.5,(r-y)/(2*(1-.2627))))
    return 64+876*y,512+896*cb,512+896*cr

def main():
    prev=-1
    for i in range(10001):
        x=i/10000; v=hlg(eotf(x)*.75)
        assert math.isfinite(v) and 0<=v<=1 and v>=prev; prev=v
    white=hlg(.75)
    assert abs(white-.9470986396164969)<1e-9
    assert max(abs(v) for v in convert((0,0,0),1))<1e-8
    for gray in range(256):
        rgb=convert((gray,gray,gray),0)
        assert max(rgb)-min(rgb)<1e-6
    for rgb8 in ((128,128,128),(220,220,220),(255,255,255),(255,200,80)):
        yvals=[]
        for s in (0,.25,.5,.75,1):
            p=convert(rgb8,s); assert all(math.isfinite(v) and 0<=v<=1.2 for v in p)
            yvals.append(.2627*p[0]+.6780*p[1]+.0593*p[2])
        assert yvals==sorted(yvals)
    neutral=convert((255,255,255),0); y,cb,cr=codes(neutral)
    assert max(neutral)-min(neutral)<1e-6 and abs(cb-512)<1e-3 and abs(cr-512)<1e-3
    assert 64<=round(y)<=940 and 64<=round(cb)<=960 and 64<=round(cr)<=960
    for rgb8 in ((255,0,0),(0,255,0),(0,0,255),(255,200,80)):
        for s in (0,.5,1):
            y,cb,cr=codes(convert(rgb8,s))
            assert 64<=y<=940 and 64<=cb<=960 and 64<=cr<=960
    print(f'PASS: HLG monotonic; SDR white HLG={white:.6f}; neutral grayscale; shoulder monotonic; P010 Y/C legal ranges')

if __name__=='__main__': main()
