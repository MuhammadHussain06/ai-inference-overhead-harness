#!/usr/bin/env python3
"""Keeps the k6 JSON-lines Points whose metric is in KEEP, streaming line by line.

    k6_filter.py finalize RAW OUT.gz KEEP   filter RAW into a new gzip file
    k6_filter.py append   RAW OUT KEEP      filter RAW onto the end of a plain file
    k6_filter.py gzip     PLAIN OUT.gz      gzip an already-filtered file

KEEP is a comma-separated metric list.
"""

import gzip
import json
import shutil
import sys

# zlib's default. Level 9 takes about twice as long for files about 8% smaller,
# which on the high-throughput cells costs more wall clock than the filter itself.
COMPRESS_LEVEL = 6

# k6 writes each sample as {"metric":"<name>","type":"Point","data":{...}}, so the
# name is read from that fixed prefix instead of parsing every line. A complete
# Point line ends with the tags, data and envelope closing together; any line not
# in that exact shape takes the full parse.
_PREFIX = '{"metric":"'
_POINT = '","type":"Point",'


def kept(line, keep):
    if line.startswith(_PREFIX) and line.endswith("}}}"):
        end = line.find('"', len(_PREFIX))
        if end > 0 and line.startswith(_POINT, end):
            return line[len(_PREFIX):end] in keep
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        return False
    return isinstance(obj, dict) and obj.get("type") == "Point" and obj.get("metric") in keep


def filter_stream(fin, fout, keep):
    for raw in fin:
        line = raw.strip()
        if line and kept(line, keep):
            fout.write(line + "\n")


def main(argv):
    if len(argv) == 5 and argv[1] in ("finalize", "append"):
        src, dst, keep = argv[2], argv[3], set(argv[4].split(","))
        if argv[1] == "finalize":
            out = gzip.open(dst, "wt", encoding="utf-8", compresslevel=COMPRESS_LEVEL)
        else:
            out = open(dst, "a", encoding="utf-8")
        with open(src, encoding="utf-8") as fin, out:
            filter_stream(fin, out, keep)
    elif len(argv) == 4 and argv[1] == "gzip":
        with open(argv[2], "rb") as fin, gzip.open(argv[3], "wb", compresslevel=COMPRESS_LEVEL) as fout:
            shutil.copyfileobj(fin, fout, 1 << 20)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
