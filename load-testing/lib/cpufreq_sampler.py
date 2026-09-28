#!/usr/bin/env python3
"""The clock speed each service's CPUs ran at while a measured cell ran, and whether
mains power held, read from the host's sysfs and procfs.

    cpufreq_sampler.py --cell NAME --cpus python=0-1,4-5 [--cpus java=2-3 ...]
                       [--interval 0.5] [--avoid-cpus CPUSET] [--sysfs-root /sys]
                       [--proc-root /proc]

On SIGTERM, or when the process that started it exits, prints one line:

    cell_freq ts=<UTC> python_mhz=<n> python_busy_pct=<n> ... samples=<n> mains_offline_samples=<n> cell=<name>

<service>_mhz averages scaling_cur_freq over the service's CPUs weighted by each CPU's
busy time in each interval, so idle moments before and after the load do not dilute
it; "na" where cpufreq is not exposed or the CPUs never ran. Exits 3 when any sample
found the host off mains power, 0 otherwise.
"""

import argparse
import glob
import os
import signal
import sys
import time

from placement import expand_cpuset, utc_now


def cpu_times(proc_root):
    """{cpu: (busy, total)} cumulative jiffies; idle and iowait count as not busy."""
    times = {}
    with open(os.path.join(proc_root, "stat")) as f:
        for line in f:
            if line.startswith("cpu") and line[3:4].isdigit():
                name, *values = line.split()
                values = [int(v) for v in values[:8]]
                total = sum(values)
                times[int(name[3:])] = (total - values[3] - values[4], total)
    return times


def cpu_mhz(sysfs_root, cpu):
    try:
        with open(os.path.join(sysfs_root, f"devices/system/cpu/cpu{cpu}/cpufreq/scaling_cur_freq")) as f:
            return int(f.read()) / 1000
    except (OSError, ValueError):
        return None


def on_battery(sysfs_root):
    """The rule lib/host-provenance.sh's power_source_state() applies: the first mains
    supply reporting online decides, else a discharging battery means battery power."""
    supplies = sorted(glob.glob(os.path.join(sysfs_root, "class/power_supply/*")))

    def read(path):
        try:
            with open(path) as f:
                return f.read().strip()
        except OSError:
            return ""

    for supply in supplies:
        if read(os.path.join(supply, "type")) == "Mains" and read(os.path.join(supply, "online")) in ("0", "1"):
            return read(os.path.join(supply, "online")) == "0"
    return any(read(os.path.join(s, "type")) == "Battery" and read(os.path.join(s, "status")) == "Discharging"
               for s in supplies)


def parse_services(pairs):
    services = {}
    for pair in pairs:
        name, sep, cpuset = pair.partition("=")
        if not sep or not name or not expand_cpuset(cpuset):
            raise ValueError(f"--cpus expects SERVICE=CPUSET, got '{pair}'")
        services[name] = sorted(expand_cpuset(cpuset))
    return services


def summary(cell, services, acc, samples, offline):
    fields = [f"cell_freq ts={utc_now()}"]
    for name in services:
        a = acc[name]
        mhz = f"{a['weighted'] / a['weight']:.0f}" if a["weight"] else "na"
        busy = f"{100 * a['busy'] / a['total']:.1f}" if a["total"] else "na"
        fields.append(f"{name}_mhz={mhz} {name}_busy_pct={busy}")
    fields.append(f"samples={samples} mains_offline_samples={offline} cell={cell}")
    return " ".join(fields)


def run(args):
    stop = []
    signal.signal(signal.SIGTERM, lambda *_: stop.append(True))
    if args.avoid_cpus:
        allowed = os.sched_getaffinity(0) - expand_cpuset(args.avoid_cpus)
        if allowed:
            os.sched_setaffinity(0, allowed)
    services = parse_services(args.cpus)
    acc = {name: {"weighted": 0.0, "weight": 0, "busy": 0, "total": 0} for name in services}
    samples = offline = 0
    parent = os.getppid()
    try:
        prev = cpu_times(args.proc_root)
    except OSError:
        prev = {}
    while not stop and os.getppid() == parent:
        deadline = time.monotonic() + args.interval
        while not stop and time.monotonic() < deadline:
            time.sleep(0.05)
        if stop:
            break
        try:
            cur = cpu_times(args.proc_root)
        except OSError:
            cur = {}
        for name, cpus in services.items():
            for cpu in cpus:
                if cpu not in cur or cpu not in prev:
                    continue
                busy, total = cur[cpu][0] - prev[cpu][0], cur[cpu][1] - prev[cpu][1]
                acc[name]["busy"] += busy
                acc[name]["total"] += total
                mhz = cpu_mhz(args.sysfs_root, cpu)
                if mhz is not None and busy > 0:
                    acc[name]["weighted"] += busy * mhz
                    acc[name]["weight"] += busy
        prev = cur
        samples += 1
        offline += on_battery(args.sysfs_root)
    print(summary(args.cell, services, acc, samples, offline), flush=True)
    return 3 if offline else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--cell", required=True)
    parser.add_argument("--cpus", action="append", required=True, help="SERVICE=CPUSET, repeatable.")
    parser.add_argument("--interval", type=float, default=0.5)
    parser.add_argument("--avoid-cpus", default="", help="Cpuset the sampler must not run on.")
    parser.add_argument("--sysfs-root", default="/sys")
    parser.add_argument("--proc-root", default="/proc")
    return run(parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
