"""Genera las direcciones de marca de Graph Funding con Higgsfield (gpt_image_2) y baja los resultados."""
import json, subprocess, sys, urllib.request, concurrent.futures as cf, pathlib, shutil
HF = shutil.which('higgsfield') or shutil.which('higgsfield.cmd')
NEG = ("No text, no letters, no numbers, no logo, no watermark, no outline stroke, no halo or glow disc behind the subject, "
       "no pointed hood, not a ninja, not a monk, not cute chibi, not dark, not moody, not cinematic.")
ROBE = ("a Veridian citizen from the novel Snowmoon wearing a thick winter privacy robe with a big rounded hood pulled up "
        "and a knitted face cover over nose and mouth, so only two calm, steady eyes show between hood and scarf")
LAMP = "a slim far-UVC 222nm tube lamp of frosted glass with brushed aluminium end caps, held up like a lantern, glowing soft violet-white"
JOBS = {
 # A · vinilo de diseñador, duotono naranja + negro
 'A-pfp': ('1:1', f"Close-up product render of a designer vinyl art toy: {ROBE}. The robe is matte black quilted vinyl with satin sheen and faint toy seam lines. "
          f"It holds {LAMP} next to its face; the lamp light tints the hood rim violet. Soft studio softbox from upper left. "
          "Flat seamless background of solid saturated orange #FF8A1F, no gradient. A very large Ethereum diamond silhouette in a slightly darker orange sits behind, "
          "cropped by the right edge of the frame. Head and hood fully in frame with margin, figure fills 70% of the frame. " + NEG),
 'A-banner': ('21:9', f"Wide diorama render of designer vinyl art toys: three small figures, each {ROBE}, robes in matte black quilted vinyl, sit on a snowy black ledge "
          f"entering from the bottom right. Each holds {LAMP}. Thin taut black cords run between the three lamps like the branches of a small tree, one cord glowing orange. "
          "Behind them a huge pale snow moon half hidden in orange haze. The sky is flat solid saturated orange #FF8A1F. Duotone orange and black, minimal accents. "
          "The left 45% of the frame is empty flat orange. Soft studio light, satin vinyl sheen. " + NEG),
 # B · afiche risograph de Veridia, papel crema + azul + naranja flúor
 'B-pfp': ('1:1', f"Risograph print portrait with three inks only (warm cream paper #F3EBDD, ink blue #2B59C3, fluorescent orange #FF6B1A), slight misregistration, visible halftone dots and paper grain. "
          f"Close-up of {ROBE}, robe printed in ink blue, holding {LAMP} printed in fluorescent orange next to the face. Big flat hand-cut stencil shapes. "
          "Background flat cream paper with a very large blue moon circle cropped by the top right edge. Head fully in frame with margin. Not vector clip art, no gradients. " + NEG),
 'B-banner': ('21:9', "Risograph civic poster, three inks only (warm cream paper, ink blue, fluorescent orange), misregistration, halftone and paper grain. "
          "A snowy Veridian town square in bright daylight under a huge pale moon. On the right a tall bare winter tree whose branches split like a funding graph; "
          f"at each fork stands a small figure, {ROBE}, holding a lamp in fluorescent orange; one path of branches glows orange from the trunk to a single lamp at the tip. "
          "The left half is empty cream paper. Big flat shapes, not vector clip art. " + NEG),
 # C · foto de estudio sobre papel sin fin hielo, túnica tejida naranja
 'C-pfp': ('1:1', f"Studio photograph, medium format, daylight softbox: close-up of {ROBE}; the robe and face cover are hand-knit chunky wool in saturated orange #FF6B1A, real fibre texture. "
          f"They hold {LAMP} near the chin. Solid seamless paper backdrop in pale ice white-blue #E4EEF6, no gradient, crisp soft shadow. "
          "A very large Ethereum diamond shape cut from pale blue paper leans behind, cropped by the frame edge. Fashion editorial, natural skin around the eyes. " + NEG),
 'C-banner': ('21:9', f"Studio photograph on a long seamless paper sweep in pale ice white-blue #E4EEF6: on the right, three people, each {ROBE}, robes hand-knit chunky wool in saturated orange #FF6B1A, "
          f"each holding {LAMP}. Thin orange cords run between their lamps forming a small branching tree shape. A big pale paper-cutout moon hangs behind them. "
          "The left half is empty ice-blue paper. Bright even daylight, crisp soft shadows, fashion editorial. " + NEG),
}
def run(name):
    ar, prompt = JOBS[name]
    cmd = [HF, 'generate', 'create', 'gpt_image_2', '--prompt', prompt, '--aspect_ratio', ar, '--resolution', '2k', '--quality', 'high', '--wait', '--json']
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=900)
    try:
        data = json.loads(out.stdout)
        job = data[0] if isinstance(data, list) else data
        url = job.get('result_url') or (job.get('results') or [{}])[0].get('url')
    except Exception:
        return name, 'ERROR ' + (out.stdout[-400:] + out.stderr[-400:])
    ext = url.split('?')[0].rsplit('.', 1)[-1][:4]
    dst = pathlib.Path('refs/dirs') / f'{name}.{ext}'
    urllib.request.urlretrieve(url, dst)
    return name, str(dst)
names = sys.argv[1:] or list(JOBS)
with cf.ThreadPoolExecutor(len(names)) as ex:
    for n, r in ex.map(run, names):
        print(n, r, flush=True)
