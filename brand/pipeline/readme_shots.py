"""Capturas de secciones del sitio para el README: python refs/readme_shots.py [url] -> refs/readme/*.png (2x)"""
import sys
from pathlib import Path
from playwright.sync_api import sync_playwright

url = sys.argv[1] if len(sys.argv) > 1 else 'http://127.0.0.1:5174/'
out = Path(__file__).parent / 'readme'
out.mkdir(exist_ok=True)
SHOTS = {
    'steps': 'section.steps',
    'graph': '.graph-grid',
    'route': '.box-route',
    'owner': '.box-owner',
}
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={'width': 1440, 'height': 1000}, device_scale_factor=2, reduced_motion='reduce')
    logs = []
    pg.on('pageerror', lambda e: logs.append(f'pageerror: {e}'))
    pg.goto(url, wait_until='networkidle'); pg.evaluate('document.fonts.ready')
    # el widget de cosecha y las pistas de interacción no tienen sentido en una imagen estática
    pg.add_style_tag(content='[data-harvest],.swipe-hint,.tree-tip{display:none!important}')
    for name, sel in SHOTS.items():
        el = pg.locator(sel).first
        el.scroll_into_view_if_needed(); pg.wait_for_timeout(1800)
        el.screenshot(path=str(out / f'{name}.png'))
        print(name, el.bounding_box())
    print('\n'.join(logs))
    b.close()
