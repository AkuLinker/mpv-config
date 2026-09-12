import sys
import re
import json
import unicodedata
from difflib import SequenceMatcher


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


def base_title_score(title_norm, field_norm):
    if not field_norm:
        return 0.0
    # If our (base, season-less) title is a substring of the field, that's
    # strong direct evidence - e.g. our parsed title is often exactly the
    # start of a longer official name that adds a subtitle. Only checked
    # in this direction: the reverse (field-in-title) is NOT safe here,
    # since a plain season-1-style name can end up being a prefix of some
    # unrelated longer title too.
    if title_norm and title_norm in field_norm:
        return 1.0
    return SequenceMatcher(None, title_norm, field_norm).ratio()


ORDINAL_WORDS = {
    2: "2nd", 3: "3rd", 4: "4th", 5: "5th", 6: "6th",
    7: "7th", 8: "8th", 9: "9th", 10: "10th",
}
ROMAN_NUMERALS = {
    2: "ii", 3: "iii", 4: "iv", 5: "v", 6: "vi", 7: "vii", 8: "viii", 9: "ix", 10: "x",
}


def season_markers(n):
    """Normalized (loose) text markers that indicate season `n` (n >= 2)."""
    markers = {"season " + str(n), "s" + str(n), "part " + str(n)}
    if n in ORDINAL_WORDS:
        markers.add(ORDINAL_WORDS[n] + " season")
    if n in ROMAN_NUMERALS:
        markers.add(ROMAN_NUMERALS[n])
    return markers


def has_marker(loose_text, marker):
    tokens = loose_text.split()
    if " " in marker:
        return marker in loose_text
    return marker in tokens


def has_any_season_marker(loose_text):
    """True if the text declares ANY season/part >= 2 at all."""
    for n in range(2, 11):
        for m in season_markers(n):
            if has_marker(loose_text, m):
                return True
    return False


def matches_season(loose_text, n):
    return any(has_marker(loose_text, m) for m in season_markers(n))


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
            loose = loose_normalize(field)
            if matches_season(loose, target_season):
                any_field_matches_season = True
            elif has_any_season_marker(loose):
                any_field_has_other_season = True
    else:
        for field in fields:
            if not field:
                continue
            if has_any_season_marker(loose_normalize(field)):
                any_field_has_other_season = True

    score = best_base
    if target_season is not None:
        if any_field_matches_season:
            score = min(1.0, score + 0.3)
        elif any_field_has_other_season:
            score *= 0.3  # explicitly a different season - heavily penalize
        else:
            score *= 0.5  # no season marker anywhere - likely a plain/season-1
            # entry, and we're specifically looking for season >= 2
    else:
        if any_field_has_other_season:
            score *= 0.3  # our file had no season marker; a candidate that
            # explicitly claims season >= 2 is probably the wrong one.

    return score, any_field_matches_season, best_base


PART_RE = re.compile(r"\bpart (\d+)\b")


def extract_part_number(fields):
    """First 'part N' number found across fields (loosely normalized), or
    None if the candidate's name doesn't declare a part at all. This is
    ONLY used to group/order candidates that already matched the target
    season via season_markers() - "part" is not itself treated as a
    season signal here (that's a separate, existing fallback in
    matches_season/season_markers)."""
    for field in fields:
        if not field:
            continue
        m = PART_RE.search(loose_normalize(field))
        if m:
            return int(m.group(1))
    return None


def resolve_part(season_matches, target_episode):
    """Given candidates that already match the target season and each
    declare a part number, figure out which part `target_episode`
    (an absolute, cumulative episode number as fansub groups usually
    number them) actually falls into, and what its LOCAL episode number
    is within that part. Returns (index, local_episode) or None if it
    can't be determined (e.g. unknown episode counts blocking the count,
    or the number falls outside every known part's range).
    """
    parts = sorted(season_matches, key=lambda c: c["part"])

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
    payload = json.loads(sys.stdin.read())
    title = payload["title"]
    target_season = payload.get("season")  # number or None
    target_episode = payload.get("episode")  # absolute episode number, or None
    candidates = payload["candidates"]  # [{"index", "fields", "episodes"}, ...]
    title_norm = normalize(title)

    # High bar for base-title similarity specifically for multi-part
    # grouping: matching season text alone isn't enough evidence that two
    # candidates are parts of the SAME franchise (an unrelated show could
    # easily mention "Season 2" too) - genuine same-franchise part
    # siblings should score at or very near 1.0 on title alone via the
    # containment rule in base_title_score.
    PART_GROUPING_TITLE_THRESHOLD = 0.9

    scored = []
    for cand in candidates:
        fields = cand.get("fields", [])
        score, matches_season_flag, best_base = score_candidate(title_norm, target_season, fields)
        is_same_franchise = best_base >= PART_GROUPING_TITLE_THRESHOLD
        scored.append({
            "index": cand["index"],
            "score": score,
            "matches_season": matches_season_flag,
            # A season-matching candidate with no "part N" wording at all is
            # treated as part 1 - real franchises often label only the
            # LATER installments explicitly ("Season 2 Part 2") while the
            # first one is just "Season 2" with no part suffix.
            "part": (extract_part_number(fields) or 1) if (matches_season_flag and is_same_franchise) else None,
            "episodes": cand.get("episodes"),
        })

    # Multi-part disambiguation: only among candidates that matched the
    # target season AND are confidently the same franchise (see threshold
    # above). A single plain "Season N" candidate (no siblings) never
    # enters this path, so ordinary single-part seasons behave exactly
    # as before.
    season_matches = [c for c in scored if c["part"] is not None]
    if target_episode is not None and len(season_matches) >= 2:
        resolved = resolve_part(season_matches, target_episode)
        if resolved:
            best_index, local_episode = resolved
            print(json.dumps({"best_index": best_index, "score": 1.0, "episode": local_episode}))
            return

    best = max(scored, key=lambda c: c["score"])
    print(json.dumps({"best_index": best["index"], "score": best["score"]}))


if __name__ == "__main__":
    main()
