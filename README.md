# Portfolio

Personal data science portfolio built with [Quarto](https://quarto.org) and hosted on GitHub Pages.

## Layout

```
_quarto.yml                 site config (theme, navbar, freeze, post-render check)
index.qmd                   home: intro + featured projects
projects.qmd                full project listing, filterable by category
about.qmd
projects/
  _metadata.yml             code-fold, code-tools for every project page
  mco-medicaid/index.qmd
  futurama/index.qmd        (+ futurama.css for the Planet Express accent)
  futurama/data/            aggregated counts only (allowlisted in published-data.txt)
  futurama/_pipeline/       reference copies of the R cleaning/counting scripts (never rendered)
  cni-sample/index.qmd
  food-store-definitions/index.qmd
_templates/project.qmd      starter page: R/Python tabsets, OJS hand-off
assets/                     dark.scss, styles.css, placeholder image
scripts/check_site.py       fails the render if unapproved data lands in _site/
scripts/published-data.txt  allowlist of aggregated data files that may be published
.github/workflows/          optional CI publish from _freeze/
```

## Day to day

```bash
quarto preview          # live reload; draft pages are visible here
quarto render           # full build; drafts are excluded
```

Every project page starts with `draft: true`. Delete that line when a page is ready
to go live; it then appears in the listings and the published site.

To start a new project: copy `_templates/project.qmd` to `projects/<slug>/index.qmd`.

## Code and computation

- `freeze: auto` re-executes a page only when its source changes. Results are cached
  in `_freeze/`, which **is committed** so CI can build without R, Python, or data.
- After changing analysis code, render locally (`quarto render projects/<slug>/index.qmd`)
  and commit the updated `_freeze/` along with the source.
- Pages that mix R and Python chunks run on knitr with reticulate (`engine: knitr`).
  Python-only pages run on Jupyter.

## Data rules

- Only aggregated data (counts by character, word, episode; tract-level flags) is ever
  published. Raw inputs live in gitignored folders (`data-raw/`, `raw/`, `transcripts/`).
- Futurama: no scraping code, transcripts, line-level, or token-order data in the repo or site.
- `scripts/check_site.py` runs after every render. Any data-like file in `_site/` that isn't
  listed in `scripts/published-data.txt`, or that sits under a `raw/`/`transcripts/` folder,
  fails the build.

## Publishing

**First time**

1. On github.com, create an **empty** public repo named `sean-hudson-data.github.io` under
   `sean-hudson-data` (no README or .gitignore). That name makes the site live at
   https://sean-hudson-data.github.io.
2. From PowerShell in this folder:

   ```powershell
   git init -b main
   git add .
   git commit -m "Scaffold portfolio site with Futurama counts"
   git remote add origin https://github.com/sean-hudson-data/sean-hudson-data.github.io.git
   git push -u origin main
   ```

3. Run `quarto publish gh-pages`. This creates the `gh-pages` branch and writes
   `_publish.yml`; commit and push that file.
4. In the repo: Settings → Pages → Source: *Deploy from a branch*, branch `gh-pages`, `/ (root)`.

**Custom domain (later)**: create a `CNAME` file containing the domain, add it under
`resources:` in `_quarto.yml`, update `site-url`, then add DNS records at your registrar
(apex: four `A` records to GitHub Pages IPs; `www`: a `CNAME` to `sean-hudson-data.github.io`)
and tick *Enforce HTTPS* once the certificate is issued.

**After that**, either:

- run `quarto publish gh-pages` locally, or
- push to `main` and let `.github/workflows/publish.yml` render from `_freeze/` and publish.

Use one or the other; delete the workflow if you'd rather publish by hand.

## TODO before first publish

- [ ] Fill in the LinkedIn URL in `_quarto.yml`
- [ ] Write the home intro and About page
- [ ] Take at least one project out of draft
