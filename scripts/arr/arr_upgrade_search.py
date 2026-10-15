#!/usr/bin/env python3
"""Independent ARR search CLI; defaults to dry-run."""
import sys
import os
import tempfile
sys.pycache_prefix = os.path.join(tempfile.gettempdir(), 'arr-pycache-' + str(os.getuid()))
from arr_common import cli

if __name__ == "__main__":
    from datetime import datetime
    print("————————————执行开始(" + datetime.now().strftime("%Y-%m-%d %H:%M") + ")————————————", flush=True)
    try:
        raise SystemExit(cli("search"))
    finally:
        print("————————————执行完毕(" + datetime.now().strftime("%Y-%m-%d %H:%M") + ")————————————", flush=True)
