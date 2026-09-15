import sys
import os
import json

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
