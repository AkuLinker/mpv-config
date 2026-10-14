import sys
import re
import json
import unicodedata
from difflib import SequenceMatcher

# Always write UTF-8 (see lookup.py for why).
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")
    except Exception:
        pass


def normalize(s):
    # NFKC first: decomposes compatibility characters like "½" into "1⁄2"
    # so it lines up with an ASCII "1/2" after the alnum filter below.
    s = unicodedata.normalize("NFKC", s)
    # Keep only alnum characters, lowercased, so punctuation/spacing/case
    # differences (":", "-", etc.) don't affect the score.
    return "".join(ch.lower() for ch in s if ch.isalnum())


def loose_normalize(s):
    # Like normalize(), but keeps word boundaries (spaces) - needed to spot
    # whole-word season markers ("s4", roman "iv") without them accidentally
    # gluing onto neighboring letters/digits.
    s = unicodedata.normalize("NFKC", s).lower()
    s = re.sub(r"[^a-z0-9]+", " ", s)
    return re.sub(r"\s+", " ", s).strip()


SHORT_TITLE_LEN = 4


def base_title_score(title_norm, field_norm):
    if not field_norm:
        return 0.0
    # If our (base, season-less) title is a substring of the field, that's
    # strong direct evidence - e.g. our parsed title is often exactly the
    # start of a longer official name that adds a subtitle. Only checked
    # in this direction: the reverse (field-in-title) is NOT safe here,
    # since a plain season-1-style name can end up being a prefix of some
    # unrelated longer title too.
    # Very short titles (1-3 characters) appear inside lots of unrelated
    # names, so for those only a match at the START of the name counts.
    if title_norm and title_norm in field_norm:
        if len(title_norm) >= SHORT_TITLE_LEN or field_norm.startswith(title_norm):
            return 1.0
    return SequenceMatcher(None, title_norm, field_norm).ratio()


# Highest season number recognized from season WORDING ("Season 12",
# "12th Season"). Long-running shows do go past 10.
MAX_SEASON = 30


def ordinal(n):
    if 10 <= n % 100 <= 13:
        return str(n) + "th"
    return str(n) + {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")


SPELLED_ORDINALS = {
    1: "first", 2: "second", 3: "third", 4: "fourth", 5: "fifth",
    6: "sixth", 7: "seventh", 8: "eighth", 9: "ninth", 10: "tenth",
}
ROMAN_NUMERALS = {
    2: "ii", 3: "iii", 4: "iv", 5: "v", 6: "vi", 7: "vii", 8: "viii", 9: "ix", 10: "x",
}
ROMAN_TO_INT = {v: k for k, v in ROMAN_NUMERALS.items()}

# Splits a name into "title" and "subtitle" segments, so a roman numeral
# can be recognized at the end of each segment ("Danmachi IV: Shin Shou").
SEGMENT_SPLIT_RE = re.compile(r"[:\-\u2013\u2014(\[|/]")
PART_RE = re.compile(r"\bpart (\d+)\b")
TRAILING_PART_RE = re.compile(r"\s+(?:part|cour)\s+\d+$")


def has_phrase(loose_text, phrase):
    """Whole-word match: "season 1" must not match inside "season 12"."""
    return (" " + phrase + " ") in (" " + loose_text + " ")


def roman_season(field):
    """Season implied by a roman numeral, or None.

    Only a numeral that is the LAST word of the name (or of one of its
    title/subtitle segments) counts: "Overlord IV", "Mob Psycho 100 III".
    A numeral in the middle of a name is ordinary text - otherwise the
    "x" in "Spy x Family" / "Hunter x Hunter" would read as "season 10".
    """
    for segment in SEGMENT_SPLIT_RE.split(field):
        # "... IV Part 2" - ignore a trailing part/cour number so the
        # numeral right before it is still seen as the last word.
        loose = TRAILING_PART_RE.sub("", loose_normalize(segment))
        tokens = loose.split()
        if len(tokens) >= 2 and tokens[-1] in ROMAN_TO_INT:
            return ROMAN_TO_INT[tokens[-1]]
    return None


def word_seasons(field):
    """Season numbers (1..10) a name declares with season WORDING:
    "season N", "sN", "Nth season", "second season"."""
    loose = loose_normalize(field)
    found = set()
    for n in range(1, MAX_SEASON + 1):
        phrases = ["season " + str(n), "s" + str(n), ordinal(n) + " season"]
        if n in SPELLED_ORDINALS:
            phrases.append(SPELLED_ORDINALS[n] + " season")
        if any(has_phrase(loose, p) for p in phrases):
            found.add(n)
    return found


def explicit_seasons(field):
    """Season wording plus a trailing roman numeral - everything except
    "Part N"."""
    found = word_seasons(field)
    r = roman_season(field)
    if r:
        found.add(r)
    return found


def part_numbers(field):
    return {int(m) for m in PART_RE.findall(loose_normalize(field))}


def field_seasons(field):
    """Seasons a single name declares (same idea as before: any marker
    counts), with one exception: when the name has real season WORDING,
    "Part N" no longer counts as season N - so "Season 3 Part 2" is
    season 3 only, never season 2. Without season wording, "Part N" still
    stands in for a season ("Title Part 2", "Lupin III: Part 6")."""
    found = explicit_seasons(field)
    if not word_seasons(field):
        found |= {p for p in part_numbers(field) if 1 <= p <= 10}
    return found


def has_any_season_marker(field):
    """True if the name declares ANY season/part >= 2 at all."""
    return any(n >= 2 for n in field_seasons(field))


def matches_season(field, n):
    return n in field_seasons(field)


def score_candidate(title_norm, target_season, fields):
    best_base = 0.0
    for field in fields:
        if not field:
            continue
        b = base_title_score(title_norm, normalize(field))
        if b > best_base:
            best_base = b

    # Season signal is evaluated across ALL fields (a season marker might
    # show up in "english" but not "name", for instance), independent of
    # which single field won the base-title score.
    any_field_matches_season = False
    any_field_has_other_season = False
    if target_season is not None:
        for field in fields:
            if not field:
                continue
            if matches_season(field, target_season):
                any_field_matches_season = True
            elif has_any_season_marker(field):
                any_field_has_other_season = True
    else:
        for field in fields:
            if not field:
                continue
            if has_any_season_marker(field):
                any_field_has_other_season = True

    score = best_base
    if target_season is not None:
        if any_field_matches_season:
            score = min(1.0, score + 0.3)
        elif any_field_has_other_season:
            score *= 0.3  # explicitly a different season - heavily penalize
        elif target_season != 1:
            score *= 0.5  # no season marker anywhere, and we wanted season >= 2
            # - most likely this candidate IS season 1 (which is why it has
            # no marker), just not the season we're after.
        # else: target_season == 1 and no marker anywhere - this is the
        # NORMAL, expected state for a genuine season-1 entry (nobody
        # labels the debut season "Season 1"/"S1" in its own title), so
        # don't penalize it the way we would for season >= 2.
    else:
        if any_field_has_other_season:
            score *= 0.3  # our file had no season marker; a candidate that
            # explicitly claims season >= 2 is probably the wrong one.

    return score, any_field_matches_season, best_base


# High bar for base-title similarity specifically for multi-part grouping:
# matching season text alone isn't enough evidence that two candidates are
# parts of the SAME franchise (an unrelated show could easily mention
# "Season 2" too) - genuine same-franchise part siblings should score at
# or very near 1.0 on title alone via the containment rule in
# base_title_score.
PART_GROUPING_TITLE_THRESHOLD = 0.9


def extract_part_number(fields):
    """First 'part N' number found across fields (loosely normalized), or
    None if the candidate's name doesn't declare a part at all. This is
    ONLY used to group/order candidates that already matched the target
    season via field_seasons() - "part" is not itself treated as a
    season signal here (that's a separate fallback in field_seasons)."""
    for field in fields:
        if not field:
            continue
        m = PART_RE.search(loose_normalize(field))
        if m:
            return int(m.group(1))
    return None


def extract_season_number(fields):
    """Season number (2..10) implied by the candidate's text, or 1 if no
    field declares any season at all. Used to order same-franchise
    candidates when the FILENAME ITSELF has no season marker (target_season
    is None) but some fansub groups number episodes straight through
    multiple separate season entries without ever resetting or marking
    which season - see the target_season is None branch in main().

    Two passes: explicit season wording first ("season N", "Nth season",
    "sN", roman numerals), and only if NONE of the fields has any, fall
    back to "part N" as a season stand-in. Doing it in one pass would
    misread "3rd Season Part 2" as season 2 (since "part 2" is also a
    season-2 marker and n is checked in ascending order) - the sub-part
    of a season must never override the season itself."""
    for field in fields:
        if not field:
            continue
        explicit = [n for n in explicit_seasons(field) if n >= 2]
        if explicit:
            return min(explicit)

    for field in fields:
        if not field:
            continue
        parts = [n for n in part_numbers(field) if 2 <= n <= 10]
        if parts:
            return min(parts)
    return 1


def resolve_part(part_candidates, target_episode):
    """Given candidates that already match the target season and each
    declare a part number, figure out which part `target_episode`
    (an absolute, cumulative episode number as fansub groups usually
    number them) actually falls into, and what its LOCAL episode number
    is within that part. Returns (index, local_episode) or None if it
    can't be determined (e.g. unknown episode counts blocking the count,
    or the number falls outside every known part's range).
    """
    parts = sorted(part_candidates, key=lambda c: c["part"])

    cumulative = 0
    for c in parts:
        count = c["episodes"]
        if count is None:
            # Unknown total (still airing) - can only happen for the LAST
            # part in a real franchise (an earlier part can't still be
            # airing once a later one exists). Anything past the
            # previous parts' cumulative total belongs here.
            if target_episode > cumulative:
                return c["index"], target_episode - cumulative
            return None
        if cumulative < target_episode <= cumulative + count:
            return c["index"], target_episode - cumulative
        cumulative += count

    return None  # beyond every known part - can't place it, don't guess


def main():
    try:
        # Read raw bytes and decode as UTF-8 explicitly: on Windows the
        # default stdin encoding is the ANSI codepage, which would garble
        # Japanese/Cyrillic titles sent by mpv.
        payload = json.loads(sys.stdin.buffer.read().decode("utf-8"))
        title = payload["title"]
        candidates = payload["candidates"]  # [{"index", "fields", "episodes", "kind"}, ...]
    except Exception as e:
        print("match.py: invalid input: {}".format(e), file=sys.stderr)
        sys.exit(1)

    target_season = payload.get("season")  # number or None
    target_episode = payload.get("episode")  # absolute episode number, or None
    title_norm = normalize(title)

    scored = []
    for cand in candidates:
        fields = cand.get("fields", [])
        score, matches_season_flag, best_base = score_candidate(title_norm, target_season, fields)
        is_same_franchise = best_base >= PART_GROUPING_TITLE_THRESHOLD
        scored.append({
            "index": cand["index"],
            "fields": fields,
            "score": score,
            "matches_season": matches_season_flag,
            "same_franchise": is_same_franchise,
            # A season-matching candidate with no "part N" wording at all is
            # treated as part 1 - real franchises often label only the
            # LATER installments explicitly ("Season 2 Part 2") while the
            # first one is just "Season 2" with no part suffix.
            "part": (extract_part_number(fields) or 1) if (matches_season_flag and is_same_franchise) else None,
            "episodes": cand.get("episodes"),
            "kind": cand.get("kind"),
        })

    if target_episode is not None:
        if target_season is not None:
            # Case 1: the filename DID declare a season - only disambiguate
            # "Part N" splits WITHIN that season. Only among candidates that
            # matched the target season AND are confidently the same
            # franchise (see threshold above). A single plain "Season N"
            # candidate (no siblings) never enters this path, so ordinary
            # single-part seasons behave exactly as before.
            # kind == "tv" guards against a movie/OVA/special with a
            # similar enough title being swept into the season sequence -
            # those aren't part of the main run's episode count at all.
            part_candidates = [c for c in scored if c["part"] is not None and c["kind"] == "tv"]
            if len(part_candidates) >= 2:
                resolved = resolve_part(part_candidates, target_episode)
                if resolved:
                    best_index, local_episode = resolved
                    print(json.dumps({"best_index": best_index, "score": 1.0, "episode": local_episode}))
                    return
        else:
            # Case 2: the filename has NO season marker at all - some
            # fansub groups number straight through multiple separate
            # season entries without ever marking or resetting (e.g.
            # episode 23 of a show whose Shikimori/MAL entry is split into
            # a 12-episode Season 1 and a Season 2 that continues from 13).
            # Group same-franchise candidates by their own (textually
            # implied) season number and try the same cumulative-offset
            # placement used for Part splits above.
            # Safety gate: only attempt this if at least one sibling
            # EXPLICITLY declares season >= 2 - otherwise there's no real
            # evidence this is a multi-season situation at all, and
            # grouping could just be colliding an unrelated same-titled
            # movie/special (which would also default to "season 1") with
            # the real season-1 entry.
            # kind == "tv": without this, a movie or an ONA/OVA spin-off
            # that's merely in the same franchise (even just cross-
            # referenced via a synonym, like an official mini-anime) can
            # default to "season 1" same as the real season 1 and get
            # spliced into the cumulative count ahead of the real later
            # seasons - this is exactly what happened with Kusuriya no
            # Hitorigoto's "Maomao no Hitorigoto" ONA spin-off.
            # Sort key is season * 100 + part-within-season, so e.g.
            # "3rd Season" (301) always sorts before "3rd Season Part 2"
            # (302), and both after "2nd Season" (201) - without the part
            # term, entries of the same season would tie and fall back to
            # whatever order Shikimori happened to return them in.
            season_candidates = [
                {
                    "index": c["index"],
                    "part": extract_season_number(c["fields"]) * 100 + (extract_part_number(c["fields"]) or 1),
                    "episodes": c["episodes"],
                }
                for c in scored if c["same_franchise"] and c["kind"] == "tv"
            ]
            if len(season_candidates) >= 2 and any(c["part"] >= 200 for c in season_candidates):
                resolved = resolve_part(season_candidates, target_episode)
                if resolved:
                    best_index, local_episode = resolved
                    print(json.dumps({"best_index": best_index, "score": 1.0, "episode": local_episode}))
                    return

    best = max(scored, key=lambda c: c["score"])
    print(json.dumps({"best_index": best["index"], "score": best["score"]}))


if __name__ == "__main__":
    main()
