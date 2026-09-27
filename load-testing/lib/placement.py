#!/usr/bin/env python3
"""Records which python-service worker process holds each inbound connection while a
measured cell runs, the information `ss -tnp` reports, read from the host's procfs so
nothing executes inside the measured container.

    placement.py --container-pid PID --cell NAME [--port 8000] [--interval 0.2]
                 [--avoid-cpus CPUSET] [--proc-root /proc]

Prints a `placement` line at the first sample and whenever the placement changes, and
a `placement_end` line on SIGTERM:

    placement cell=<name> ts=<UTC> established=<n> workers=<pid>:<n>,<pid>:<n>,...
    placement_end cell=<name> ts=<UTC>

Worker PIDs are those inside the container's PID namespace. The workers are the
processes holding the listening socket whose parent holds it too (the uvicorn
supervisor's children), or the single holder when uvicorn runs one process. If the
tree cannot be read, one `placement_unavailable` line says why and the sampler exits 0:
placement is supporting evidence, never a condition of the run.
"""

import argparse
import os
import signal
import sys
import time
from datetime import datetime, timezone

LISTEN, ESTABLISHED = "0A", "01"


def utc_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def expand_cpuset(cpuset):
    cpus = set()
    for part in str(cpuset or "").split(","):
        part = part.strip()
        if part and part.replace("-", "").isdigit():
            lo, _, hi = part.partition("-")
            cpus.update(range(int(lo), int(hi or lo) + 1))
    return cpus


def tcp_sockets(proc_root, pid, port):
    """{inode: state} for the IPv4 and IPv6 sockets bound locally to port in pid's
    network namespace."""
    sockets = {}
    for name in ("tcp", "tcp6"):
        try:
            with open(os.path.join(proc_root, str(pid), "net", name)) as f:
                next(f, None)
                for line in f:
                    fields = line.split()
                    if len(fields) > 9 and int(fields[1].rsplit(":", 1)[1], 16) == port:
                        sockets[fields[9]] = fields[3]
        except FileNotFoundError:
            continue
    return sockets


def parent_map(proc_root):
    """{pid: ppid} for every process visible in proc_root."""
    parents = {}
    for entry in os.listdir(proc_root):
        if not entry.isdigit():
            continue
        try:
            with open(os.path.join(proc_root, entry, "stat")) as f:
                stat = f.read()
        except OSError:
            continue
        # comm may contain spaces or parentheses; the fields after its closing ')' do not.
        parents[int(entry)] = int(stat.rsplit(")", 1)[1].split()[1])
    return parents


def descendants(parents, root):
    found, frontier = {root}, [root]
    while frontier:
        pid = frontier.pop()
        for child, parent in parents.items():
            if parent == pid and child not in found:
                found.add(child)
                frontier.append(child)
    return found


def socket_inodes(proc_root, pid):
    inodes = set()
    fd_dir = os.path.join(proc_root, str(pid), "fd")
    for fd in os.listdir(fd_dir):
        try:
            target = os.readlink(os.path.join(fd_dir, fd))
        except OSError:
            continue
        if target.startswith("socket:["):
            inodes.add(target[8:-1])
    return inodes


def namespace_pid(proc_root, pid):
    """The PID as the container sees it: the last NSpid entry, else the host PID."""
    try:
        with open(os.path.join(proc_root, str(pid), "status")) as f:
            for line in f:
                if line.startswith("NSpid:"):
                    return int(line.split()[-1])
    except OSError:
        pass
    return pid


def find_workers(proc_root, container_pid, port):
    """Host PIDs of the worker processes, as described in the module docstring."""
    parents = parent_map(proc_root)
    listening = {inode for inode, state in tcp_sockets(proc_root, container_pid, port).items() if state == LISTEN}
    holders = {pid for pid in descendants(parents, container_pid) if socket_inodes(proc_root, pid) & listening}
    workers = {pid for pid in holders if parents.get(pid) in holders}
    return sorted(workers or holders)


def snapshot(proc_root, container_pid, port, workers):
    """(established connections on port, {namespace pid: connections held}) now."""
    established = {inode for inode, state in tcp_sockets(proc_root, container_pid, port).items()
                   if state == ESTABLISHED}
    held = {namespace_pid(proc_root, pid): len(socket_inodes(proc_root, pid) & established) for pid in workers}
    return len(established), held


def format_workers(held):
    return ",".join(f"{pid}:{n}" for pid, n in sorted(held.items()))


def run(args):
    stop = []
    signal.signal(signal.SIGTERM, lambda *_: stop.append(True))
    if args.avoid_cpus:
        allowed = os.sched_getaffinity(0) - expand_cpuset(args.avoid_cpus)
        if allowed:
            os.sched_setaffinity(0, allowed)
    try:
        workers = find_workers(args.proc_root, args.container_pid, args.port)
        if not workers:
            raise OSError(f"no process in the container holds a socket listening on port {args.port}")
    except OSError as e:
        print(f"placement_unavailable cell={args.cell} ts={utc_now()} reason={str(e).replace(' ', '_')}", flush=True)
        return 0
    last = None
    parent = os.getppid()
    # Also stops when the harness that started it is gone, so an interrupted run leaves
    # no sampler behind.
    while not stop and os.getppid() == parent:
        try:
            state = snapshot(args.proc_root, args.container_pid, args.port, workers)
        except OSError:
            break
        if state != last:
            print(f"placement cell={args.cell} ts={utc_now()} established={state[0]} "
                  f"workers={format_workers(state[1])}", flush=True)
            last = state
        time.sleep(args.interval)
    print(f"placement_end cell={args.cell} ts={utc_now()}", flush=True)
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--container-pid", type=int, required=True)
    parser.add_argument("--cell", required=True)
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--interval", type=float, default=0.2)
    parser.add_argument("--avoid-cpus", default="", help="Cpuset the sampler must not run on.")
    parser.add_argument("--proc-root", default="/proc")
    return run(parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
