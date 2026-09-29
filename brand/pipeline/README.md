# Image pipeline

Snowmoon is released under the GPL v3, and its author asks derivative works to publish their pipeline. These are the
exact scripts used for the site and the X kit:

- `gen_directions.py`: the three brand directions (vinyl, risograph, studio photo); risograph was chosen.
- `gen_post.py`, `gen_boards.py`, `gen_assets.py`: prompts for the post, the section boards and every site asset
  (gpt_image_2 through the Higgsfield CLI, with the chosen direction as the style reference).
- `process_assets.py`, `export_assets.py`: curation (lanterns recolored to ink except one, paper to alpha, dotted empty
  seats, ink grain, torn paper mask) and export to `web/public/assets`.

Models only generate the world; every letter on the site and the kit is HTML with real fonts (`brand/banner.html`,
`brand/post.html`).
