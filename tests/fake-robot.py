#!/usr/bin/env python3
"""A fake Dreame FEL payload speaking fastboot over TCP (the protocol Google's `fastboot -s tcp:` uses), so that
the official fastboot and our fbtool can be run against the same "robot" and compared byte for byte.

Modelled on what we know of the dustbuilder payload: `getvar config` required first, max-download-size 32 MiB
("FAILdownload: data > buffer" above it), `oem dust <check>` then `oem prep` before any flash, flash of raw or
Android-sparse data into partitions (written to OUTDIR/<part>.img), `upload` of the current stage (0 unless
`oem stage1|2`) rebuilt from them and XOR-encrypted as the real one (tests/flashsim.py), reboot. Anything else
answers FAIL.
Every command and a sha256 of every download goes to OUTDIR/transcript.jsonl.

usage: fake-robot.py PORT OUTDIR [GATE_FILE]   (with GATE_FILE, connections are refused until it exists,
                                                 like a robot that is not in fastboot yet)
"""
import hashlib
import json
import os
import socket
import struct
import sys

import flashsim

CONFIG = os.environ["FAKE_CONFIG"]   # the job's configvalue
CHECK = os.environ["FAKE_CHECK"]     # the job's check.txt
MAX = 0x02000000

port, out = int(sys.argv[1]), sys.argv[2]
gate = sys.argv[3] if len(sys.argv) > 3 else None
os.makedirs(out, exist_ok=True)
state = {"config": False, "dust": False, "prep": False, "buf": None, "stage": 0}
log = open(os.path.join(out, "transcript.jsonl"), "a", buffering=1)


def record(**kw):
    log.write(json.dumps(kw) + "\n")


def recv_exact(c, n):
    b = bytearray()
    while len(b) < n:
        chunk = c.recv(min(n - len(b), 1 << 20))
        if not chunk:
            raise EOFError
        b += chunk
    return bytes(b)


def recv_msg(c):
    (n,) = struct.unpack(">Q", recv_exact(c, 8))
    return recv_exact(c, n)


def send_msg(c, data):
    c.sendall(struct.pack(">Q", len(data)) + data)


def flash(part):
    data = state["buf"]
    if part not in flashsim.SIZES:
        return "FAILunknown partition"
    if not (state["dust"] and state["prep"]):
        return "FAILnot prepared"
    if data is None:
        return "FAILno data"
    err = flashsim.write(out, part, data)
    return "FAIL" + err if err else "OKAY"


def handle(c):
    if recv_exact(c, 4) != b"FB01":
        return
    c.sendall(b"FB01")
    while True:
        cmd = recv_msg(c).decode(errors="replace")
        if cmd.startswith("getvar:"):
            var = cmd[7:]
            record(cmd=cmd)
            vals = {"config": CONFIG, "dustversion": "2024.12.00", "max-download-size": "0x%08x" % MAX,
                    "product": "Android Fastboot"}
            if var == "config":
                state["config"] = True
            if var == "toc1hash":   # as on the real robot: toc1 name[:4] + magic + add_sum of the toc1 on flash
                p = os.path.join(out, "toc1.img")
                t = open(p, "rb").read(24) if os.path.exists(p) else None
                vals[var] = (t[:4] + t[16:24]).hex() if t else os.environ["FAKE_TOC1HASH"]
            send_msg(c, ("OKAY" + vals[var]).encode() if var in vals else b"FAILnot supported")
        elif cmd.startswith("download:"):
            n = int(cmd[9:], 16)
            if n == 0:
                record(cmd=cmd, result="FAIL")
                send_msg(c, b"FAILdownload: data size is 0")
                continue
            if n > MAX:
                record(cmd=cmd, result="FAIL")
                send_msg(c, b"FAILdownload: data > buffer")
                continue
            send_msg(c, b"DATA%08x" % n)
            buf = bytearray()
            while len(buf) < n:
                buf += recv_msg(c)
            if len(buf) != n:
                record(cmd=cmd, result="FAIL", got=len(buf))
                send_msg(c, b"FAILtoo much data")
                continue
            state["buf"] = bytes(buf)
            record(cmd="download", size=n, sha256=hashlib.sha256(buf).hexdigest())
            send_msg(c, b"OKAY")
        elif cmd == "upload":
            data = flashsim.stage(out, state["stage"])
            record(cmd=cmd, stage=state["stage"], size=len(data))
            send_msg(c, b"DATA%08x" % len(data))
            for i in range(0, len(data), 1 << 20):
                send_msg(c, data[i:i + (1 << 20)])
            send_msg(c, b"OKAY")
        elif cmd.startswith("flash:"):
            r = flash(cmd[6:])
            record(cmd=cmd, result=r)
            send_msg(c, r.encode())
        elif cmd.startswith("oem "):
            args = cmd[4:].split()
            if not state["config"]:
                r = 'FAIL you need to run "fastboot getvar config" first'
            elif args[:1] == ["dust"] and args[1:] == [CHECK]:
                state["dust"], r = True, "OKAY"
            elif args in (["stage1"], ["stage2"]):
                state["stage"], r = int(args[0][-1]), "OKAY"
            elif args == ["prep"] and state["dust"]:
                state["prep"], r = True, "OKAY"
            else:
                r = "FAILnot supported"
            record(cmd=cmd, result=r)
            send_msg(c, r.encode())
        elif cmd == "reboot":
            record(cmd=cmd)
            send_msg(c, b"OKAY")
            return
        else:
            record(cmd=cmd, result="FAIL")
            send_msg(c, b"FAILunknown command")


srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(1)
print("ready", flush=True)
while True:
    conn, _ = srv.accept()
    try:
        if gate and not os.path.exists(gate):
            continue    # not in fastboot yet: drop the connection
        handle(conn)
    except (EOFError, ConnectionError):
        pass
    finally:
        conn.close()
