#!/usr/bin/env python3
"""
gen_katana.py - procedural, photo-real black katana sprite sheet.

Output: 1024x512 RGBA, 8 bit, straight alpha, RGB bled under alpha = 0.

Layout (texture px, do not change - ZeroIntro.lua depends on it):
  A  x 0..1023, y   0..127   clean blade, tip left at (8, 34), cutting edge down
  B  x 0..1023, y 128..255   wet-blood overlay for the blade (same geometry, +128)
  C  x 0..511,  y 256..511   hilt, straight, axis y = 384, collar at the left

Usage:  python tools/gen_katana.py [out.png] [--preview]   (default: ../assets/zero_katana.png)
Everything is rendered from height / normal descriptions at SS x supersampling,
shaded in linear light, then filtered down (non-negative Hamming kernel).
"""
import os
import sys
import time

import numpy as np
from PIL import Image
from scipy import ndimage as ndi

F32 = np.float32

# ------------------------------------------------------------------ tunables
SS = 4                       # supersampling factor (>= 3)
SEED = 20261112
OUT_W, OUT_H = 1024, 512
BG_DARK = (13, 5, 7)         # only used for the preview

# --- blade geometry (region A; region B is the same shifted by +128)
TIP_X, SPINE_Y, SORI = 8.0, 34.0, 16.0      # y_spine = 34 + 16 (1 - u^2), u = (x-512)/504
YOKOTE_X, BASE_X = 90.0, 1016.0
W_YOKOTE, W_BASE = 22.0, 30.0               # blade width, linear between yokote and base
FUKURA_P = 2.35                             # width = 22 (1 - (1-t)^p) inside the kissaki
SHINOGI_V = 0.40                            # ridge position as fraction of the width
MUNE_PX = 1.5                               # visible height of the back bevel
HAMON_V = 0.775                             # mean temper-line position (fraction of width)
HI_X0 = 126.0                               # centre of the rounded groove stop

# --- blade look (linear radiance after steel reflectance)
BLADE_AMBIENT = (0.0029, 0.0033, 0.0047)
L_KEY, L_UPPER, L_FILL, L_RED = 0.46, 0.036, 0.072, 0.034
HOTSPOT_X = 344.0                           # ~ one third from the tip
HA_BASE, HA_GAIN = 0.045, 0.150              # satin edge band brightness
GRAIN = 0.20                                # brushed grain strength

# --- blood
BLOOD_COVER = 0.64
BLOOD_THIN = (150, 12, 16)
BLOOD_MID = (95, 4, 10)
BLOOD_DEEP = (58, 2, 6)
BEADS = ((121.0, 7.4, 2.1), (377.0, 4.6, 1.5), (604.0, 6.3, 1.85))   # x, drop below edge, radius

# --- hilt (region C)
AXIS_Y = 384.0
HABAKI = (16.0, 46.0)
SEPPA1 = (46.0, 50.0)
TSUBA = (50.0, 74.0)
SEPPA2 = (74.0, 78.0)
FUCHI = (78.0, 98.0)
TSUKA = (98.0, 420.0)
KASHIRA = (420.0, 442.0)
N_DIAMONDS = 11
CORD_W, CORD_T = 11.6, 2.6                  # tsuka-ito band width / thickness
CORD_SLOPE = 2.15                           # strand slope in the unrolled handle surface
MENUKI_X = 229.7

# --- hilt lighting (direction, colour, radiance, angular size^2, diffuse wrap)
KEY_DIR = (-0.15, 0.62, 0.77)
LIGHT_DEFS = (
    (KEY_DIR, (1.00, 0.96, 0.90), 4.4, 0.07, 0.15),               # soft key from above/front
    ((0.45, -0.22, 0.87), (0.55, 0.68, 1.00), 0.26, 0.40, 0.4),     # weak cool fill
    ((0.10, -0.88, 0.46), (1.00, 0.07, 0.05), 0.15, 0.26, 0.2),    # crimson bounce from below
    ((0.00, 0.55, 0.83), (0.80, 0.86, 1.00), 0.035, 1.50, 1.0),    # faint dome
)
AMBIENT = np.array([0.008, 0.008, 0.011], F32)


# ------------------------------------------------------------------- helpers
def sstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def unit(v):
    v = np.asarray(v, np.float64)
    return (v / np.linalg.norm(v)).astype(F32)


def grid(x0, y0, x1, y1):
    xs = (np.arange(int(round((x1 - x0) * SS)), dtype=F32) + 0.5) / SS + x0
    ys = (np.arange(int(round((y1 - y0) * SS)), dtype=F32) + 0.5) / SS + y0
    return np.meshgrid(xs, ys)


def blur(a, s):
    """Gaussian blur, sigma in texture px."""
    return ndi.gaussian_filter(a, s * SS, mode='nearest')


def normals(h, max_slope=6.0):
    """Unit normals (x right, y up, z to viewer) of a height field given in px."""
    gy, gx = np.gradient(h)
    gx = np.clip(gx * SS, -max_slope, max_slope)
    gy = np.clip(gy * SS, -max_slope, max_slope)
    inv = 1.0 / np.sqrt(gx * gx + gy * gy + 1.0)
    return (-gx * inv).astype(F32), (gy * inv).astype(F32), inv.astype(F32)


def hash01(i, j, s=0.0):
    v = np.sin(np.asarray(i, np.float64) * 127.1 + np.asarray(j, np.float64) * 311.7 + s * 74.7) * 43758.5453
    return (v - np.floor(v)).astype(F32)


def srgb_to_lin(c):
    c = np.asarray(c, np.float64) / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4).astype(F32)


def tonemap(lin):
    k = 0.55                                   # soft shoulder above k, then sRGB OETF
    lin = np.maximum(np.nan_to_num(lin), 0.0)
    out = np.where(lin > k, k + (1 - k) * (1 - np.exp(-(lin - k) / (1 - k))), lin)
    return np.where(out <= 0.0031308, out * 12.92, 1.055 * np.power(np.maximum(out, 1e-9), 1 / 2.4) - 0.055)


class Noise:
    def __init__(self, seed):
        self.rng = np.random.default_rng(seed)

    def g(self, shape, sy, sx):
        """Unit-variance gaussian noise; correlation lengths sy, sx in texture px."""
        sys_, sxs = sy * SS, sx * SS
        fy, fx = max(1, int(sys_ / 2)), max(1, int(sxs / 2))
        n = self.rng.standard_normal((shape[0] // fy + 3, shape[1] // fx + 3)).astype(F32)
        n = ndi.gaussian_filter(n, (sys_ / fy, sxs / fx), mode='wrap')
        if fy > 1 or fx > 1:
            n = np.asarray(Image.fromarray(n).resize((shape[1], shape[0]), Image.BICUBIC))
        n = n[:shape[0], :shape[1]]
        n = n - n.mean()
        return (n / (n.std() + 1e-9)).astype(F32)

    def line(self, x, corr):
        """Smooth 1-D unit noise sampled at x (px), correlation length corr px."""
        n = int((x.max() - x.min()) / corr) + 8
        k = self.rng.standard_normal(n)
        k = ndi.gaussian_filter1d(k, 1.0, mode='wrap')
        k /= k.std() + 1e-9
        xi = (x - x.min()) / corr + 2
        i = np.floor(xi).astype(int)
        f = xi - i
        f = f * f * (3 - 2 * f)
        return (k[i] * (1 - f) + k[i + 1] * f).astype(F32)


class Light:
    def __init__(self, d, col, rad, sig2, wrap):
        self.d = unit(d)
        self.col = np.asarray(col, F32)
        self.rad, self.sig2, self.wrap = rad, sig2, wrap
        self.E = rad * min(2.0 * sig2, 1.0) * 1.6          # diffuse irradiance scale


LIGHTS = [Light(*ld) for ld in LIGHT_DEFS]


def shade(n, diff, f0, rough, ao=1.0, key_vis=1.0, fres=0.5, limb=0.45):
    """Diffuse + glossy response to the soft lights (spherical-gaussian lobes)."""
    nx, ny, nz = n
    nzc = np.clip(nz, 0.0, 1.0)
    rx, ry, rz = 2 * nz * nx, 2 * nz * ny, 2 * nz * nz - 1
    diff = np.asarray(diff, F32)
    f0 = np.asarray(f0, F32)
    ao = np.clip(np.broadcast_to(np.asarray(ao, F32), nx.shape), 0.0, 1.2)
    F = f0 + (1 - f0) * (((1 - nzc) ** 5) * fres)[..., None]
    out = diff * AMBIENT * ao[..., None]
    r2 = np.asarray(rough, F32) ** 2
    ld = nzc ** limb
    sao = ao ** 1.5
    for i, L in enumerate(LIGHTS):
        vis = key_vis if i == 0 else 1.0
        ndl = nx * L.d[0] + ny * L.d[1] + nz * L.d[2]
        dif = np.clip((ndl + L.wrap) / (1 + L.wrap), 0, 1) * (L.E * ld) * vis * ao
        rdl = rx * L.d[0] + ry * L.d[1] + rz * L.d[2]
        s2 = L.sig2 + r2
        sp = np.exp(np.minimum((rdl - 1.0) / s2, 0.0)) * (L.sig2 / s2) * L.rad * vis * sao
        out = out + (diff * dif[..., None] + F * sp[..., None]) * L.col
    return out.astype(F32)


# --------------------------------------------------------------------- blade
def blade_geometry():
    X, Y = grid(0, 0, 1024, 128)
    x = X[0].astype(np.float64)
    u = (x - 512.0) / 504.0
    ysp = SPINE_Y + SORI * (1 - u * u)
    tk = np.clip((x - TIP_X) / (YOKOTE_X - TIP_X), 0, 1)
    w = np.where(x >= YOKOTE_X,
                 W_YOKOTE + (W_BASE - W_YOKOTE) * (x - YOKOTE_X) / (BASE_X - YOKOTE_X),
                 W_YOKOTE * (1 - (1 - tk) ** FUKURA_P))
    w[x < TIP_X] = 0.0
    yed = ysp + w
    cs = 1 / np.sqrt(1 + np.gradient(ysp, x) ** 2)
    ce = 1 / np.sqrt(1 + np.gradient(yed, x) ** 2)
    r = lambda a: a.astype(F32)[None, :]
    g = dict(X=X, Y=Y, x=x, ysp=r(ysp), yed=r(yed), w=r(w), tk=r(tk), yed1=yed)
    g['d_top'] = (Y - g['ysp']) * r(cs)
    g['d_bot'] = (g['yed'] - Y) * r(ce)
    g['cov'] = (np.clip(np.minimum(g['d_top'], g['d_bot']) * SS + 0.5, 0, 1) * (X >= TIP_X)).astype(F32)
    ws = np.maximum(g['w'], 0.05)
    g['v'] = (Y - g['ysp']) / ws
    g['px'] = Y - g['ysp']
    g['vm'] = np.minimum(MUNE_PX / ws, 0.10)
    g['vs'] = SHINOGI_V * np.where(x >= YOKOTE_X, 1.0, 0.62 + 0.38 * tk).astype(F32)[None, :]
    g['g0'] = g['vm'] * g['w'] + 1.0             # groove lips (px below the spine)
    g['g1'] = g['vs'] * g['w'] - 1.2
    return g


def hamon_line(x, nz_):
    """Irregular gunome-midare on a slow notare wave; returns v of the temper line."""
    per = np.abs(np.sin(np.pi * (x / 31.0 + 1.3 * nz_.line(x, 170.0)))) ** 1.2
    heads = 0.50 * per + 0.50 * sstep(-0.9, 1.1, nz_.line(x, 15.0))
    heads = heads * np.clip(0.80 + 0.35 * nz_.line(x, 90.0), 0.35, 1.3)
    vh = HAMON_V + 0.040 - 0.088 * heads + 0.018 * np.sin(x / 47.0 + 1.3) + 0.009 * nz_.line(x, 7.0)
    return np.clip(vh, 0.62, 0.9).astype(F32)[None, :]


def render_blade(g, nz_):
    X, Y, v, w, px = g['X'], g['Y'], g['v'], g['w'], g['px']
    shape = X.shape
    x = g['x']
    vm, vs = g['vm'], g['vs']
    rng = nz_.rng
    C = lambda *c: np.asarray(c, F32)

    # ---- height field (px) of the shinogi-zukuri cross-section
    th = np.where(x >= YOKOTE_X, 0.80 + 0.20 * (x - YOKOTE_X) / (BASE_X - YOKOTE_X),
                  0.80 * (0.35 + 0.65 * g['tk'][0] ** 0.7)).astype(F32)[None, :]
    s_mu = np.clip(v / vm, 0, 1)
    s_sj = np.clip((v - vm) / (vs - vm), 0, 1)
    s_ji = np.clip((v - vs) / (1 - vs), 0, 1)
    h = 2.75 * s_mu + 0.75 * s_sj - 3.5 * (0.58 * s_ji + 0.42 * s_ji ** 2)
    h = h * th
    # bo-hi: circular-arc channel with a rounded stop before the yokote
    gc, gw = 0.5 * (g['g0'] + g['g1']), 0.5 * (g['g1'] - g['g0'])
    dd = np.sqrt((px - gc) ** 2 + np.clip(HI_X0 - X, 0, None) ** 2)
    R = gw * 1.2
    hi_depth = np.clip(np.sqrt(np.clip(R * R - dd * dd, 0, None)) - np.sqrt(R * R - gw * gw), 0, None)
    hi_mask = sstep(0.0, 0.45, hi_depth)
    h = h - hi_depth
    h = h + 0.10 * nz_.g(shape, 5.0, 60.0)                  # slow polishing undulation
    nx, ny, nzz = normals(blur(h, 0.27), 4.0)

    # kissaki: its own facet, tilted towards the point
    mk = sstep(YOKOTE_X + 0.3, YOKOTE_X - 0.3, X) * sstep(-0.3, 0.3, (v - vs) * w)
    nx = nx - 0.10 * mk
    inv = 1 / np.sqrt(nx * nx + ny * ny + nzz * nzz)
    nx, ny = nx * inv, ny * inv

    # ---- brushed grain (long along the blade, very short across)
    grain = 0.75 * nz_.g(shape, 0.42, 30.0) + 0.55 * nz_.g(shape, 0.8, 90.0)
    grain_k = nz_.g(shape, 3.0, 0.6)                        # kissaki is polished across
    grain = grain * (1 - mk) + 0.18 * grain_k * mk

    # ---- environment: soft light cards mirrored in the steel (ex = where along the room)
    t = 2.0 * ny + 0.045 * grain + 0.035 * nz_.g(shape, 4.0, 70.0)
    ex = X + 150.0 * ny + 620.0 * 2 * nx + 14.0 * nz_.g(shape, 6.0, 90.0)
    gb = lambda c, s: np.exp(-0.5 * ((ex - c) / s) ** 2)
    gt = lambda c, s: np.exp(-0.5 * ((t - c) / s) ** 2)
    plate = lambda a, b, sa, sb: sstep(a - sa, a + sa, ex) * sstep(b + sb, b - sb, ex)
    K = 0.14 + 0.86 * (plate(150, 640, 70, 150) * (0.55 + 0.45 * gb(330, 130)) + 0.50 * plate(715, 930, 50, 60))
    U = 0.09 + 1.00 * plate(545, 850, 100, 60) * (0.50 + 0.50 * gb(705, 95)) + 0.55 * plate(165, 300, 28, 55)
    Fc = 0.045 + 1.00 * gb(HOTSPOT_X, 44) + 0.40 * plate(238, 480, 36, 80) + 0.32 * plate(600, 800, 60, 90) \
        + 0.20 * plate(880, 985, 36, 26)
    Rc = 0.45 + 0.55 * plate(330, 930, 160, 110)
    in_hi = hi_mask
    body = np.empty(shape + (3,), F32)
    body[...] = C(*BLADE_AMBIENT)
    hi_fade = sstep(HI_X0 - 2, HI_X0 + 30, X)
    k_lobe = gt(1.45, 0.42) * (1 - in_hi) + 0.20 * gt(1.25, 0.65) * in_hi * (0.35 + 0.65 * U / 1.1) * hi_fade
    u_lobe = gt(0.20, 0.20) * (1 - in_hi) + 0.80 * gt(0.25, 0.60) * in_hi
    for amp, col in ((L_KEY * K * k_lobe, (0.86, 0.93, 1.00)),
                     (L_UPPER * U * u_lobe, (0.58, 0.76, 1.00)),
                     (L_FILL * Fc * gt(-0.33, 0.125) * (1 - 0.6 * in_hi), (0.52, 0.72, 1.00)),
                     (L_RED * Rc * gt(-1.20, 0.46) * (1 - 0.7 * in_hi), (1.00, 0.05, 0.06))):
        body += amp[..., None].astype(F32) * C(*col)
    body *= (1.0 + GRAIN * grain)[..., None]
    hue = nz_.g(shape, 8.0, 110.0)[..., None]                # temper-colour drift: blue <-> violet
    body *= 1.0 + hue * C(0.07, -0.03, -0.02)
    body *= (1.0 - 0.50 * sstep(0.2, 1.2, hi_depth))[..., None]      # groove self-occlusion

    # ---- hamon / hardened edge (satin, clearly brighter, misty boundary)
    vh = hamon_line(x, nz_)
    dh = (v - vh) * w                                       # px below the temper line
    cloud = 0.5 + 0.5 * np.tanh(nz_.g(shape, 1.3, 5.0))
    m_ha = sstep(-1.5, 1.7, dh + 1.1 * (cloud - 0.5))
    Ih = 0.12 + 0.88 * (plate(175, 560, 85, 150) * (0.60 + 0.40 * gb(360, 95)) + 0.50 * plate(650, 905, 70, 70))
    satin = 1.0 + 0.15 * nz_.g(shape, 0.36, 12.0) + 0.05 * grain
    ha_l = (HA_BASE + HA_GAIN * Ih) * satin * (0.74 + 0.26 * sstep(4.5, 0.0, dh))
    ha = ha_l[..., None] * C(0.74, 0.84, 0.98)
    edge_t = sstep(0.82, 1.0, v)
    ha = ha * (1 - 0.32 * edge_t)[..., None] + (0.016 * edge_t * Rc)[..., None] * C(1.0, 0.05, 0.06)
    nioi = np.exp(-(dh / 1.15) ** 2) * (0.45 + 0.55 * cloud)
    mist = np.exp(np.minimum(dh, 0) / (1.2 + 2.2 * cloud)) * (dh < 0.3) * (0.3 + 0.7 * cloud)
    lin = body * (1 - 0.93 * m_ha)[..., None] + ha * m_ha[..., None]
    lin += ((0.052 * nioi + 0.022 * mist) * (0.30 + 0.70 * Ih))[..., None] * C(0.80, 0.88, 1.0)

    # kissaki polish: hazy, slightly brighter
    lin += (mk * (1 - m_ha) * 0.010 * (1 + 0.10 * grain_k))[..., None] * C(0.78, 0.87, 1.0)

    # ---- crisp lines: shinogi / ko-shinogi, yokote
    lit = 0.16 + 0.84 * np.clip(0.6 * U + 0.7 * Fc, 0, 1.25)
    ds = (v - vs) * w
    lin += (0.040 * np.exp(-(ds / 0.36) ** 2) * lit * sstep(TIP_X + 1, TIP_X + 14, X))[..., None] * C(0.80, 0.88, 1.0)
    yok = np.exp(-((X - YOKOTE_X) / 0.42) ** 2) * sstep(-0.4, 0.6, ds)
    lin += (0.040 * yok * (0.5 + 0.5 * Ih))[..., None] * C(0.85, 0.9, 1.0)

    # ---- micro scratches (mostly lengthwise)
    scr = np.zeros(shape, F32)
    for _ in range(60):
        xa = rng.uniform(95, 985)
        ln = float(np.clip(rng.lognormal(4.0, 0.7), 14, 300))
        v0, slope, amp = rng.uniform(0.07, 0.96), rng.normal(0, 0.013), rng.uniform(0.25, 1.0)
        c0, c1 = int(xa * SS), int(min(xa + ln, 1022) * SS)
        if c1 - c0 < 8:
            continue
        xx = X[:, c0:c1]
        line = np.exp(-((px[:, c0:c1] - (v0 * w[:, c0:c1] + slope * (xx - xa))) / 0.26) ** 2)
        scr[:, c0:c1] += line * np.clip(np.sin(np.pi * (xx - xa) / ln), 0, 1) ** 0.6 * amp
    lin += (scr * (0.004 + 0.12 * lin.mean(axis=2)))[..., None] * C(0.9, 0.95, 1.0)

    # ---- razor edge highlight
    eh = np.exp(-(np.clip(g['d_bot'], 0, None) / 0.42) ** 2) * (0.42 + 0.58 * Ih)
    lin += (0.95 * eh)[..., None] * C(0.96, 0.97, 1.0)

    g['hi_mask'], g['vh'] = hi_mask, vh
    return lin, g['cov']


# --------------------------------------------------------------------- blood
def render_blood(g, nz_):
    X, Y, v = g['X'], g['Y'], g['v']
    shape = X.shape
    rng = nz_.rng
    inside = g['cov'] > 0.5
    d_bot = np.clip(g['d_bot'], 0, None)

    # where the film lies: smooth lobes stretched along the cut, wiped streaks removed
    f = nz_.g(shape, 2.8, 30.0) + 0.55 * nz_.g(shape, 1.5, 10.0) + 0.15 * nz_.g(shape, 0.8, 3.2)
    f += 1.25 * np.exp(-(X - TIP_X) / 260.0) + 0.85 * (v - 0.5) + 0.30 * np.exp(-((X - 690) / 110) ** 2)
    f -= 1.8 * np.clip(nz_.g(shape, 0.95, 65.0) - 0.75, 0, None)
    tau = np.quantile(f[inside], 1.0 - BLOOD_COVER)
    d = f - tau
    gy, gx = np.gradient(d)
    dist = d / (np.sqrt(gx * gx + gy * gy) * SS + 0.03)      # ~px inside the contact line

    # how thick it is: thin smear .. film .. pooled, plus runs, groove and edge build-up
    m0 = nz_.g(shape, 2.2, 13.0)
    runs = np.clip(nz_.g(shape, 1.0, 80.0) - 0.9, 0, 1.5)
    M = 0.34 + 0.52 * sstep(-1.3, 0.2, m0) + 0.80 * sstep(0.6, 1.3, m0)
    M *= 0.72 + 0.50 * sstep(-1.0, 1.0, nz_.g(shape, 0.55, 42.0))            # smear streaks
    M += 0.55 * runs + 0.45 * g['hi_mask'] + 0.50 * np.exp(-d_bot / 1.4)
    thin = sstep(0.62, 0.25, M)
    E = np.clip(dist / (0.30 + 1.7 * thin), 0, 1).astype(F32)
    T = (M * (1 - np.exp(-np.clip(dist, 0, None) / 1.2))).astype(F32)

    def stamp(cx, cy, rx, ry, amp):
        x0, x1 = max(int((cx - rx - 1) * SS), 0), int((cx + rx + 1) * SS) + 1
        y0, y1 = max(int((cy - ry - 1) * SS), 0), int((cy + ry + 1) * SS) + 1
        rr = np.sqrt(((X[y0:y1, x0:x1] - cx) / rx) ** 2 + ((Y[y0:y1, x0:x1] - cy) / ry) ** 2)
        dome = np.sqrt(np.clip(1 - rr * rr, 0, 1))
        T[y0:y1, x0:x1] = np.maximum(T[y0:y1, x0:x1], amp * dome ** 0.7)
        E[y0:y1, x0:x1] = np.maximum(E[y0:y1, x0:x1], np.clip((1 - rr) * min(rx, ry) * SS + 0.5, 0, 1))

    xs = g['x']
    for _ in range(120):                                    # droplets / spatter
        cx = TIP_X + 6 + (1000 - TIP_X) * rng.uniform() ** 1.4
        i = int(cx * SS)
        cy = g['ysp'][0, i] + rng.uniform(0.08, 0.95) * g['w'][0, i]
        r = float(np.clip(rng.lognormal(-0.20, 0.45), 0.4, 2.2))
        stamp(cx, cy, r * rng.uniform(1.0, 2.2), r, rng.uniform(0.7, 1.3))
    bead_cov = np.zeros(shape, F32)
    bead_h = np.zeros(shape, F32)
    for xb, drop, r in BEADS:                               # vertical runs feeding hanging beads
        ye = float(np.interp(xb, xs, g['yed1']))
        wb = float(np.interp(xb, xs, g['w'][0]))
        x0, x1 = int((xb - 7) * SS), int((xb + 7) * SS)
        y0, y1 = int((ye - wb) * SS), int((ye + drop + 2) * SS)
        xx, yy = X[y0:y1, x0:x1], Y[y0:y1, x0:x1]
        dx = xx - xb - 0.8 * np.sin((yy - ye) / 3.1 + xb)
        top = ye - wb * rng.uniform(0.45, 0.7)
        run = np.exp(-(dx / (0.75 + 0.5 * sstep(top, ye, yy))) ** 2) * sstep(top - 2, top + 2, yy) * (yy < ye + 0.5)
        T[y0:y1, x0:x1] = np.maximum(T[y0:y1, x0:x1], 1.2 * run)
        E[y0:y1, x0:x1] = np.maximum(E[y0:y1, x0:x1], np.clip(run * 4 - 1.2, 0, 1))
        yc = ye + drop - r
        dxb = xx - xb
        tn = np.clip((yy - (ye - 1.0)) / (yc - ye + 1.0), 0, 1)
        hw = (0.50 + 0.50 * tn ** 1.7) * r
        sd = np.where(yy <= yc, np.where(yy >= ye - 1.0, hw - np.abs(dxb), -9.0), r - np.sqrt(dxb ** 2 + (yy - yc) ** 2))
        hb = np.where(yy <= yc, np.sqrt(np.clip(1 - (dxb / hw) ** 2, 0, 1)) * hw,
                      np.sqrt(np.clip(r * r - dxb ** 2 - (yy - yc) ** 2, 0, None)))
        bead_cov[y0:y1, x0:x1] = np.clip(sd * SS + 0.5, 0, 1)
        bead_h[y0:y1, x0:x1] = hb * (sd > -0.3)

    # ---- wet shading from the film's height
    n = normals(blur(T, 0.28) * 1.0 + bead_h, 5.0)
    rx, ry, rz = 2 * n[2] * n[0], 2 * n[2] * n[1], 2 * n[2] * n[2] - 1
    kd = unit(KEY_DIR)
    rdl = rx * kd[0] + ry * kd[1] + rz * kd[2]
    Tb = np.maximum(T, bead_h * 0.8)
    wetmask = sstep(-0.2, 1.0, nz_.g(shape, 1.6, 5.0)) * sstep(0.35, 0.8, Tb)
    glint = np.exp(np.minimum((rdl - 1) / 0.0035, 0)) * 0.85 * wetmask
    sheen = np.exp(np.minimum((rdl - 1) / 0.10, 0)) * 0.011 * sstep(0.4, 1.1, Tb)
    thin_c, mid_c, deep_c = srgb_to_lin(BLOOD_THIN), srgb_to_lin(BLOOD_MID), srgb_to_lin(BLOOD_DEEP)
    a1 = sstep(0.12, 0.55, Tb)[..., None]
    a2 = sstep(0.55, 1.25, Tb)[..., None]
    col = thin_c * (1 - a1) + mid_c * a1
    col = col * (1 - a2) + deep_c * a2
    col = col * (0.88 + 0.22 * np.clip(n[1], -0.6, 0.6) + 0.07 * nz_.g(shape, 2.0, 6.0))[..., None]
    alpha = E * (0.56 + 0.41 * (1 - np.exp(-2.6 * T))) * g['cov']
    alpha = np.maximum(alpha, bead_cov * 0.96)
    present = np.maximum(E * g['cov'], bead_cov)
    spec = (glint + sheen) * present
    pm = col * alpha[..., None] + (glint * present)[..., None] * np.asarray((1.0, 0.90, 0.86), F32) \
        + (sheen * present)[..., None] * np.asarray((1.0, 0.30, 0.26), F32)
    a_out = np.clip(alpha + spec * 0.9, 0, 1)
    g['blood_cover'] = float((E[inside] > 0.5).mean())
    return pm / np.maximum(a_out, 1e-4)[..., None], a_out


# ---------------------------------------------------------------------- hilt
GOLD = np.array((1.00, 0.72, 0.33), F32)
COPPER_GOLD = np.array((0.96, 0.62, 0.31), F32)
BRASS = np.array((0.84, 0.63, 0.30), F32)
STEEL = np.array((0.52, 0.53, 0.56), F32)
SILK_D = np.array((0.011, 0.011, 0.013), F32)
SILK_F = np.array((0.068, 0.068, 0.076), F32)


class Canvas:
    """Premultiplied accumulation buffer for region C (x 0..512, y 256..512)."""

    def __init__(self):
        self.pm = np.zeros((256 * SS, 512 * SS, 3), F32)
        self.a = np.zeros((256 * SS, 512 * SS), F32)

    def sl(self, x0, y0, x1, y1):
        return (slice(int((y0 - 256) * SS), int((y1 - 256) * SS)), slice(int(x0 * SS), int(x1 * SS)))

    def over(self, box, rgb, cov):
        s = self.sl(*box)
        c = np.nan_to_num(cov)[..., None]
        self.pm[s] = np.nan_to_num(rgb) * c + self.pm[s] * (1 - c)
        self.a[s] = c[..., 0] + self.a[s] * (1 - c[..., 0])

    def darken(self, box, k):
        s = self.sl(*box)
        self.pm[s] *= k[..., None]


def span(X, xa, xb):
    return np.clip((X - xa) * SS + 0.5, 0, 1) * np.clip((xb - X) * SS + 0.5, 0, 1)


def near(X, x0, scale):
    """Contact-occlusion falloff away from a junction at x0 (one-sided use)."""
    return np.exp(-np.clip(np.abs(X - x0), 0, None) / scale)


def part_habaki(cv, nz_):
    box = (12, 360, 50, 408)
    X, Y = grid(*box)
    shape = X.shape
    dy = Y - AXIS_Y
    ay = np.abs(dy)
    xa, xb = HABAKI
    hh = 16.4 + 1.6 * np.clip((X - xa) / (xb - xa), 0, 1.2)          # 32.8 -> 36 px tall wedge
    yn = np.clip(ay / hh, 0, 1)
    z = 9.0 * (1 - yn ** 2.3) ** 0.5
    z += 0.5 * np.exp(-((dy + 3.5) / 4.5) ** 2)                      # follows the blade's ridge
    s = np.clip((X - xa) / 2.6, 0, 1)
    z *= 1 - 0.50 * (1 - s) ** 2                                     # front lip chamfer
    # diagonal file marks (neko-gaki) inside a polished frame
    c = (0.866 * X + 0.5 * Y + 0.6 * nz_.g(shape, 6.0, 6.0)) / 2.7
    idx = np.floor(c)
    f = c - idx
    depth = 0.06 + 0.12 * hash01(idx, 3.0)
    frame = sstep(2.0, 3.4, X - xa) * sstep(1.4, 2.6, xb - X) * sstep(2.2, 3.6, hh - ay)
    marks = depth * (1 - np.abs(2 * f - 1)) ** 1.3 * frame
    z -= marks
    z += 0.04 * nz_.g(shape, 0.5, 0.5)
    n = normals(blur(z, 0.2))
    tarn = sstep(-0.6, 1.3, nz_.g(shape, 3.0, 4.0) + 0.5 * nz_.g(shape, 0.8, 0.8))
    cav = np.clip(marks / 0.14, 0, 1)
    f0 = COPPER_GOLD * (0.80 - 0.34 * tarn - 0.20 * cav)[..., None]
    f0 = f0 * (1 - 0.20 * tarn[..., None] * np.asarray((0.0, 0.5, 1.0), F32))
    diff = np.asarray((0.030, 0.016, 0.008), F32) * (0.5 + tarn + cav)[..., None]
    rough = 0.22 + 0.14 * tarn + 0.10 * cav
    ao = (1 - 0.60 * near(X, xb, 2.4)) * (1 - 0.25 * cav)
    rgb = shade(n, diff, f0, rough, ao)
    cov = span(X, xa, xb + 1) * np.clip((hh - ay) * SS + 0.5, 0, 1)
    cv.over(box, rgb, cov.astype(F32))


def part_seppa(cv, nz_, xr):
    xa, xb = xr
    box = (xa - 2, 356, xb + 2, 412)
    X, Y = grid(*box)
    dy = Y - AXIS_Y
    tt = np.clip(np.abs(X - 0.5 * (xa + xb)) / (0.5 * (xb - xa)), 0, 1)
    rim = 1 - np.sqrt(1 - 0.94 * tt * tt)
    hh = 24.0 - 1.2 * rim
    yn = np.clip(dy / hh, -1, 1)
    z = (15.0 - 1.5 * rim) * np.sqrt(1 - yn * yn)
    z += 0.15 * np.cos(2 * np.pi * hh * np.arcsin(yn) / 2.3) * (1 - tt ** 4)   # coin-edge notches
    n = normals(blur(z, 0.15))
    tarn = sstep(-0.8, 1.2, nz_.g(X.shape, 2.0, 1.0))
    f0 = BRASS * (0.66 - 0.28 * tarn)[..., None]
    diff = np.asarray((0.030, 0.020, 0.008), F32) * (0.6 + tarn)[..., None]
    ao = 0.78 - 0.26 * tt
    rgb = shade(n, diff, f0, 0.26 + 0.12 * tarn, ao)
    cov = span(X, xa, xb) * np.clip((hh - np.abs(dy)) * SS + 0.5, 0, 1)
    cv.over(box, rgb, cov.astype(F32))


def part_tsuba(cv, nz_):
    xa, xb = TSUBA
    box = (xa - 2, 328, xb + 2, 440)
    X, Y = grid(*box)
    shape = X.shape
    dy = Y - AXIS_Y
    de = np.minimum(X - xa, xb - X)                                   # distance from the faces
    tt = np.clip(1 - de / 5.0, 0, 1)
    fil = 5.0 * (1 - np.sqrt(1 - 0.97 * tt * tt))                     # rounded rim corners
    hh = 52.0 - fil
    yn = np.clip(dy / hh, -1, 1)
    z = (40.0 - fil) * np.sqrt(1 - yn * yn)
    z += 1.3 * (1 - ((X - 0.5 * (xa + xb)) / 12.0) ** 2)              # slightly barrelled rim
    # tsuchime: overlapping hammer bowls on a jittered grid (in rim arc-length coordinates)
    S, gp = 52.0 * np.arcsin(yn), 4.3
    ci, cj = np.floor(X / gp), np.floor(S / gp)
    bowl = np.zeros(shape, F32)
    for oi in (-1, 0, 1):
        for oj in (-1, 0, 1):
            i, j = ci + oi, cj + oj
            bx = (i + 0.5 + 0.85 * (hash01(i, j, 11.0) - 0.5)) * gp
            by = (j + 0.5 + 0.85 * (hash01(i, j, 12.0) - 0.5)) * gp
            r = gp * (0.45 + 0.30 * hash01(i, j, 13.0))
            dep = (0.16 + 0.24 * hash01(i, j, 14.0)) * np.clip(1 - ((X - bx) ** 2 + (S - by) ** 2) / (r * r), 0, 1) ** 1.5
            bowl = np.maximum(bowl, dep)
    ham = -bowl + 0.10 * nz_.g(shape, 3.0, 3.0) + 0.035 * nz_.g(shape, 0.45, 0.45)
    z += ham
    n = normals(blur(z, 0.2), 7.0)
    wear = np.exp(-((tt - 0.62) / 0.20) ** 2) * sstep(-0.9, 1.0, nz_.g(shape, 5.0, 0.6) + 0.4 * (ham + 0.2) / 0.2) * 0.9
    rust = sstep(0.2, 1.6, nz_.g(shape, 2.5, 2.5))
    diff = np.asarray((0.014, 0.013, 0.013), F32) * (1 - wear)[..., None] \
        + (rust * (1 - wear))[..., None] * np.asarray((0.007, 0.003, 0.001), F32) \
        + wear[..., None] * np.asarray((0.105, 0.105, 0.115), F32)      # bare, scuffed steel
    f0 = np.asarray((0.085, 0.083, 0.088), F32) * (1 - wear)[..., None] + STEEL * wear[..., None]
    rough = 0.29 - 0.06 * wear + 0.07 * rust
    ao = np.clip(1 + 0.9 * (ham - blur(ham, 1.6)), 0.6, 1.1)
    rgb = shade(n, diff, f0, rough, ao, fres=0.35)
    cov = span(X, xa, xb) * np.clip((hh - np.abs(dy)) * SS + 0.5, 0, 1)
    cv.over(box, rgb, cov.astype(F32))


def nanako(X, s, pitch=2.3, hgt=0.15):
    """Fish-roe punch texture on a hex grid in (x, arc-length) coordinates."""
    ry = pitch * 0.866
    row = np.floor(s / ry)
    xo = X + 0.5 * pitch * np.mod(row, 2)
    fx = (xo / pitch - np.floor(xo / pitch) - 0.5) * pitch
    fy = (s / ry - row - 0.5) * ry
    return hgt * np.sqrt(np.clip(1 - (fx * fx + fy * fy) / (0.47 * pitch) ** 2, 0, 1))


def dark_metal(shape, nz_, wear, gold):
    """Shakudo-like blue-black alloy with worn edges and gold inlay masks."""
    pat = sstep(-1.0, 1.0, nz_.g(shape, 2.5, 2.5))
    diff = np.asarray((0.006, 0.007, 0.010), F32) * (0.7 + 0.6 * pat)[..., None]
    f0 = np.asarray((0.056, 0.061, 0.082), F32) * (0.8 + 0.4 * pat)[..., None]
    f0 = f0 * (1 - wear)[..., None] + np.asarray((0.42, 0.34, 0.26), F32) * wear[..., None]
    diff = diff + wear[..., None] * np.asarray((0.05, 0.04, 0.03), F32)
    f0 = f0 * (1 - gold)[..., None] + GOLD * (0.70 * gold)[..., None]
    diff = diff * (1 - gold)[..., None]
    rough = 0.25 + 0.08 * pat - 0.05 * gold
    return diff, f0, rough


def part_fuchi(cv, nz_):
    xa, xb = FUCHI
    box = (xa - 2, 360, xb + 2, 408)
    X, Y = grid(*box)
    shape = X.shape
    dy = Y - AXIS_Y
    de = np.minimum(X - xa, xb - X)
    tt = np.clip(1 - de / 1.4, 0, 1)
    fil = 1.4 * (1 - np.sqrt(1 - 0.95 * tt * tt))
    hh = 20.0 - fil
    yn = np.clip(dy / hh, -1, 1)
    gold = span(X, xa + 3.2, xa + 4.7) * 1.0
    s = 20.0 * np.arcsin(yn)
    z = (15.0 - fil) * np.sqrt(1 - yn * yn)
    z += nanako(X, s) * (1 - sstep(0.5, 1.0, span(X, xa + 2.2, xa + 5.7))) * sstep(0.0, 1.5, de - 1.0)
    z += 0.22 * gold - 0.25 * (span(X, xa + 2.5, xa + 3.2) + span(X, xa + 4.7, xa + 5.4))
    n = normals(blur(z, 0.17))
    wear = sstep(0.3, 0.9, tt) * sstep(-0.6, 1.0, nz_.g(shape, 2.5, 0.8)) * 0.7
    diff, f0, rough = dark_metal(shape, nz_, wear, np.clip(gold, 0, 1))
    ao = (1 - 0.50 * near(X, xa, 2.2)) * (1 - 0.20 * near(X, xb, 1.5))
    rgb = shade(n, diff, f0, rough, ao)
    cov = span(X, xa, xb) * np.clip((hh - np.abs(dy)) * SS + 0.5, 0, 1)
    cv.over(box, rgb, cov.astype(F32))


def part_kashira(cv, nz_):
    xa, xb = KASHIRA
    box = (xa - 2, 360, xb + 2, 408)
    X, Y = grid(*box)
    shape = X.shape
    dy = Y - AXIS_Y
    tt = np.clip(1 - np.abs(X - xa) / 1.4, 0, 1)
    fil = 1.4 * (1 - np.sqrt(1 - 0.95 * tt * tt))
    e = np.clip((X - (xb - 13.0)) / 13.0, 0, 1)
    cap = (1 - e ** 3.0) ** (1 / 3.0)                                 # rounded end
    hh = 20.0 * cap - fil
    yn = np.clip(dy / np.maximum(hh, 0.3), -1, 1)
    z = (15.0 - fil) * cap * np.sqrt(1 - yn * yn)
    s = 20.0 * np.arcsin(yn)
    gold = span(X, xa + 2.6, xa + 4.0)
    # shitodome: gold-rimmed eyelet the cord passes through
    rr = np.sqrt(((X - (xa + 10.6)) / 4.5) ** 2 + (dy / 6.2) ** 2)
    ring = sstep(0.62, 0.72, rr) * sstep(1.02, 0.92, rr)
    hole = sstep(0.70, 0.60, rr)
    z += nanako(X, s) * (1 - sstep(0.4, 1.0, span(X, xa + 1.8, xa + 4.8))) * sstep(1.12, 1.25, rr) * (1 - e ** 2)
    z += 0.22 * gold + 0.8 * np.sqrt(np.clip(1 - ((rr - 0.82) / 0.21) ** 2, 0, 1)) - 2.2 * hole
    n = normals(blur(z, 0.17), 7.0)
    wear = np.maximum(sstep(0.3, 0.9, tt), sstep(0.75, 1.0, e)) * sstep(-0.6, 1.0, nz_.g(shape, 2.0, 1.2)) * 0.6
    diff, f0, rough = dark_metal(shape, nz_, wear, np.clip(gold + 0.85 * ring, 0, 1))
    ao = (1 - 0.40 * near(X, xa, 1.8)) * (1 - 0.90 * hole) * (1 - 0.3 * sstep(1.3, 1.0, rr) * (1 - ring))
    rgb = shade(n, diff, f0, rough, ao)
    cov = span(X, xa, xb + 1) * np.clip((hh - np.abs(dy)) * SS + 0.5, 0, 1)
    cv.over(box, rgb, cov.astype(F32))


def cord_material(a, d, b, nz_, shape, seed):
    """Braided silk: chevron ribs + fibre noise. Returns (detail height, albedo scale)."""
    ph = 2 * np.pi * (a - 0.95 * np.abs(d)) / 2.7 + seed
    rib = np.cos(ph)
    fib = nz_.g(shape, 0.4, 0.4)
    det = (0.16 * rib + 0.06 * fib) * np.clip(1 - b ** 4, 0, 1) - 0.13 * np.exp(-(d / 0.55) ** 2)
    alb = 1.0 + 0.10 * np.cos(ph + 0.9) + 0.10 * fib
    return det, alb


def part_tsuka(cv, nz_):
    xa, xb = TSUKA
    box = (xa - 2, 360, xb + 4, 408)
    X, Y = grid(*box)
    shape = X.shape
    dy = Y - AXIS_Y
    xm, half_len = 0.5 * (xa + xb), 0.5 * (xb - xa)
    hhT = 18.1 + 1.15 * ((X - xm) / half_len) ** 2                    # 36.2 mid -> 38.5 px at the ends
    yn = np.clip(dy / hhT, -1, 1)
    beta, HQ = 0.55, 21.0
    Q = ((1 - beta) * yn + beta * (2 / np.pi) * np.arcsin(yn)) * HQ   # unrolled surface coordinate
    P = (xb - xa) / N_DIAMONDS
    k0 = np.round((X - xa) / P)
    m = CORD_SLOPE
    inv = 1 / np.sqrt(1 + m * m)
    zc = np.zeros(shape, F32)
    aw, dw, bw, sw = (np.zeros(shape, F32) for _ in range(4))
    for off in (-1, 0, 1):
        kk = k0 + off
        dx = X - (xa + kk * P)
        even = np.mod(kk, 2) == 0
        for t in (1.0, -1.0):
            d = (Q - t * m * dx) * inv
            a = (dx + t * m * Q) * inv
            pin = np.exp(-(a / 6.5) ** 2)
            flare = sstep(9.0, 20.0, np.abs(a))
            half = 0.5 * CORD_W * (1 - 0.16 * pin + 0.34 * flare)
            b = d / half
            prof = np.clip(1 - np.abs(b) ** 2.3, 0, 1) ** 0.62
            top = even == (t > 0)
            lift = np.where(top, 1.05, 0.0) * np.exp(-(a / 7.0) ** 2) * CORD_T
            lift = lift + 0.3 * CORD_T * flare * np.where(t * a > 0, 1.0, 0.0)
            zb = (CORD_T * (1 + 0.22 * pin) * prof + lift) * (np.abs(b) < 1)
            better = zb > zc
            zc = np.where(better, zb, zc)
            aw, dw, bw = np.where(better, a, aw), np.where(better, d, dw), np.where(better, b, bw)
            sw = np.where(better, hash01(kk, t) * 6.28, sw)
    cord = sstep(0.05, 0.5, zc)

    # ---- samegawa nodules (jittered grid in the unrolled surface)
    gp = 2.55
    ci, cj = np.floor(X / gp), np.floor(Q / gp)
    nod = np.zeros(shape, F32)
    pale = np.zeros(shape, F32)
    for oi in (-1, 0, 1):
        for oj in (-1, 0, 1):
            i, j = ci + oi, cj + oj
            px_ = (i + 0.5 + 0.62 * (hash01(i, j, 1.0) - 0.5)) * gp
            py_ = (j + 0.5 + 0.62 * (hash01(i, j, 2.0) - 0.5)) * gp
            r = gp * (0.34 + 0.20 * hash01(i, j, 3.0))
            dome = np.sqrt(np.clip(1 - ((X - px_) ** 2 + (Q - py_) ** 2) / (r * r), 0, 1)) * r * 0.6
            better = dome > nod
            nod = np.where(better, dome, nod)
            pale = np.where(better, hash01(i, j, 4.0) ** 2.2, pale)

    # ---- menuki: small antique-gold relief under the wrap (bamboo stalk with leaves)
    mx = X - MENUKI_X
    ys_ = dy - 0.05 * mx + 0.4
    zm = 2.4 * np.sqrt(np.clip(1 - (ys_ / 2.7) ** 2, 0, 1)) * np.sqrt(np.clip(1 - (mx / 19.5) ** 6, 0, 1))
    zm *= 1 + 0.22 * np.exp(-((np.mod(mx + 4.0, 9.0) - 4.5) / 0.75) ** 2) \
        - 0.18 * np.exp(-((np.mod(mx + 5.7, 9.0) - 4.5) / 0.5) ** 2)
    for lx_, ly_, ang, ln in ((-5.0, -4.3, -0.50, 6.0), (4.5, 4.6, -0.45, 5.5), (-12.5, 3.9, 0.50, 5.0), (12.5, -3.6, 0.50, 5.0)):
        ca, sa = np.cos(ang), np.sin(ang)
        u_ = (mx - lx_) * ca + (dy - ly_) * sa
        v_ = -(mx - lx_) * sa + (dy - ly_) * ca
        leaf = np.sqrt(np.clip(1 - (u_ / ln) ** 2 - (v_ / 1.7) ** 2, 0, 1))
        zm = np.maximum(zm, 1.35 * leaf - 0.3 * np.exp(-(v_ / 0.4) ** 2) * (leaf > 0))
    zm = np.clip(zm, 0, None)
    men = sstep(0.05, 0.35, zm) * (1 - cord)

    # ---- combine heights (cord level = nominal surface)
    det_c, alb_c = cord_material(aw, dw, bw, nz_, shape, sw)
    cord_h = zc + det_c * cord + 0.55 * blur(zm, 1.2) * cord
    open_h = np.maximum(nod, zm)
    detail = np.where(cord > 0.5, cord_h, open_h) - CORD_T
    z = 16.0 * np.sqrt(1 - yn * yn) + detail
    n = normals(blur(z, 0.16), 7.0)

    # occlusion: cavities + shadow thrown by the cords from the key light above
    cav = np.maximum(blur(detail, 1.3) - detail, 0) + 0.6 * np.maximum(blur(detail, 0.5) - detail, 0)
    ao = np.clip(1 - 0.52 * cav, 0.18, 1.0)
    shadow = np.zeros(shape, F32)
    for kpx, wgt in ((0.75, 0.40), (1.5, 0.30), (2.25, 0.20), (3.0, 0.10)):
        sh = np.roll(zc, int(round(kpx * SS)), axis=0)
        shadow += wgt * np.clip((sh - zc) / CORD_T, 0, 1)
    key_vis = 1 - 0.85 * blur(shadow, 0.35)
    ao = ao * (1 - 0.40 * near(X, xa, 2.2)) * (1 - 0.40 * near(X, xb, 2.2))

    # ---- materials
    strand_tone = 0.85 + 0.3 * hash01(np.round(sw * 40), 5.0)
    d_cord = SILK_D * (alb_c * strand_tone)[..., None]
    f_cord = SILK_F * (0.75 + 0.4 * alb_c)[..., None]
    top_t = np.clip(nod / (gp * 0.3), 0, 1) ** 1.5 * pale
    d_same = np.asarray((0.052, 0.0030, 0.0048), F32) * (1 - top_t)[..., None] \
        + np.asarray((0.27, 0.115, 0.09), F32) * top_t[..., None]
    d_same = d_same * (0.8 + 0.2 * nz_.g(shape, 3.0, 3.0))[..., None]
    c3, m3 = cord[..., None], men[..., None]
    mcav = np.clip(0.5 + 1.2 * (blur(zm, 0.9) - zm), 0, 1)[..., None]            # recesses hold dark patina
    f_men = GOLD * (0.62 - 0.44 * mcav)
    diff = d_cord * c3 + (d_same * (1 - m3) + np.asarray((0.030, 0.017, 0.006), F32) * m3) * (1 - c3)
    f0 = f_cord * c3 + (np.asarray((0.05, 0.035, 0.035), F32) * (1 - m3) + f_men * m3) * (1 - c3)
    rough = 0.27 * cord + (0.20 * (1 - men) + 0.16 * men) * (1 - cord)
    rgb = shade(n, diff, f0, rough, ao, key_vis=key_vis, limb=1.0)

    # silhouette follows the cord height where it wraps over the edge
    hs = shape[0]
    top_i = np.clip(((AXIS_Y - 0.96 * hhT[0] - box[1]) * SS).astype(int), 0, hs - 1)
    bot_i = np.clip(((AXIS_Y + 0.96 * hhT[0] - box[1]) * SS).astype(int), 0, hs - 1)
    cols = np.arange(shape[1])
    lim_t = ndi.gaussian_filter1d(np.minimum(zc[top_i, cols], CORD_T), 0.6 * SS)
    lim_b = ndi.gaussian_filter1d(np.minimum(zc[bot_i, cols], CORD_T), 0.6 * SS)
    hh_eff = hhT - (CORD_T - np.where(dy < 0, lim_t[None, :], lim_b[None, :])) * 0.85
    cov = span(X, xa - 1, xb + 1) * np.clip((hh_eff - np.abs(dy)) * SS + 0.5, 0, 1)
    cv.over(box, rgb, cov.astype(F32))


def part_knot(cv, nz_):
    """Makidome: two strands running into the kashira eyelet out of a small knot."""
    kx = KASHIRA[0]
    box = (kx - 26, 366, kx + 14, 402)
    X, Y = grid(*box)
    shape = X.shape
    dy = Y - AXIS_Y
    yn = np.clip(dy / 19.8, -1, 1)
    zbase = 16.0 * np.sqrt(1 - yn * yn)
    x_end, lx = kx + 10.2, kx - 13.4
    # the two strands
    zh, dh_, bh = (np.zeros(shape, F32) for _ in range(3))
    for cy in (-2.3, 2.3):
        b = (dy - cy) / 2.4
        zs = (CORD_T * 0.95 * np.clip(1 - np.abs(b) ** 2.3, 0, 1) ** 0.62 + 0.4 * CORD_T) * (np.abs(b) < 1)
        better = zs > zh
        zh = np.where(better, zs, zh)
        dh_, bh = np.where(better, dy - cy, dh_), np.where(better, b, bh)
    covh = sstep(0.05, 0.5, zh) * span(X, lx, x_end) * np.clip((x_end - X) / 2.5, 0, 1) ** 0.5
    # the knot: one tight diagonal turn over the strands
    ux = (X - lx) * 0.88 + dy * 0.47
    uy = -(X - lx) * 0.47 + dy * 0.88
    rk = np.sqrt((ux / 4.3) ** 2 + (uy / 7.4) ** 2)
    zl = (CORD_T * (0.9 + 1.5 * np.sqrt(np.clip(1 - rk ** 2.5, 0, 1))) - 0.55 * np.exp(-(ux / 0.6) ** 2)) * (rk < 1)
    covl = np.clip((1 - rk) * 4.3 * SS + 0.5, 0, 1)
    is_knot = covl > 0.5
    zk = np.where(is_knot, zl, zh)
    det, alb = cord_material(np.where(is_knot, uy, X - lx), np.where(is_knot, np.abs(ux) - 2.1, dh_),
                             np.where(is_knot, (np.abs(ux) - 2.1) / 2.2, bh), nz_, shape, 1.7)
    cov = np.maximum(covh, covl)
    n = normals(blur(zbase + zk + det, 0.16), 7.0)
    ao = np.clip(1 - 0.40 * np.maximum(blur(zk, 1.2) - zk, 0), 0.3, 1.0)
    rgb = shade(n, SILK_D * alb[..., None], SILK_F * (0.75 + 0.4 * alb)[..., None], 0.27, ao, limb=1.0)
    # contact shadow on whatever lies beneath
    occ = np.maximum(blur(cov, 1.0), np.roll(blur(cov, 0.6), int(1.5 * SS), axis=0))
    cv.darken(box, 1 - 0.60 * occ * (1 - cov))
    cv.over(box, rgb, (cov * (cv.a[cv.sl(*box)] > 0.5)).astype(F32))


def render_hilt(nz_):
    cv = Canvas()
    part_tsuka(cv, nz_)
    part_habaki(cv, nz_)
    part_fuchi(cv, nz_)
    part_kashira(cv, nz_)
    part_knot(cv, nz_)
    part_seppa(cv, nz_, SEPPA1)
    part_seppa(cv, nz_, SEPPA2)
    part_tsuba(cv, nz_)
    return cv.pm / np.maximum(cv.a, 1e-5)[..., None], cv.a


# ------------------------------------------------------------------ assembly
def downsample(rgb, a):
    """Premultiplied filtering with a non-negative (Hamming) kernel -> straight colour."""
    size = (a.shape[1] // SS, a.shape[0] // SS)
    rs = lambda c: np.asarray(Image.fromarray(np.ascontiguousarray(c, dtype=F32)).resize(size, Image.HAMMING))
    rgb, a = np.nan_to_num(rgb), np.nan_to_num(a)
    al = rs(a)
    out = np.stack([rs(rgb[..., i] * a) for i in range(3)], -1)
    return out / np.maximum(al, 1e-5)[..., None], np.clip(al, 0, 1)


def bleed(rgb8, a8, regions):
    """Give every fully transparent texel the colour of the nearest visible one (per region)."""
    for x0, y0, x1, y1 in regions:
        m = a8[y0:y1, x0:x1] > 0
        if not m.any():
            continue
        idx = ndi.distance_transform_edt(~m, return_distances=False, return_indices=True)
        sub = rgb8[y0:y1, x0:x1]
        rgb8[y0:y1, x0:x1] = sub[idx[0], idx[1]]
    return rgb8


def build(verbose=False):
    lin = np.zeros((OUT_H, OUT_W, 3), F32)
    alpha = np.zeros((OUT_H, OUT_W), F32)
    g = blade_geometry()
    c, a = downsample(*render_blade(g, Noise(SEED)))
    lin[0:128], alpha[0:128] = c, a
    c, a = downsample(*render_blood(g, Noise(SEED + 1)))
    lin[128:256], alpha[128:256] = c, a
    c, a = downsample(*render_hilt(Noise(SEED + 2)))
    lin[256:512, 0:512], alpha[256:512, 0:512] = c, a
    if verbose:
        print('blood coverage of the blade: %.0f%%' % (100 * g['blood_cover']))

    srgb = tonemap(lin)
    grain = np.random.default_rng(SEED + 3).standard_normal((OUT_H, OUT_W, 1)) * (0.45 / 255.0)
    rgb8 = np.clip(np.rint((srgb + grain) * 255.0), 0, 255).astype(np.uint8)
    a8 = np.clip(np.rint(alpha * 255.0), 0, 255).astype(np.uint8)
    rgb8 = bleed(rgb8, a8, ((0, 0, 1024, 128), (0, 128, 1024, 256), (0, 256, 1024, 512)))
    return np.dstack([rgb8, a8])


def write_previews(rgba, folder):
    a = rgba[..., 3:4].astype(np.float32) / 255.0
    for name, bg in (('preview_dark.png', BG_DARK), ('preview_grey.png', (128, 128, 128))):
        comp = rgba[..., :3] * a + np.asarray(bg, np.float32) * (1 - a)
        Image.fromarray(np.rint(comp).astype(np.uint8), 'RGB').save(os.path.join(folder, name))


def main():
    t0 = time.time()
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    here = os.path.dirname(os.path.abspath(__file__))
    out = args[0] if args else os.path.join(here, '..', 'assets', 'zero_katana.png')
    rgba = build(verbose=True)
    Image.fromarray(rgba, 'RGBA').save(out, optimize=True, compress_level=9)
    if '--preview' in sys.argv:
        write_previews(rgba, os.path.dirname(os.path.abspath(out)))
    print('wrote %s  %dx%d  %d bytes  %.1fs' % (out, rgba.shape[1], rgba.shape[0], os.path.getsize(out), time.time() - t0))


if __name__ == '__main__':
    main()
