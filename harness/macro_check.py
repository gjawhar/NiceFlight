"""Runs the generated simulator macros, unmodified, against the real widget
core, in order, with badge state carried from one to the next -- i.e. what a
full session in the simulator should produce.  python3 harness/macro_check.py
"""
import json, lupa, os, shutil, sys, tempfile
here = os.path.dirname(os.path.abspath(__file__))
root = os.path.join(here, "..")
meta = json.load(open(os.path.join(root, "sim", "flights.json")))
import re
def play(speed):
    run = tempfile.mkdtemp(prefix="nf_macro_"); os.mkdir(os.path.join(run, "Files"))
    shutil.copy(os.path.join(root, "NiceFlt", "core.lua"), run)
    shutil.copy(os.path.join(here, "macro_check.lua"), run)
    for m in meta:
        text = open(os.path.join(root, "sim", m["name"], "flight.lua"), encoding="utf-8").read()
        text, n = re.subn(r"^local SPEED = \d+", "local SPEED = %d" % speed, text, count=1, flags=re.M)
        assert n == 1, "SPEED line not found"
        open(os.path.join(run, m["name"] + ".lua"), "w", encoding="utf-8").write(text)
    open(os.path.join(run, "macro_list.txt"), "w").write("\n".join(m["name"] for m in meta) + "\n")
    os.chdir(run)
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute("TIMESCALE = %d" % speed)
    lua.execute(open("macro_check.lua", encoding="utf-8").read())
    return [l.rstrip("\n").split("\t") for l in open("macro_out.txt")]

EXPECT = { "NiceSim1_NearMiss": ("0", ""), "NiceSim2_Duration": ("1", "dur"), "NiceSim3_NoBadge": ("1", ""),
           "NiceSim4_SavePeak": ("1", "peak+save+rech"), "NiceSim5_Epic": ("1", "dur+yoyo+reb+rech+rect") }
bad = 0
for speed in (1, 8):
    print("\n== macros at SPEED %d, widget time scale %d" % (speed, speed))
    print("%-20s %6s %5s %6s %3s %4s  %-28s %s" % ("macro", "launch", "max", "dur", "clb", "nice", "badge families", "verdict"))
    for p in play(speed):
        if len(p) < 7: print("\t".join(p)); bad += 1; continue
        name, launch, mx, dur, clb, nice, fams = p[:7]
        want = EXPECT.get(name)
        ok = want and nice == want[0] and (want[1] is None or fams == want[1])
        bad += 0 if ok else 1
        print("%-20s %6s %5s %6s %3s %4s  %-28s %s" % (name, launch, mx, "%d:%02d" % (int(dur) // 60, int(dur) % 60), clb, nice, fams or "-", "as designed" if ok else "UNEXPECTED"))
        if os.environ.get("VERBOSE"): print("      graph:", p[7])
sys.exit(1 if bad else 0)
