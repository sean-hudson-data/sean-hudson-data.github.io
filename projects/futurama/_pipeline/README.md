# Futurama counts pipeline

These scripts are copies for reference. They run in the private `futurama_transcripts`
project, which holds the raw transcript CSV; nothing raw or line-level lives in this repo.

1. `01_clean.R`: re-parses the raw transcripts into one row per spoken line (private output).
2. `02_counts.R`: writes the aggregated tables that are copied into `../data/`.

After re-running, copy `output/*.csv` from that project into `projects/futurama/data/`.
Folders starting with `_` are ignored by Quarto, so these files are never rendered or published.
Scraping code is deliberately not included.
