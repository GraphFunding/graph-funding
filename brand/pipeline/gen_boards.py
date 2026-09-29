"""Reference boards de la página de Graph Funding (uno por sección), gpt_image_2 16:9 con el kit B como referencia."""
import json, subprocess, urllib.request, shutil, sys, concurrent.futures as cf, pathlib
HF = shutil.which('higgsfield') or shutil.which('higgsfield.cmd')
REFS = ['refs/dirs/B-banner.png', 'refs/dirs/B-post-1.png', 'refs/dirs/B-pfp.png']
BASE = ("Horizontal web page section board for a crypto public-goods website based on the novel Snowmoon, drawn in exactly the "
        "risograph print world of the reference images: three inks only, warm cream paper #F3EBDD, ink blue #2B59C3, fluorescent "
        "orange #FF6B1A, slight misregistration, halftone dots, paper grain, big flat hand-cut stencil shapes. Headlines are tall "
        "condensed poster capitals in ink blue with a fluorescent orange misregistered offset. Fluorescent orange is used ONLY for the "
        "funded path of money and the main button. Editorial layout, generous negative space, no lorem ipsum, no browser chrome, "
        "no stock-photo people, no gradients, no glow, not dark, not glossy, not a generic crypto landing. ")
KEEPER = "small figures wearing thick winter privacy robes with big rounded hoods and knitted face covers, holding lanterns"
BOARDS = {
 '1-hero': "HERO SECTION: full-bleed illustration of a snowy Veridian town square under a huge pale moon, a tall bare tree on the right whose "
   f"forks hold {KEEPER}, one path of branches from the trunk to one lantern printed in fluorescent orange. On the cream left side: a small kicker "
   "'SNOWMOON · CHAPTER 17', a giant headline 'NOBODY VOTES ON THE WHOLE BUDGET.', a short paragraph, an orange pill button 'Become a Keeper', a "
   "small status chip. A thin top nav with a tiny round hooded-figure emblem and four small links.",
 '2-posters': "BOOK POSTER WALL SECTION: a snowy tunnel wall with four tall risograph civic posters taped at the corners, side by side: "
   "(1) students of all ages reading textbooks together, (2) an icy empire of sharp towers with a lion, a propaganda poster, "
   "(3) a gloved hand holding a slim device whose screen shows a branching tree graph, (4) a senator in a long parliament robe at a podium. "
   "Small printed captions under each poster with chapter numbers, a section title 'FROM THE BOOK' in condensed capitals.",
 '3-graph': "LIVE GRAPH SECTION (the centerpiece): one very large illustrated tree across the whole width, trunk at the bottom center, four main "
   f"branches splitting into leaves; at each fork stand five {KEEPER}; small condensed labels on branches ('CORE PROTOCOL', 'PRIVACY', "
   "'SECURITY', 'OPEN TOOLING & DATA') and tiny project names on the leaves; one continuous fluorescent orange path runs from the trunk up "
   "to one leaf. A thin strip of monospace counters across the top (POOL, EPOCH, KEEPERS, NEXT SPLIT). Section title 'THE GRAPH, LIVE'.",
 '4-steps': "HOW IT IS DECIDED SECTION: four risograph panels in a row like a printed civic instruction sheet, each with a big number and one "
   "condensed word: 'ENLIST' (a gloved hand dropping tokens into a slot in a wooden box), 'DRAWN' (a lottery drum releasing five hooded "
   "figures), 'VOTE' (five hooded figures each raising a card), 'FLOW' (a tree with fluorescent orange sap flowing down, a small clock).",
 '5-keeper-app': "BECOME A KEEPER SECTION: a printed civic enrollment form on cream paper, like a Veridian government form with boxes and ruled "
   "lines, containing a working web app: left a card with a hooded Keeper portrait, stake amount in monospace and a row of small stamp "
   "badges; right a form with an amount field, 'Stake' orange button and 'Unstake' outline button, below a 'You were drawn for PRIVACY' "
   "block with three percentage sliders. Ink blue UI lines, one orange primary button.",
 '6-rules': "RULES ON THE WALL SECTION: a large printed public notice pinned on a wall, divided into ruled boxes: a small diagram of the fee "
   "route (a market stall → a hooded wallet keeper → the tree), a checklist of what the owner can and cannot do, contract addresses in "
   "monospace, a boxed list of risks, a round rubber stamp in ink blue. Dense but orderly, like a legal notice designed by a poster studio.",
}
def run(name):
    prompt = BASE + BOARDS[name]
    cmd = [HF,'generate','create','gpt_image_2','--prompt',prompt,'--aspect_ratio','16:9','--resolution','2k','--quality','high','--wait','--json']
    for r in REFS: cmd += ['--image', r]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=1200)
    try:
        d = json.loads(out.stdout); j = d[0] if isinstance(d, list) else d; url = j['result_url']
    except Exception:
        return name, 'ERROR ' + out.stdout[-300:] + out.stderr[-300:]
    dst = pathlib.Path('refs/boards') / f'{name}.png'
    urllib.request.urlretrieve(url, dst)
    return name, str(dst)
names = sys.argv[1:] or list(BOARDS)
with cf.ThreadPoolExecutor(3) as ex:
    for n, r in ex.map(run, names): print(n, r, flush=True)
