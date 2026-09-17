"""Syntax-check every NiceFlt/*.lua file, then execute the mock-Ethos harness
(test.lua) against fresh copies in a scratch dir, so the repo's own Files/
(and the simulator's) are never touched.

    pip3 install lupa     # once; no system Lua needed
    python3 harness/run.py
"""
import lupa, os, shutil, sys, tempfile

here = os.path.dirname(os.path.abspath(__file__))
src  = os.path.join(here, "..", "NiceFlt")
files = ["main.lua", "core.lua", "draw.lua", "screen.lua", "config.lua"]

lua = lupa.LuaRuntime(unpack_returned_tuples=True)
check = lua.eval("function(s,n) local fn,e=load(s,n) if fn then return true,nil else return false,e end end")
bad = False
for f in files:
    ok, err = check(open(os.path.join(src, f), encoding="utf-8").read(), f)
    print(("syntax ok   " if ok else "SYNTAX ERR  ") + f, err or "")
    bad = bad or not ok
if bad:
    sys.exit(1)

run = tempfile.mkdtemp(prefix="nf_run_")
os.mkdir(os.path.join(run, "Files"))
for f in files:
    shutil.copy(os.path.join(src, f), run)
shutil.copy(os.path.join(here, "test.lua"), run)
os.chdir(run)
failures = lua.execute(open("test.lua", encoding="utf-8").read())
sys.exit(1 if failures else 0)
