import sys
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


def ratio(a, b):
    return SequenceMatcher(None, normalize(a), normalize(b)).ratio()


def main():
    payload = json.loads(sys.stdin.read())
    title = payload["title"]
    candidates = payload["candidates"]  # [{"index": int, "fields": [str, ...]}, ...]

    best_index = None
    best_score = -1.0

    for cand in candidates:
        score = 0.0
        for field in cand.get("fields", []):
            if not field:
                continue
            field_score = ratio(title, field)
            if field_score > score:
                score = field_score
        if score > best_score:
            best_score = score
            best_index = cand["index"]

    print(json.dumps({"best_index": best_index, "score": best_score}))


if __name__ == "__main__":
    main()
