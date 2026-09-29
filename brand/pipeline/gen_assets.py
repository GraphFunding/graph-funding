"""Assets del sitio (sin texto): afiches del libro, paneles del mecanismo, Keeper recortado, papel, skyline, base del árbol."""
import json, subprocess, urllib.request, shutil, sys, concurrent.futures as cf, pathlib
HF = shutil.which('higgsfield') or shutil.which('higgsfield.cmd')
REFS = ['refs/dirs/B-banner.png', 'refs/dirs/B-post-1.png', 'refs/dirs/B-pfp.png']
STYLE = ("Risograph print in exactly the style of the reference images: three inks only (warm cream paper #F3EBDD, ink blue #2B59C3, "
         "fluorescent orange #FF6B1A), slight misregistration, visible halftone dots, paper grain, big flat hand-cut stencil shapes. "
         "No text, no letters, no numbers, no logo, no watermark, no border frame, not vector clip art, no gradients, no glow, not dark, "
         "not glossy, no pointed hoods, not a monk. ")
ROBE = "a Veridian citizen in a thick winter privacy robe with a big rounded hood and a knitted face cover over nose and mouth"
A = {
 'poster-ch1': ('3:4', "A civic education poster: students of all ages, from a child to an old man, wrapped in winter clothes, reading textbooks together "
                "at a long table in a warm library, big windows with snow outside. Mostly ink blue, one small orange lamp."),
 'poster-ch3': ('3:4', "An imperial propaganda poster of the Arctic Empire: a proud lion in front of sharp icy towers and a gleaming tall spire reaching to "
                "the stars, dramatic but printed flat, only ink blue, no orange at all."),
 'poster-ch17': ('3:4', "Close-up of a gloved hand holding a slim hand device; on its screen a branching tree graph of nodes, one path of branches printed in "
                 "fluorescent orange, the rest in ink blue. Snow falling behind."),
 'poster-ch32': ('3:4', "A senator in a long parliament robe speaking calmly at a wooden podium in a snowy parliament hall, a few candles, one small orange "
                 "light. Mostly ink blue."),
 'step-enlist': ('1:1', f"A gloved hand dropping a coin into the slot of a sturdy wooden ballot box with a snowflake emblem. Ink blue, the coin fluorescent orange. Plain cream background, centered object with margin."),
 'step-drawn': ('1:1', f"A brass lottery drum on a stand, turning, releasing five small figures, each {ROBE}. Ink blue only. Plain cream background, centered with margin."),
 'step-vote': ('1:1', f"Five small figures standing in a row, each {ROBE}, each raising a small card; one card is fluorescent orange. Plain cream background, centered with margin."),
 'step-flow': ('1:1', "A bare winter tree whose sap flows down as fluorescent orange streams along the branches into the roots, a small round wall clock beside it. Plain cream background, centered with margin."),
 'keeper-blue': ('1:1', f"A single full-body standing figure, {ROBE}, holding a small lantern in front of them, printed in ink blue only. Isolated on a transparent background, no ground, no shadow."),
 'keeper-lit': ('1:1', f"A single full-body standing figure, {ROBE}, holding a small lantern that glows fluorescent orange, figure in ink blue. Isolated on a transparent background, no ground, no shadow."),
 'paper': ('1:1', "Seamless tileable texture of warm cream risograph paper: fine fibres, subtle grain and a few faint ink-blue halftone specks, perfectly even lighting, no objects."),
 'skyline': ('21:9', "A long snowy skyline of a Veridian town seen from a square: domed civic building, clock tower, rooftops with snow, tiny people walking, a huge pale moon rising on the left. Ink blue on cream, the whole top half is empty cream paper."),
 'fee-route': ('21:9', f"Three separate small spot illustrations spaced evenly on plain cream paper, left to right: a small market stall with coins, {ROBE} holding a lockbox, a small bare tree with an orange path running up its trunk. Lots of empty space between them."),
 'tree-base': ('16:9', "The base of a single massive old tree trunk rising from the bottom center, cut off by the top edge, with thick roots in the snow of a Veridian town square; small snowy rooftops and a domed building on both sides along the bottom; a huge pale moon behind on the left. The top two thirds of the image are almost empty pale sky with light snow."),
}
TRANSPARENT = {'keeper-blue', 'keeper-lit'}
def run(name):
    ar, p = A[name]
    cmd = [HF,'generate','create','gpt_image_2','--prompt', STYLE + p,'--aspect_ratio',ar,'--resolution','2k','--quality','high','--wait','--json']
    if name in TRANSPARENT: cmd += ['--background','transparent']
    for r in REFS: cmd += ['--image', r]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=1500)
    try:
        d = json.loads(out.stdout); j = d[0] if isinstance(d, list) else d; url = j['result_url']
    except Exception:
        return name, 'ERROR ' + out.stdout[-200:] + out.stderr[-200:]
    dst = pathlib.Path('refs/assets') / f'{name}.png'
    urllib.request.urlretrieve(url, dst); return name, str(dst)
names = sys.argv[1:] or list(A)
with cf.ThreadPoolExecutor(4) as ex:
    for n, r in ex.map(run, names): print(n, r, flush=True)
