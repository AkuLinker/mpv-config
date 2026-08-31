import sys
import os
import json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import anitopy

def main():
    filename = sys.argv[1]
    info = anitopy.parse(filename)
    print(json.dumps(info, indent=2, ensure_ascii=False))

if __name__ == "__main__":
    main()
