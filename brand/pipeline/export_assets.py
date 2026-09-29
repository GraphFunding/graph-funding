"""Curado y export de assets al sitio: web/public/assets/*.webp|jpg|png (se corre desde la raíz del repo)."""
from pathlib import Path
from PIL import Image, ImageOps

SRC = Path('refs/assets')
OUT = Path('web/public/assets')
OUT.mkdir(parents=True, exist_ok=True)


def webp(img: Image.Image, name: str, width: int, q: int = 84):
    if img.width > width:
        img = img.resize((width, round(img.height * width / img.width)), Image.LANCZOS)
    img.save(OUT / f'{name}.webp', 'WEBP', quality=q, method=6)
    print(name, img.size)


def paper_to_white(img: Image.Image) -> Image.Image:
    """Divide por el color del papel (mediana del borde) para que el papel quede blanco y el multiply deje sólo tinta."""
    img = img.convert('RGB')
    w, h = img.size
    border = [img.getpixel((x, y)) for x in range(0, w, 7) for y in (2, h - 3)] + [img.getpixel((x, y)) for y in range(0, h, 7) for x in (2, w - 3)]
    paper = [sorted(c[i] for c in border)[len(border) // 2] for i in range(3)]
    bands = [b.point(lambda v, p=p: min(255, int(v * 255 / max(p, 1)))) for b, p in zip(img.split(), paper)]
    return Image.merge('RGB', bands)


def white_to_alpha(img: Image.Image) -> Image.Image:
    """Color-to-alpha sobre blanco: la tinta queda opaca y el papel (ya llevado a blanco) queda transparente."""
    rgb = paper_to_white(img)
    px = rgb.load()
    out = Image.new('RGBA', rgb.size)
    op = out.load()
    w, h = rgb.size
    for y in range(h):
        for x in range(w):
            r, g, b = px[x, y]
            a = 1 - min(r, g, b) / 255
            if a < 0.04:
                op[x, y] = (0, 0, 0, 0)
                continue
            op[x, y] = tuple(max(0, min(255, round((c - 255 * (1 - a)) / a))) for c in (r, g, b)) + (round(a * 255),)
    return out


def trim_alpha(img: Image.Image, pad: int = 8) -> Image.Image:
    box = img.getchannel('A').point(lambda a: 255 if a > 12 else 0).getbbox()
    img = img.crop(box)
    canvas = Image.new('RGBA', (img.width + pad * 2, img.height + pad * 2), (0, 0, 0, 0))
    canvas.paste(img, (pad, pad))
    return canvas


# hero: la escena del banner (cielo crema a la izquierda, árbol a la derecha)
PROC = SRC / 'proc'
webp(Image.open(PROC / 'hero.png').convert('RGB'), 'hero', 2400, 82)
webp(Image.open(PROC / 'hero-mobile.png').convert('RGB'), 'hero-mobile', 1100, 82)
for name in ('ink-grain', 'torn-mask'):
    Image.open(PROC / f'{name}.png').save(OUT / f'{name}.png', optimize=True)
ke = Image.open(PROC / 'keeper-empty.png')
ke.save(OUT / 'keeper-empty.webp', 'WEBP', lossless=True)
tb = Image.open(PROC / 'tree-base.png')
tb.resize((2000, round(tb.height * 2000 / tb.width)), Image.LANCZOS).save(OUT / 'tree-base.webp', 'WEBP', quality=84, method=6)
print('hero/hero-mobile/grain/torn/keeper-empty/tree-base ok')

for ch in (1, 3, 17, 32):
    p = SRC / 'proc' / f'poster-ch{ch}.png'
    if p.exists():
        webp(Image.open(p).convert('RGB'), f'poster-ch{ch}', 900)

for s in ('enlist', 'drawn', 'vote', 'flow'):
    p = SRC / f'step-{s}.png'
    if p.exists():
        webp(white_to_alpha(Image.open(p).resize((800, 800), Image.LANCZOS)), f'step-{s}', 800, 88)

for k in ('keeper-blue', 'keeper-lit'):
    p = SRC / f'{k}.png'
    if p.exists():
        img = trim_alpha(Image.open(p).convert('RGBA'))
        img.thumbnail((160, 200), Image.LANCZOS)
        img.save(OUT / f'{k}.webp', 'WEBP', quality=90, method=6)
        print(k, img.size)

# papel: tile sin costura espejando 2x2
p = SRC / 'paper.png'
if p.exists():
    t = Image.open(p).convert('RGB').resize((512, 512), Image.LANCZOS)
    tile = Image.new('RGB', (1024, 1024))
    tile.paste(t, (0, 0))
    tile.paste(ImageOps.mirror(t), (512, 0))
    tile.paste(ImageOps.flip(t), (0, 512))
    tile.paste(ImageOps.flip(ImageOps.mirror(t)), (512, 512))
    tile.save(OUT / 'paper.webp', 'WEBP', quality=80, method=6)
    print('paper', tile.size)

p = SRC / 'fee-route.png'
if p.exists():
    src = Image.open(p)
    webp(white_to_alpha(src.resize((1600, round(src.height * 1600 / src.width)), Image.LANCZOS)), 'fee-route', 1600, 88)

for name, w in (('skyline', 2400),):
    p = SRC / f'{name}.png'
    if p.exists():
        webp(Image.open(p).convert('RGB'), name, w)

# avatar del Keeper (kit B)
pfp = Image.open('brand/pfp-1000.png').convert('RGB')
pfp.resize((96, 96), Image.LANCZOS).save(OUT / 'pfp-96.jpg', quality=88)
pfp.resize((400, 400), Image.LANCZOS).save(OUT / 'pfp-400.jpg', quality=86)
pfp.resize((64, 64), Image.LANCZOS).save(OUT / 'favicon.png')
print('pfp + favicon ok')
