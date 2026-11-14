# 02_counts.R -----------------------------------------------------------------
# Word counts for "What is Bender's most-used word?"
#
# Input : data-private/lines_clean.rds   (from 01_clean.R; private)
# Output: output/*.csv                   (aggregated counts only; safe to publish)
#
# Definitions (state these on the page):
# - Tokens: tidytext::unnest_tokens() defaults (lowercase, punctuation stripped,
#   contractions and possessives kept whole, so "bender's" != "bender").
# - Stop words: tidytext::stop_words (all three lexicons), as in the 2023 article,
#   PLUS interjections and fillers ("hey", "yeah", "uh", "ohhh", "gonna"), which
#   tidytext doesn't cover. See is_filler() below.
# - Stems: SnowballC::wordStem(), English Porter stemmer.
# - Ranks: min_rank(), so ties share a rank and the next rank is skipped
#   (two words tied at 14th are both 14th; the next is 16th).
# - Scope: the 140 broadcast episodes. These include the four films as 16
#   "Part" episodes, so the full-length film transcripts are dropped as duplicates.
# - Only named, individual speakers are credited; group lines ("Fry and Bender")
#   are excluded from character totals.
# - Why fillers matter: with only tidytext stop words, "hey" edges out
#   "bender" as Bender's top word. output/sensitivity_fillers.csv keeps that
#   comparison for the methods note.

library(dplyr)
library(readr)
library(tidyr)
library(tidytext)
library(SnowballC)

lines_clean <- readRDS("data-private/lines_clean.rds") |>
  filter(type == "episode")   # full-length films repeat the 16 "Part" episodes

# Interjections and fillers --------------------------------------------------
# A fixed list plus a pattern, so stretched spellings ("ohhhh", "hmmm", "wooo",
# "hahahaha") are caught too. Check output/fillers_removed.csv after changes.
filler_words <- c("hey", "yeah", "yes", "yep", "yup", "nah", "nope", "okay", "ok",
                  "alright", "um", "er", "yo", "oops", "gonna", "gotta", "wanna")
filler_pattern <- paste0(
  "^(a+h+|a+w+|o+h+|o+w+|o+o+h*|u+h+|h+m+|m+h*m+|h+u+h+|w+h*o+a+h*|y+a+y+|",
  "h+a+(h+a+)*|h+e+h+|u+g+h+|e+h+|w+h*o+o+[hp]*|w+o+w+|y+e+a+h+|p+s+t+|s+h+)$"
)
is_filler <- function(w) w %in% filler_words | grepl(filler_pattern, w)

# One row per token. Kept in memory only: token-level data is never written out.
tokens <- lines_clean |>
  select(episode_order, episode, type, speaker, text) |>
  unnest_tokens(word, text) |>
  filter(!grepl("^[0-9.,]+$", word)) |>          # drop bare numbers
  mutate(stem = wordStem(word, language = "english"),
         is_tidytext_stop = word %in% stop_words$word,
         is_filler = !is_tidytext_stop & is_filler(word),
         is_stop = is_tidytext_stop | is_filler)

content <- tokens |> filter(!is_stop)

rank_words <- function(df, col) {
  df |>
    mutate(rank = min_rank(desc(n))) |>
    arrange(rank, {{ col }})
}

# Character totals -----------------------------------------------------------
character_totals <- tokens |>
  group_by(speaker) |>
  summarise(words = n(), content_words = sum(!is_stop), .groups = "drop") |>
  left_join(count(lines_clean, speaker, name = "lines"), by = "speaker") |>
  arrange(desc(words))

# 1. Bender's top words ------------------------------------------------------
bender_top_words <- content |>
  filter(speaker == "Bender") |>
  count(word, name = "n") |>
  rank_words(word)

bender_top_stems <- content |>
  filter(speaker == "Bender") |>
  count(stem, name = "n") |>
  rank_words(stem)

# Sensitivity: Bender's top 10 with tidytext stop words only (fillers kept)
# vs. the definition used on the page
sensitivity_fillers <- bind_rows(
  tokens |> filter(speaker == "Bender", !is_tidytext_stop) |>
    count(word, name = "n") |> mutate(definition = "tidytext stop words only"),
  content |> filter(speaker == "Bender") |>
    count(word, name = "n") |> mutate(definition = "also excluding fillers")
) |>
  group_by(definition) |>
  mutate(rank = min_rank(desc(n))) |>
  filter(rank <= 10 | word == "ass") |>
  arrange(definition, rank, word) |>
  ungroup() |>
  select(definition, rank, word, n)

# Audit trail: every filler removed, with counts across all speakers
fillers_removed <- tokens |>
  filter(is_filler) |>
  count(word, name = "n", sort = TRUE)

# 2. Who says "ass" most -----------------------------------------------------
ass_by_character <- tokens |>
  filter(word == "ass" | stem == "ass") |>
  group_by(speaker) |>
  summarise(ass_exact = sum(word == "ass"),
            ass_stem  = sum(stem == "ass"), .groups = "drop") |>
  left_join(select(character_totals, speaker, words), by = "speaker") |>
  mutate(ass_per_10k_words = 1e4 * ass_exact / words) |>
  arrange(desc(ass_exact))

# 3. Per-word rates for the main speakers ------------------------------------
# Content-word counts for every speaker with at least 2,000 words spoken, plus
# rate per 1,000 words (all words, stop words included, as the denominator).
main_speakers <- character_totals |> filter(words >= 2000) |> pull(speaker)

character_word_counts <- content |>
  filter(speaker %in% main_speakers) |>
  count(speaker, word, name = "n") |>
  filter(n >= 3) |>
  left_join(select(character_totals, speaker, words), by = "speaker") |>
  mutate(per_1k_words = 1e3 * n / words) |>
  select(-words) |>
  arrange(speaker, desc(n))

# 4. The episode's claimed top ten vs. real counts ---------------------------
# Counted over ALL of Bender's tokens: three of the claimed words ("my",
# "yours", "up") are stop words and would vanish otherwise. Left join from the
# claimed list keeps zero-count words.
claimed_top_ten <- tibble(
  claimed_rank = 1:10,
  word = c("chump", "chumpette", "yours", "up", "pimpmobile",
           "bite", "my", "shiny", "daffodil", "ass")
)   # TODO: confirm order against the episode

bender_all_words <- tokens |>
  filter(speaker == "Bender") |>
  count(word, name = "n") |>
  mutate(rank_all_words = min_rank(desc(n)))

claimed_vs_actual <- claimed_top_ten |>
  left_join(bender_all_words, by = "word") |>
  left_join(select(bender_top_words, word, rank_content_words = rank), by = "word") |>
  mutate(n = replace_na(n, 0L),
         is_stop_word = word %in% stop_words$word | is_filler(word))

# 5. Bender x episode x word (for the "was it true when it aired?" callout) --
# Bag-of-words counts per episode; no order within an episode.
bender_word_by_episode <- content |>
  filter(speaker == "Bender") |>
  count(episode_order, episode, type, word, stem, name = "n") |>
  arrange(episode_order, desc(n), word)

# Write ----------------------------------------------------------------------
write_csv(character_totals,        "output/character_totals.csv")
write_csv(bender_top_words,        "output/bender_top_words.csv")
write_csv(bender_top_stems,        "output/bender_top_stems.csv")
write_csv(ass_by_character,        "output/ass_by_character.csv")
write_csv(character_word_counts,   "output/character_word_counts.csv")
write_csv(claimed_vs_actual,       "output/claimed_vs_actual.csv")
write_csv(bender_word_by_episode,  "output/bender_word_by_episode.csv")
write_csv(sensitivity_fillers,     "output/sensitivity_fillers.csv")
write_csv(fillers_removed,         "output/fillers_removed.csv")

# Headline numbers -----------------------------------------------------------
ass_rank      <- bender_top_words |> filter(word == "ass")
ass_stem_rank <- bender_top_stems |> filter(stem == "ass")
cat("\nBender's top 10 content words:\n"); print(head(bender_top_words, 10))
cat(sprintf("\n'ass': %d uses, rank %d unstemmed; %d uses, rank %d stemmed\n",
            ass_rank$n, ass_rank$rank, ass_stem_rank$n, ass_stem_rank$rank))
cat("\nTop 'ass' users:\n"); print(head(ass_by_character, 5))
