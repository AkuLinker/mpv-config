import sys
import os
import json

# Always talk UTF-8 with mpv, whatever the OS default is (on Windows the
# default is the ANSI codepage, which can't represent Japanese/Cyrillic
# titles and would crash or garble the output). main.lua also starts Python
# with "-X utf8"; this is a second safety net.
for stream in (sys.stdout, sys.stderr):
    try:
        stream.reconfigure(encoding="utf-8")
    except Exception:
        pass

# The bundled "anitopy" package lives next to this file.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import anitopy


def main():
    if len(sys.argv) < 2:
        print("lookup.py: missing filename argument", file=sys.stderr)
        sys.exit(1)

    filename = sys.argv[1]
    try:
        info = anitopy.parse(filename)
    except Exception as e:
        print("lookup.py: anitopy.parse() failed: {}".format(e), file=sys.stderr)
        sys.exit(1)

    print(json.dumps(info, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
