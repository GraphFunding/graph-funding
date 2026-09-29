"""Exporta las imágenes del README: cabecera (HTML con fuentes reales) + capturas de secciones del sitio.
python refs/readme_shots.py && python refs/readme_export.py  ->  docs/readme/*.jpg, brand/social-preview.jpg"""
from pathlib import Path
from PIL import Image
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
SHOTS = ROOT / 'refs' / 'readme'
OUT = ROOT / 'docs' / 'readme'
OUT.mkdir(parents=True, exist_ok=True)
W = 1760  # 2× el ancho de la columna del README en GitHub


def save(img: Image.Image, path: Path, width: int | None = W, q: int = 86):
    img = img.convert('RGB')
    if width and img.width > width:
        img = img.resize((width, round(img.height * width / img.width)), Image.LANCZOS)
    img.save(path, quality=q, optimize=True, progressive=True)
    print(path.relative_to(ROOT), img.size, f'{path.stat().st_size // 1024} KB')


with sync_playwright() as p:
    b = p.chromium.launch()
    for scale, dst in [(2, SHOTS / 'header@2x.png'), (1, SHOTS / 'header@1x.png')]:
        pg = b.new_page(viewport={'width': 1280, 'height': 640}, device_scale_factor=scale)
        pg.goto((ROOT / 'brand' / 'readme-header.html').as_uri(), wait_until='networkidle')
        pg.evaluate('document.fonts.ready'); pg.wait_for_timeout(400)
        pg.locator('.h').screenshot(path=str(dst))
    b.close()

save(Image.open(SHOTS / 'header@2x.png'), OUT / 'header.jpg')
save(Image.open(SHOTS / 'header@1x.png'), ROOT / 'brand' / 'social-preview.jpg', width=None, q=90)
save(Image.open(SHOTS / 'steps.png'), OUT / 'how-it-works.jpg')
g = Image.open(SHOTS / 'graph.png')
save(g.crop((780, 0, g.width, g.height)), OUT / 'genesis-tree.jpg')  # sólo el árbol: el título lo pone el README
save(Image.open(SHOTS / 'route.png'), OUT / 'money-in.jpg', width=None)
