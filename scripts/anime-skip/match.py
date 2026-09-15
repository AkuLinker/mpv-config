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


PART_RE = re.compile(r"\bpart (\d+)\b")

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


def extract_season_number(fields):
    """Season number (2..10) implied by season_markers() text, or 1 if no
    field declares any season at all. Used to order same-franchise
    candidates when the FILENAME ITSELF has no season marker (target_season
    is None) but some fansub groups number episodes straight through
    multiple separate season entries without ever resetting or marking
    which season - see the target_season is None branch in main()."""
    for field in fields:
        if not field:
            continue
        loose = loose_normalize(field)
        for n in range(2, 11):
            if matches_season(loose, n):
                return n
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
        payload = json.loads(sys.stdin.read())
        title = payload["title"]
        candidates = payload["candidates"]  # [{"index", "fields", "episodes"}, ...]
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
        })

    if target_episode is not None:
        if target_season is not None:
            # Case 1: the filename DID declare a season - only disambiguate
            # "Part N" splits WITHIN that season. Only among candidates that
            # matched the target season AND are confidently the same
            # franchise (see threshold above). A single plain "Season N"
            # candidate (no siblings) never enters this path, so ordinary
            # single-part seasons behave exactly as before.
            part_candidates = [c for c in scored if c["part"] is not None]
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
            season_candidates = [
                {"index": c["index"], "part": extract_season_number(c["fields"]), "episodes": c["episodes"]}
                for c in scored if c["same_franchise"]
            ]
            if len(season_candidates) >= 2 and any(c["part"] > 1 for c in season_candidates):
                resolved = resolve_part(season_candidates, target_episode)
                if resolved:
                    best_index, local_episode = resolved
                    print(json.dumps({"best_index": best_index, "score": 1.0, "episode": local_episode}))
                    return

    best = max(scored, key=lambda c: c["score"])
    print(json.dumps({"best_index": best["index"], "score": best["score"]}))


if __name__ == "__main__":
    main()
