import json, subprocess, urllib.request, shutil, sys
HF = shutil.which('higgsfield') or shutil.which('higgsfield.cmd')
ROBE = ("a Veridian citizen wearing a thick winter privacy robe with a big rounded hood pulled up and a knitted face cover over nose and mouth")
prompt = ("Risograph civic poster in exactly the same print style as the reference images: three inks only (warm cream paper #F3EBDD, ink blue #2B59C3, "
  "fluorescent orange #FF6B1A), slight misregistration, visible halftone dots, paper grain, big flat hand-cut stencil shapes. "
  "Portrait composition: a tall bare winter tree seen slightly from below, its trunk splitting into branches and the branches splitting again, like a funding graph. "
  f"At every fork stands one small figure, {ROBE}, holding a small lantern. Exactly one path, from the base of the trunk up through three forks to a single lantern "
  "near the top, is printed in fluorescent orange; that top lantern glows orange; every other branch and figure is ink blue. A huge pale moon behind the crown, "
  "snowy Veridian rooftops and a domed civic building small at the bottom. The top 30% of the frame is plain empty cream paper with only a little snow. "
  "No text, no letters, no numbers, no logo, no watermark, not vector clip art, no gradients, not dark, not moody, no pointed hoods, not a monk.")
cmd=[HF,'generate','create','gpt_image_2','--prompt',prompt,'--aspect_ratio','4:5','--resolution','2k','--quality','high',
     '--image','refs/dirs/B-banner.png','--image','refs/dirs/B-pfp.png','--wait','--json']
out=subprocess.run(cmd,capture_output=True,text=True,timeout=900)
try:
    d=json.loads(out.stdout); j=d[0] if isinstance(d,list) else d; url=j['result_url']
except Exception:
    print('ERROR',out.stdout[-600:],out.stderr[-600:]); sys.exit(1)
dst=sys.argv[1] if len(sys.argv)>1 else 'refs/dirs/B-post.png'
urllib.request.urlretrieve(url,dst); print('ok',dst)
