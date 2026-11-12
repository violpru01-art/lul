#!/usr/bin/env python3
"""Procedural blood textures for ZeroIntro.lua.

Writes three 1024x1024 RGBA atlases (straight alpha) into ../assets:

    zero_blots_a.png   4 large impact blots, 512x512 cells
    zero_blots_b.png   4 more blots, 512x512 cells
    zero_blood_fx.png  sprays, drips, droplets and a soft "bleed" blot

Every shape is built as a signed distance field (blobs, crown spikes,
satellite drops), then shaded as a wet liquid: a meniscus height map gives
normals for a rim highlight, thickness drives the colour from bright thin
films to almost black pools.  The cell layout below is mirrored by the
ATLAS table in ZeroIntro.lua - keep both in sync.

    python3 tools/gen_blood.py [output_dir] [--preview preview.png]

Requires numpy, scipy and pillow.
"""
import math
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage as ndi

SS = 2            # supersampling factor
CELL = 512        # blot cell size in the atlas
SEED = 20261112

# Light from the upper left, viewer straight on.
LIGHT = np.array([-0.38, -0.72, 0.58])
LIGHT /= np.linalg.norm(LIGHT)
HALF = LIGHT + np.array([0.0, 0.0, 1.0])
HALF /= np.linalg.norm(HALF)

THIN = np.array([160.0, 12.0, 16.0])    # thin film
MID = np.array([102.0, 5.0, 9.0])
DEEP = np.array([52.0, 1.0, 4.0])       # thick pool
SPEC = np.array([255.0, 214.0, 202.0])
SHADOW = np.array([9.0, 0.0, 1.0])
TAU = math.tau


def smin(a, b, k):
    """Polynomial smooth minimum: fillets where two shapes meet."""
    if k <= 0:
        return np.minimum(a, b)
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0.0, 1.0)
    return b + (a - b) * h - k * h * (1.0 - h)


class Field:
    """Signed distance field (negative inside) built from simple primitives."""

    def __init__(self, w, h):
        self.w, self.h = w, h
        self.sd = np.full((h, w), 1e4, np.float32)
        self.yy, self.xx = np.mgrid[0:h, 0:w].astype(np.float32)

    def _win(self, x0, y0, x1, y1, pad):
        xa, xb = max(int(x0 - pad), 0), min(int(x1 + pad) + 2, self.w)
        ya, yb = max(int(y0 - pad), 0), min(int(y1 + pad) + 2, self.h)
        if xa >= xb or ya >= yb:
            return None
        return slice(ya, yb), slice(xa, xb)

    def circle(self, cx, cy, r, k=0.0):
        win = self._win(cx - r, cy - r, cx + r, cy + r, k + 2)
        if win is None:
            return
        d = np.hypot(self.xx[win] - cx, self.yy[win] - cy) - r
        self.sd[win] = smin(self.sd[win], d, k)

    def cone(self, ax, ay, bx, by, ra, rb, k=0.0):
        """Capsule whose radius goes from ra at A to rb at B."""
        pad = max(ra, rb) + k + 2
        win = self._win(min(ax, bx), min(ay, by), max(ax, bx), max(ay, by), pad)
        if win is None:
            return
        px, py = self.xx[win] - ax, self.yy[win] - ay
        dx, dy = bx - ax, by - ay
        t = np.clip((px * dx + py * dy) / (dx * dx + dy * dy + 1e-6), 0.0, 1.0)
        d = np.hypot(px - t * dx, py - t * dy) - (ra + (rb - ra) * t)
        self.sd[win] = smin(self.sd[win], d, k)

    def lobe(self, cx, cy, r, harmonics, k=0.0):
        """Disc with a wobbly outline; harmonics = [(frequency, amplitude, phase)]."""
        dx, dy = self.xx - cx, self.yy - cy
        th = np.arctan2(dy, dx)
        rr = np.full_like(th, 1.0)
        for f, a, p in harmonics:
            rr += a * np.sin(f * th + p)
        self.sd = smin(self.sd, np.hypot(dx, dy) - r * rr, k)


def lobe_radius(r, harmonics, th):
    return r * (1.0 + sum(a * math.sin(f * th + p) for f, a, p in harmonics))


# ---------------------------------------------------------------------------
# Shapes
# ---------------------------------------------------------------------------
def build_blot(rng, n, st):
    """Impact blot: merged pools, a crown of spikes and thrown satellite drops."""
    f = Field(n, n)
    c = n / 2
    r0 = st["radius"] * n

    lobes = [(0.0, 0.0, r0)]
    ang = rng.uniform(0, TAU)
    for i in range(1, st["lobes"]):
        r = r0 * rng.uniform(0.55, 0.84)
        a = ang + i * TAU / max(st["lobes"] - 1, 1) * rng.uniform(0.55, 1.0) + rng.uniform(-0.4, 0.4)
        d = (r0 + r) * rng.uniform(0.55, 0.8) * st.get("spread", 1.0)
        lobes.append((math.cos(a) * d, math.sin(a) * d, r))
    minx = min(x - r for x, y, r in lobes)
    maxx = max(x + r for x, y, r in lobes)
    miny = min(y - r for x, y, r in lobes)
    maxy = max(y + r for x, y, r in lobes)
    ox, oy = (minx + maxx) / 2, (miny + maxy) / 2
    lobes = [(x - ox, y - oy, r) for x, y, r in lobes]
    rc = max(math.hypot(x, y) + r for x, y, r in lobes)
    fit = min(1.0, st.get("extent", 0.33) * n / rc)
    lobes = [(c + x * fit, c + y * fit, r * fit) for x, y, r in lobes]
    rc *= fit

    shapes = []
    for x, y, r in lobes:
        harm = [(fq, amp * rng.uniform(0.3, 1.0), rng.uniform(0, TAU))
                for fq, amp in ((2, 0.06), (3, 0.05), (4, 0.035), (5, 0.03), (7, 0.018), (9, 0.012))]
        shapes.append((x, y, r, harm))
        f.lobe(x, y, r, harm, k=0.05 * n)

    def buried(px, py, skip, margin=0.97):
        return any(j != skip and math.hypot(px - x, py - y) < r * margin for j, (x, y, r, _) in enumerate(shapes))

    limit = 0.035 * n

    def inside_cell(px, py, pad=0.0):
        return limit + pad < px < n - limit - pad and limit + pad < py < n - limit - pad

    for i, (x, y, r, harm) in enumerate(shapes):
        # scalloped edge: small bumps riding on the outline
        nb = int(TAU * r / (0.024 * n))
        for j in range(nb):
            th = (j + rng.uniform(-0.4, 0.4)) * TAU / nb
            rb = n * rng.uniform(0.007, 0.019)
            rr = lobe_radius(r, harm, th) - rb * rng.uniform(0.25, 0.6)
            px, py = x + math.cos(th) * rr, y + math.sin(th) * rr
            if not buried(px, py, i, 0.9):
                f.circle(px, py, rb, k=rb * 0.9)

        # fringe: dense short hairs all around, like the edge of an ink blot
        nf = int(TAU * r / (0.0125 * n) * st.get("fringe", 1.0))
        for j in range(nf):
            th = (j + rng.uniform(-0.5, 0.5)) * TAU / nf
            rr = lobe_radius(r, harm, th)
            bx, by = x + math.cos(th) * (rr - 2), y + math.sin(th) * (rr - 2)
            if buried(bx + math.cos(th) * 5, by + math.sin(th) * 5, i):
                continue
            length = r * rng.uniform(0.03, 0.13) * (1.9 if rng.random() < 0.14 else 1.0)
            d = th + rng.normal(0, 0.2)
            ux, uy = math.cos(d), math.sin(d)
            tx, ty = bx + ux * length, by + uy * length
            if not inside_cell(tx, ty, 6):
                continue
            rt = n * rng.uniform(0.0012, 0.0022)
            f.cone(bx, by, tx, ty, n * rng.uniform(0.0034, 0.0064), rt, k=0.006 * n)
            if rng.random() < 0.3:
                f.circle(tx, ty, rt * rng.uniform(1.6, 2.5), k=rt)
            if rng.random() < 0.3:
                gap = length + n * rng.uniform(0.007, 0.022)
                f.circle(bx + ux * gap, by + uy * gap, rt * rng.uniform(0.9, 2.0))

        # crown of spikes, mostly short with a few long throws
        ns = max(6, int(st["spikes"] * (r / shapes[0][2]) ** 0.8))
        for j in range(ns):
            th = (j + rng.uniform(-0.45, 0.45)) * TAU / ns
            rr = lobe_radius(r, harm, th)
            bx, by = x + math.cos(th) * (rr - 3), y + math.sin(th) * (rr - 3)
            if buried(bx + math.cos(th) * 6, by + math.sin(th) * 6, i):
                continue
            length = r * (st["spike_min"] + st["spike_len"] * rng.random() ** st["spike_pow"])
            if "dir" in st:
                length *= 0.55 + st["dir_gain"] * max(math.cos(th - st["dir"]), 0.0) ** 2
            d = th + rng.normal(0, 0.11)
            ux, uy = math.cos(d), math.sin(d)
            while length > 4 and not inside_cell(bx + ux * length, by + uy * length, 6):
                length *= 0.8
            if length <= 4:
                continue
            rel = min(length / (0.38 * r), 1.0)
            rb = n * (0.0055 + 0.0105 * rel) * rng.uniform(0.8, 1.2)
            rt = n * rng.uniform(0.0021, 0.0038)
            bend = rng.normal(0, 0.07) * length
            mx, my = bx + ux * length * 0.55 - uy * bend, by + uy * length * 0.55 + ux * bend
            tx, ty = bx + ux * length, by + uy * length
            f.cone(bx, by, mx, my, rb, (rb + rt) * 0.42, k=0.013 * n)
            f.cone(mx, my, tx, ty, (rb + rt) * 0.42, rt, k=0.004 * n)
            if rng.random() < 0.42:                      # bead at the tip
                f.circle(tx, ty, rt * rng.uniform(1.7, 2.9), k=rt)
            gap = length
            for _ in range(rng.integers(0, 4) if rng.random() < 0.5 else 0):   # drops thrown further along
                gap += n * rng.uniform(0.012, 0.045)
                px, py = bx + ux * gap, by + uy * gap
                if not inside_cell(px, py, 4):
                    break
                rd = rt * rng.uniform(0.9, 2.3)
                if rng.random() < 0.5:
                    f.circle(px, py, rd)
                else:
                    ln = rd * rng.uniform(2.5, 5.5)
                    if inside_cell(px + ux * ln, py + uy * ln, 4):
                        f.cone(px, py, px + ux * ln, py + uy * ln, rd, rd * 0.3)

    def throw_angle():
        if "dir" in st and rng.random() < 0.7:
            return st["dir"] + rng.normal(0, 0.55)
        return rng.uniform(0, TAU)

    for _ in range(st["satellites"]):                    # drops thrown out of a random pool
        j = int(rng.integers(0, len(shapes)))
        x, y, r, harm = shapes[j]
        th = throw_angle()
        dist = lobe_radius(r, harm, th) * (1.05 + 1.25 * rng.random() ** 2.0)
        px, py = x + math.cos(th) * dist, y + math.sin(th) * dist
        if not inside_cell(px, py, 3) or buried(px, py, j, 1.04):
            continue
        rd = min(n * 0.0022 * (1.0 + rng.pareto(1.8)), n * 0.016)
        if rng.random() < 0.3:
            ln = rd * rng.uniform(1.8, 4.5)
            ex, ey = px + math.cos(th) * ln, py + math.sin(th) * ln
            if inside_cell(ex, ey, 3):
                f.cone(px, py, ex, ey, rd, rd * 0.45)
                continue
        f.circle(px, py, rd)

    for _ in range(st["dashes"]):
        th = throw_angle()
        dist = rc * rng.uniform(1.12, 1.85)
        ln = n * rng.uniform(0.02, 0.075)
        px, py = c + math.cos(th) * dist, c + math.sin(th) * dist
        ex, ey = px + math.cos(th) * ln, py + math.sin(th) * ln
        if inside_cell(px, py, 3) and inside_cell(ex, ey, 3):
            f.cone(px, py, ex, ey, n * rng.uniform(0.0022, 0.0036), n * 0.0011)
    return f.sd


def build_spray(rng, n, directional):
    """Field of thrown droplets: all around a point, or a cone flying along +X."""
    f = Field(n, n)
    count = 420 if directional else 520
    for _ in range(count):
        if directional:
            th = float(np.clip(rng.normal(0, 0.24), -0.6, 0.6))
            dist = n * (0.05 + 0.84 * rng.random() ** 0.85)
            px, py = 0.08 * n + math.cos(th) * dist, 0.5 * n + math.sin(th) * dist
            stretch = rng.uniform(2.5, 6.0)
        else:
            th = rng.uniform(0, TAU)
            dist = n * (0.09 + 0.38 * rng.random() ** 0.75)
            px, py = 0.5 * n + math.cos(th) * dist, 0.5 * n + math.sin(th) * dist
            stretch = rng.uniform(1.8, 4.2)
        rd = min(n * 0.0023 * (1.0 + rng.pareto(2.0)), n * 0.011)
        pad = 0.03 * n
        if not (pad < px < n - pad and pad < py < n - pad):
            continue
        if rng.random() < (0.6 if directional else 0.3):
            ln = rd * stretch
            ex, ey = px + math.cos(th) * ln, py + math.sin(th) * ln
            if pad < ex < n - pad and pad < ey < n - pad:
                f.cone(px, py, ex, ey, rd, rd * 0.5)
                continue
        f.circle(px, py, rd)
    return f.sd


def build_mist(rng, n):
    f = Field(n, n)
    for _ in range(260):
        px, py = rng.normal(0.5, 0.17) * n, rng.normal(0.5, 0.17) * n
        if 0.05 * n < px < 0.95 * n and 0.05 * n < py < 0.95 * n:
            f.circle(px, py, min(n * 0.0032 * (1.0 + rng.pareto(2.6)), n * 0.016))
    return f.sd


def build_drips(rng, w, h, cols, split):
    """Vertical trails. Rows above `split` are the trail, below it the hanging bead."""
    f = Field(w, h)
    cw = w / cols
    s = cw / 64.0
    for i in range(cols):
        cx = cw * (i + 0.5)
        base = rng.uniform(4.6, 6.2) * s
        ph = rng.uniform(0, TAU, 3)
        y, step = 9.0 * s, 5.0 * s
        bead_y = split + 66.0 * s
        prev = None
        while y < bead_y:
            wob = 1.0 + 0.11 * math.sin(y / (37 * s) + ph[0]) + 0.07 * math.sin(y / (15 * s) + ph[1])
            neck = 1.0 - 0.3 * max(0.0, 1.0 - (bead_y - y) / (46 * s)) ** 2      # thins just above the bead
            start = min(1.0, 0.55 + y / (60 * s))                                   # narrow where it starts
            r = base * wob * neck * start
            x = cx + 0.8 * s * math.sin(y / (58 * s) + ph[2])
            if prev:
                f.cone(prev[0], prev[1], x, y, prev[2], r)
            prev = (x, y, r)
            y += step
        f.circle(cx, bead_y, rng.uniform(11.5, 13.5) * s, k=9.0 * s)
        for _ in range(rng.integers(2, 5)):              # droplets left beside the trail
            yy = rng.uniform(0.08, 0.8) * split
            f.circle(cx + rng.choice([-1, 1]) * rng.uniform(9, 15) * s, yy, rng.uniform(0.9, 2.2) * s)
    return f.sd


def build_streak(n_w, n_h):
    """Flying drop: round head on the right, tail tapering to the left."""
    f = Field(n_w, n_h)
    cy = n_h / 2
    f.cone(n_w * 0.78, cy, n_w * 0.08, cy, n_h * 0.2, n_h * 0.02)
    f.circle(n_w * 0.8, cy, n_h * 0.215, k=n_h * 0.08)
    return f.sd


def build_drop(rng, n, squash):
    f = Field(n, n)
    harm = [(2, 0.04 + squash, rng.uniform(0, TAU)), (3, 0.03, rng.uniform(0, TAU)), (5, 0.015, rng.uniform(0, TAU))]
    f.lobe(n / 2, n / 2, n * 0.31, harm)
    return f.sd


# ---------------------------------------------------------------------------
# Shading
# ---------------------------------------------------------------------------
def shade(sd, rng, meniscus, pool, bump=13.0, ripple=0.02, shadow=0.34):
    """SDF -> premultiplied RGBA (float, colour 0..255, alpha 0..1)."""
    inside = sd < 0
    depth = ndi.distance_transform_edt(inside).astype(np.float32)
    alpha = np.clip(0.5 - sd, 0.0, 1.0)

    height = 1.0 - np.exp(-depth / meniscus)         # rounded edge, flat top
    thick = 1.0 - np.exp(-depth / pool)              # how much liquid is under the surface
    surf = ndi.gaussian_filter(height, 1.5)
    if ripple:
        noise = ndi.gaussian_filter(rng.standard_normal(sd.shape).astype(np.float32), 16)
        surf += ripple * noise / (noise.std() + 1e-6) * thick
    gy, gx = np.gradient(surf)
    nx, ny = -gx * bump, -gy * bump
    inv = 1.0 / np.sqrt(nx * nx + ny * ny + 1.0)
    nx, ny, nz = nx * inv, ny * inv, inv

    diffuse = np.clip(nx * LIGHT[0] + ny * LIGHT[1] + nz * LIGHT[2], 0.0, 1.0)
    glint = np.clip(nx * HALF[0] + ny * HALF[1] + nz * HALF[2], 0.0, 1.0)
    spec = 0.9 * glint ** 110 + 0.06 * glint ** 16

    t = thick[..., None]
    base = np.where(t < 0.5, THIN + (MID - THIN) * (t / 0.5), MID + (DEEP - MID) * ((t - 0.5) / 0.5))
    # large pools are not uniform: slow tonal drift
    drift = ndi.gaussian_filter(rng.standard_normal(sd.shape).astype(np.float32), 46)
    drift = 1.0 + 0.13 * drift / (drift.std() + 1e-6) * thick
    col = base * (0.52 + 0.8 * diffuse)[..., None] * drift[..., None] + SPEC * spec[..., None]
    col = np.clip(col, 0.0, 255.0)

    a = alpha * (0.9 + 0.1 * thick)
    a_sh = shadow * np.exp(-np.maximum(sd, 0.0) / (1.7 * SS)) * (1.0 - a)
    out = np.empty(sd.shape + (4,), np.float32)
    out[..., :3] = col * a[..., None] + SHADOW * a_sh[..., None]
    out[..., 3] = a + a_sh
    return out


def soften(sd, rng):
    """Bleeding blot: no hard edge, blood soaking outwards."""
    inside = (sd < 0).astype(np.float32)
    n = sd.shape[0]
    core = ndi.gaussian_filter(inside, 0.016 * n)
    halo = ndi.gaussian_filter(inside, 0.05 * n)
    a = np.clip(0.8 * np.clip(core * 1.5 - 0.1, 0, 1) + 0.75 * halo, 0.0, 1.0) ** 1.15
    drift = ndi.gaussian_filter(rng.standard_normal(sd.shape).astype(np.float32), 30)
    tone = 1.0 + 0.1 * drift / (drift.std() + 1e-6)
    col = (DEEP * 1.12)[None, None, :] * tone[..., None]
    out = np.empty(sd.shape + (4,), np.float32)
    out[..., :3] = col * a[..., None]
    out[..., 3] = a
    return out


def downsample(img):
    h, w = img.shape[0] // SS, img.shape[1] // SS
    return img.reshape(h, SS, w, SS, 4).mean(axis=(1, 3))


def finish(premult):
    """Premultiplied float -> straight 8-bit RGBA with colour bled under transparent pixels."""
    a = premult[..., 3]
    rgb = np.zeros_like(premult[..., :3])
    solid = a > 1e-3
    rgb[solid] = premult[..., :3][solid] / a[solid][:, None]
    known = a > 0.03
    if known.any() and not known.all():
        idx = ndi.distance_transform_edt(~known, return_distances=False, return_indices=True)
        rgb = rgb[idx[0], idx[1]]
    out = np.dstack([np.clip(rgb, 0, 255), np.clip(a, 0, 1)[..., None] * 255.0])
    return np.round(out).astype(np.uint8)


# ---------------------------------------------------------------------------
# Atlases
# ---------------------------------------------------------------------------
BLOTS_A = [
    dict(radius=0.225, lobes=1, spikes=34, spike_min=0.05, spike_len=0.46, spike_pow=2.3, satellites=110, dashes=10),
    dict(radius=0.195, lobes=2, spikes=27, spike_min=0.05, spike_len=0.5, spike_pow=2.1, satellites=100, dashes=9),
    dict(radius=0.172, lobes=3, spikes=23, spike_min=0.05, spike_len=0.5, spike_pow=2.2, satellites=96, dashes=8),
    dict(radius=0.188, lobes=2, spikes=27, spike_min=0.04, spike_len=0.5, spike_pow=1.8, satellites=130, dashes=14,
         dir=-0.5, dir_gain=1.5),
]
BLOTS_B = [
    dict(radius=0.2, lobes=1, spikes=19, spike_min=0.08, spike_len=0.72, spike_pow=1.35, satellites=104, dashes=12),
    dict(radius=0.168, lobes=3, spread=1.14, spikes=24, spike_min=0.05, spike_len=0.48, spike_pow=2.0, satellites=92,
         dashes=8),
    dict(radius=0.245, lobes=1, spikes=46, spike_min=0.04, spike_len=0.26, spike_pow=1.9, satellites=76, dashes=6),
    dict(radius=0.168, lobes=2, spikes=26, spike_min=0.04, spike_len=0.55, spike_pow=1.6, satellites=140, dashes=16,
         dir=2.6, dir_gain=2.1),
]


def blot_atlas(rng, styles):
    atlas = np.zeros((CELL * 2, CELL * 2, 4), np.float32)
    n = CELL * SS
    for i, st in enumerate(styles):
        sd = build_blot(rng, n, st)
        cell = downsample(shade(sd, rng, meniscus=4.0 * SS, pool=13.0 * SS))
        x, y = (i % 2) * CELL, (i // 2) * CELL
        atlas[y:y + CELL, x:x + CELL] = cell
    return atlas


def fx_atlas(rng):
    atlas = np.zeros((1024, 1024, 4), np.float32)

    def put(x, y, premult):
        cell = downsample(premult)
        atlas[y:y + cell.shape[0], x:x + cell.shape[1]] = cell

    fine = dict(meniscus=2.6 * SS, pool=9.0 * SS, bump=7.5, ripple=0.0)
    put(0, 0, shade(build_spray(rng, 512 * SS, False), rng, **fine))            # spray, all around
    put(512, 0, shade(build_spray(rng, 512 * SS, True), rng, **fine))           # spray, cone along +X
    put(0, 512, shade(build_drips(rng, 256 * SS, 512 * SS, 4, 384 * SS), rng,   # 4 drips: trail 384 px + bead 128 px
                      meniscus=3.2 * SS, pool=10.0 * SS, bump=8.5, ripple=0.0))
    put(256, 512, shade(build_streak(256 * SS, 128 * SS), rng, meniscus=7.0 * SS, pool=16.0 * SS, ripple=0.0))
    put(256, 640, shade(build_drop(rng, 128 * SS, 0.0), rng, meniscus=8.0 * SS, pool=16.0 * SS, ripple=0.0))
    put(384, 640, shade(build_drop(rng, 128 * SS, 0.08), rng, meniscus=8.0 * SS, pool=16.0 * SS, ripple=0.0))
    put(256, 768, shade(build_mist(rng, 256 * SS), rng, **fine))
    bleed = dict(radius=0.2, lobes=2, spikes=30, spike_min=0.1, spike_len=0.55, spike_pow=1.5, satellites=0, dashes=0,
                 extent=0.27)
    put(512, 512, soften(build_blot(rng, 512 * SS, bleed), rng))
    return atlas


def preview(path, images):
    """Atlases over the dark scene colour and over the bone colour of the title."""
    rows = []
    for img in images:
        rgb = img[..., :3].astype(np.float32)
        a = img[..., 3:4].astype(np.float32) / 255.0
        tiles = [rgb * a + np.array(bg, np.float32) * (1 - a) for bg in ((13, 5, 7), (236, 228, 220))]
        rows.append(np.hstack(tiles))
    sheet = Image.fromarray(np.vstack(rows).astype(np.uint8))
    sheet.save(path)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    out_dir = args[0] if args else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets")
    os.makedirs(out_dir, exist_ok=True)
    rng = np.random.default_rng(SEED)
    results = []
    for name, build in (
        ("zero_blots_a.png", lambda: blot_atlas(rng, BLOTS_A)),
        ("zero_blots_b.png", lambda: blot_atlas(rng, BLOTS_B)),
        ("zero_blood_fx.png", lambda: fx_atlas(rng)),
    ):
        img = finish(build())
        path = os.path.join(out_dir, name)
        Image.fromarray(img, "RGBA").save(path, optimize=True)
        print(f"{name}: {img.shape[1]}x{img.shape[0]}, {os.path.getsize(path) // 1024} KB")
        results.append(img)
    if "--preview" in sys.argv:
        preview(sys.argv[sys.argv.index("--preview") + 1], results)


if __name__ == "__main__":
    main()
