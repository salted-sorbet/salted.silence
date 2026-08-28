#!/usr/bin/env python3
# Atomic, no-reopen write of a JSON state file:
#   usage: write-state.py <payload-bytes> <state-file>
# The complete content is written through the exclusively created temporary
# inode (mkstemp keeps the fd open the whole time - there is no window where
# the temp pathname can be reopened), then atomically renamed over the target.
# rename() replaces the target entry itself, so a link planted there is
# replaced, never followed.
import base64
import os
import sys
import tempfile

payload = sys.argv[1]
state_file = sys.argv[2]

data = base64.b64decode(payload.encode("ascii"))
state_dir = os.path.dirname(state_file)

fd, tmp = tempfile.mkstemp(prefix=".tmp.", dir=state_dir)
try:
    os.write(fd, data)
    os.fsync(fd)
except Exception:
    os.close(fd)
    os.unlink(tmp)
    sys.exit(1)
os.close(fd)

os.rename(tmp, state_file)