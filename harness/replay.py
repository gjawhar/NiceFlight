"""Replay real Ethos logs through the real widget core and list every flight
it detects: python3 harness/replay.py /path/to/logs/*.csv
Columns: log, start second, launch ft, max ft, duration s, above s, climbs,
best climb ft, nice, badge families (judged against a clean slate)."""
import csv, glob, lupa, os, shutil, sys, tempfile
from datetime import datetime
here = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(here, "..", "NiceFlt")

def col(header, *needles):
    for i, h in enumerate(header):
        if all(n in h for n in needles): return i
    return None

def parse(path):
    with open(path, newline="", encoding="utf-8", errors="replace") as f:
        rd = csv.reader(f); header = next(rd)
        ia, il, iz, ib = col(header, "Altitude"), col(header, "MOM_LAUNCH"), col(header, "ZOOM_MODE"), col(header, "LANDING_MODE")
        ir = col(header, "RxBatt")
        metric = ia is not None and "(m)" in header[ia]
        t0 = None
        for row in rd:
            if len(row) < 3: continue
            try: ts = datetime.strptime(row[0] + " " + row[1], "%Y-%m-%d %H:%M:%S.%f")
            except ValueError: continue
            t0 = t0 or ts
            def v(i):
                try: return float(row[i]) if i is not None and row[i] != "" else None
                except (ValueError, IndexError): return None
            alt = v(ia)
            if alt is not None and metric: alt *= 3.28084
            fm = 2 if (v(il) or 0) > 0 else 3 if (v(iz) or 0) > 0 else 4 if (v(ib) or 0) > 0 else 0
            yield (ts - t0).total_seconds(), alt, fm, v(ir)

def main(paths):
    run = tempfile.mkdtemp(prefix="nf_replay_"); os.mkdir(os.path.join(run, "Files"))
    shutil.copy(os.path.join(src, "core.lua"), run); shutil.copy(os.path.join(here, "replay.lua"), run)
    with open(os.path.join(run, "replay_in.txt"), "w") as f:
        for p in sorted(paths):
            if not all(k is not None for k in [1]): continue
            f.write("LOG %s\n" % os.path.basename(p))
            for t, alt, fm, rx in parse(p):
                f.write("%.2f %s %d %s\n" % (t, "-" if alt is None else "%.1f" % alt, fm, "%.2f" % rx if rx else "0"))
    os.chdir(run)
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute("KEEP = %s" % ("true" if os.environ.get("KEEP") else "false"))
    lua.execute(open("replay.lua", encoding="utf-8").read())
    return [l.rstrip("\n").split("\t") for l in open("replay_out.txt")]

if __name__ == "__main__":
    rows = main(sys.argv[1:])
    print("%-34s %6s %6s %5s %6s %6s %3s %5s %4s  %s" % ("log", "start", "launch", "max", "dur", "above", "clb", "best", "nice", "badges"))
    for r in rows:
        print("%-34s %6s %6s %5s %6s %6s %3s %5s %4s  %s" % tuple(r))
    print(len(rows), "flights")
