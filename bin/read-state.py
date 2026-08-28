#!/usr/bin/env python3
# Bounded, descriptor-safe read of a JSON state file:
#   usage: read-state.py <path>
# The open uses O_NOFOLLOW|O_NONBLOCK, everything validates against the same
# descriptor via fstat, and at most 64 KiB of exactly-reported bytes are read.
# Non-zero exit code on refusal; never prints diagnostics to stdout.
import os
import stat
import sys

path = sys.argv[1]
flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0)
try:
    fd = os.open(path, flags)
except OSError:
    sys.exit(2)
try:
    st = os.fstat(fd)
    if st.st_uid != os.getuid():
        sys.exit(3)
    if not stat.S_ISREG(st.st_mode):
        sys.exit(4)
    if st.st_size > 65536:
        sys.exit(5)
    data = os.read(fd, st.st_size + 1)
finally:
    os.close(fd)
if not data or len(data) != st.st_size:
    sys.exit(6)
sys.stdout.write(data.decode("utf-8", "replace"))