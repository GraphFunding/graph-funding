"""Curado de assets tras el juicio visual (D3, D7, D8, D9, D10). Escribe refs/assets/proc/*.png; export_assets.py los usa."""
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter, ImageOps
from scipy import ndimage

SRC = Path('refs/assets')
PROC = SRC / 'proc'
PROC.mkdir(parents=True, exist_ok=True)
PAPER = np.array([243, 235, 221], np.float32) / 255
INK = np.array([43, 89, 195], np.float32) / 255


def orange_score(im: np.ndarray) -> np.ndarray:
    """0..1: cuánto de tinta naranja flúor tiene cada píxel."""
    r, g, b = im[..., 0], im[..., 1], im[..., 2]
    return np.clip(((r - b) - 0.18) / 0.4, 0, 1) * (r > 0.45)


def orange_to_ink(im: np.ndarray, where: np.ndarray) -> np.ndarray:
    """Reimprime el naranja en tinta azul conservando cuánta tinta había (luminancia), sólo donde `where`."""
    lum = im @ np.array([0.299, 0.587, 0.114], np.float32)
    lum_paper = float(PAPER @ np.array([0.299, 0.587, 0.114], np.float32))
    k = np.clip((lum_paper - lum) / 0.45, 0, 1)[..., None] * 1.15
    blue = PAPER + (INK - PAPER) * np.clip(k, 0, 1)
    w = (orange_score(im) * where)[..., None]
    return im * (1 - w) + blue * w


def hero_one_lantern(path: str) -> Image.Image:
    im = np.asarray(Image.open(path).convert('RGB')).astype(np.float32) / 255
    hard = (im[..., 0] > 0.6) & (im[..., 0] > im[..., 1] + 0.12) & (im[..., 1] > im[..., 2] + 0.08)
    lab, n = ndimage.label(ndimage.binary_dilation(hard, iterations=6))
    sizes = ndimage.sum(hard.astype(np.int32), lab, np.arange(1, n + 1))
    keep_ids = np.argsort(sizes)[::-1][:2] + 1  # la rama financiada + el farol del Keeper al final de la rama
    keep = np.isin(lab, keep_ids)
    keep = ndimage.binary_dilation(keep, iterations=10)
    out = orange_to_ink(im, (~keep).astype(np.float32))
    return Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8))


def to_alpha(im: np.ndarray) -> Image.Image:
    """Papel → transparente (color-to-alpha contra el papel)."""
    diff = np.clip((PAPER - im) / np.maximum(PAPER, 1e-3), 0, 1)
    a = diff.max(-1)
    a = np.where(a < 0.05, 0, a)
    rgb = np.where(a[..., None] > 0, 1 - diff / np.maximum(a[..., None], 1e-3) * (1 - np.clip(im, 0, 1)) / np.maximum(1 - im, 1e-3) * 0 + im, im)
    rgb = np.clip((im - PAPER * (1 - a[..., None])) / np.maximum(a[..., None], 1e-3), 0, 1)
    rgba = np.dstack([rgb, a])
    return Image.fromarray((rgba * 255).astype(np.uint8), 'RGBA')


# D3 · hero y OG: un solo farol naranja
hero = hero_one_lantern('refs/dirs/B-banner.png')
hero.save(PROC / 'hero.png')
# D1 · recorte móvil del hero (árbol + rama financiada + su Keeper)
hero.crop((1500, 0, 2688, 1152)).save(PROC / 'hero-mobile.png')

# D7 · base del árbol: sólo tinta azul, papel transparente
tb = np.asarray(Image.open(SRC / 'tree-base.png').convert('RGB')).astype(np.float32) / 255
tb = orange_to_ink(tb, np.ones(tb.shape[:2], np.float32))
to_alpha(tb).save(PROC / 'tree-base.png')

# D7 · asiento vacío: contorno punteado del Keeper
kb = Image.open(SRC / 'keeper-blue.png').convert('RGBA')
alpha = kb.getchannel('A').point(lambda v: 255 if v > 90 else 0)
edge = np.asarray(alpha.filter(ImageFilter.MaxFilter(9))).astype(np.int16) - np.asarray(alpha.filter(ImageFilter.MinFilter(3))).astype(np.int16)
edge = edge > 0
yy, xx = np.mgrid[0 : edge.shape[0], 0 : edge.shape[1]]
dots = ((xx // 10 + yy // 10) % 2) == 0
line = edge & dots
empty = np.zeros((*edge.shape, 4), np.uint8)
empty[line] = [43, 89, 195, 255]
Image.fromarray(empty, 'RGBA').save(PROC / 'keeper-empty.png')

# D5 · grano de tinta: alpha con ~10% de huecos (tile 360)
rng = np.random.default_rng(7)
g = rng.random((360, 360))
g = ndimage.gaussian_filter(g, 0.9)
holes = g < np.quantile(g, 0.1)
grain = np.full((360, 360, 4), 255, np.uint8)
grain[..., 3] = np.where(holes, 0, 255)
Image.fromarray(grain, 'RGBA').save(PROC / 'ink-grain.png')

# D9 · borde rasgado del aviso (máscara 1000×1400, borde irregular)
W, H = 1000, 1400
mask = Image.new('L', (W, H), 0)
pts = []
def jag(n, a, b, fixed, horiz, amp=9):
    out = []
    for i in range(n + 1):
        t = a + (b - a) * i / n
        d = rng.normal(0, amp / 2) + (rng.random() < 0.08) * rng.uniform(4, amp * 1.4)
        out.append((t, fixed + d) if horiz else (fixed + d, t))
    return out
pts += jag(90, 14, W - 14, 14, True)
pts += jag(120, 14, H - 14, W - 14, False)
pts += jag(90, W - 14, 14, H - 14, True)
pts += jag(120, H - 14, 14, 14, False)
from PIL import ImageDraw
ImageDraw.Draw(mask).polygon(pts, fill=255)
mask.save(PROC / 'torn-mask.png')

# D10 · afiches con densidad de tinta nivelada
for ch in (1, 3, 17, 32):
    p = Image.open(SRC / f'poster-ch{ch}.png').convert('RGB')
    ImageOps.autocontrast(p, cutoff=(1.5, 0.5)).save(PROC / f'poster-ch{ch}.png')
print('ok')
