# 01_clean.R ------------------------------------------------------------------
# Re-parse futurama_transcripts.csv (theinfosphere.org scrape, June 2023) into
# one clean row per spoken line.
#
# Why re-parse: get_transcripts.R split each line on "⨂" (timestamp) and then on
# ":" (speaker). Only 8 of 144 episodes have timestamps, so for the rest the
# whole "Speaker: dialogue" text landed in the `timestamp` column and
# `character`/`line` are NA. Splitting on ":" with separate() also dropped
# everything after a second colon. Here we rebuild the full text and split on
# the FIRST colon only.
#
# Input : futurama_transcripts.csv            (raw, private; never publish)
# Output: data-private/lines_clean.rds        (line-level, private; never publish)
#         output/speaker_aliases.csv          (name merges applied, for the methods note)
#         output/parse_report.csv             (row counts at each step)
#
# Run from the project root (open futurama_transcripts.Rproj).

library(dplyr)
library(readr)
library(stringr)
library(tibble)

dir.create("data-private", showWarnings = FALSE)
dir.create("output", showWarnings = FALSE)

raw <- read_csv(
  "futurama_transcripts.csv",
  col_types = cols(.default = col_character()),
  na = c("", "NA"),
  name_repair = "minimal"
) |>
  select(timestamp, character, line, episode_url) |>
  mutate(row_id = row_number())

# Episodes -------------------------------------------------------------------
# Order = order in theinfosphere.org's transcript listing (production order,
# films last). This is NOT broadcast order; use an air-date table for that.
films <- c(
  "Bender's Big Score", "The Beast with a Billion Backs",
  "Bender's Game", "Into the Wild Green Yonder"
)

episodes <- raw |>
  distinct(episode_url) |>
  mutate(
    episode_order = row_number(),
    episode = episode_url |>
      str_remove("^https://theinfosphere.org/Transcript:") |>
      URLdecode() |>
      str_replace_all("_", " "),
    type = if_else(episode %in% films, "film", "episode")
  )

stopifnot(nrow(episodes) == 144, sum(episodes$type == "film") == 4)

# Rebuild the full "Speaker: dialogue" text ----------------------------------
# Timestamp-format rows: speaker in `character`, dialogue in `line`, timestamp
# kept. Everything else: the full text is in `timestamp`.
lines <- raw |>
  mutate(
    has_timestamp = !is.na(character),
    full_text = if_else(has_timestamp, paste0(character, ":", coalesce(line, "")), timestamp),
    timestamp = if_else(has_timestamp, str_squish(timestamp), NA_character_),
    full_text = str_squish(str_replace_all(full_text, "[\r\n]+", " "))
  ) |>
  filter(!is.na(full_text), full_text != "")

# Strip stage directions -----------------------------------------------------
# Non-greedy: [ ... ] and ( ... ) each removed separately, so text between two
# directions survives. A "[" that never closes (20 rows in the source) is a
# direction running to the end of the line; drop from it to the end. A stray
# "]" is just removed.
strip_directions <- function(x) {
  x |>
    str_remove_all("\\[[^\\[\\]]*\\]") |>
    str_remove_all("\\([^()]*\\)") |>
    str_remove("\\[.*$") |>
    str_remove_all("\\]") |>
    str_squish()
}

lines <- lines |>
  mutate(text_nodir = strip_directions(full_text))

# Split speaker on the FIRST colon -------------------------------------------
# Speaker capped at 80 characters so a colon deep inside a sentence is not
# mistaken for a speaker label. Group speakers ("Fry, Amy and Bender") are kept
# as-is and not credited to any individual.
parts <- str_match(lines$text_nodir, "^([^:]{1,80}?)\\s*:\\s*(.*)$")

lines <- lines |>
  mutate(
    speaker_raw = str_squish(parts[, 2]),
    text        = str_squish(parts[, 3])
  )

# Speaker names --------------------------------------------------------------
# Merge the same individual across alternate universes ("Bender 1", "Bender A",
# "Bender-2"), avatars ("Bender-Droid"), and ghosts. Other characters' robot
# copies ("Robot Leela") and relatives stay separate.
main_cast <- c("Fry", "Bender", "Leela", "Farnsworth", "Zoidberg", "Amy",
               "Hermes", "Zapp", "Kif", "Nibbler", "Scruffy", "Mom", "Nixon",
               "Calculon", "Cubert", "Lrrr", "Elzar", "Morbo", "Linda")

canonical_speaker <- function(x) {
  base <- x |>
    str_replace("^(Professor|Prof\\.) Farnsworth$", "Farnsworth") |>
    str_replace("^Professor$", "Farnsworth") |>
    str_replace("^Zapp Brannigan$", "Zapp") |>
    str_replace("^Bender's ghost$", "Bender") |>
    str_replace("^Bender duplicates?$", "Bender")
  # Universe / version suffixes: "Bender 1", "Bender A", "Bender-2", "Fry-Droid"
  stem <- str_match(base, "^(.+?)(?:\\s*-\\s*|\\s+)(?:\\d{1,2}|[AB]|Droid)$")[, 2]
  if_else(!is.na(stem) & stem %in% main_cast, stem, base)
}

lines <- lines |>
  mutate(speaker = canonical_speaker(speaker_raw))

speaker_aliases <- lines |>
  filter(!is.na(speaker), speaker != speaker_raw) |>
  count(speaker, speaker_raw, name = "lines", sort = TRUE)

# Final table ----------------------------------------------------------------
lines_clean <- lines |>
  filter(!is.na(speaker), !is.na(text), text != "") |>
  left_join(episodes, by = "episode_url") |>
  select(row_id, episode_order, episode, type, has_timestamp, timestamp,
         speaker, speaker_raw, text)

parse_report <- tribble(
  ~step,                                        ~rows,
  "Rows in raw CSV",                            nrow(raw),
  "Rows with text",                             nrow(lines),
  "  already split (timestamp format)",         sum(lines$has_timestamp),
  "  re-split on first colon here",             sum(!lines$has_timestamp & !is.na(lines$speaker)),
  "Dropped: no speaker (actions, song verses)", sum(is.na(lines$speaker)),
  "Dropped: speaker but empty after cleaning",  sum(!is.na(lines$speaker) & (is.na(lines$text) | lines$text == "")),
  "Clean spoken lines",                         nrow(lines_clean),
  "Lines with a 2nd colon (kept in full)",      sum(str_detect(lines_clean$text, ":")),
  "Episodes",                                   sum(episodes$type == "episode"),
  "Films",                                      sum(episodes$type == "film")
)

saveRDS(lines_clean, "data-private/lines_clean.rds")
write_csv(episodes |> select(episode_order, episode, type), "output/episodes.csv")
write_csv(speaker_aliases, "output/speaker_aliases.csv")
write_csv(parse_report, "output/parse_report.csv")

print(parse_report, n = Inf)
