"""Render the widget's real paint output to SVG + an index page.
    python3 harness/render.py      # writes harness/out/index.html
"""
import lupa, os, shutil, glob, tempfile
here = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(here, "..", "NiceFlt")
out = os.path.join(here, "out"); os.makedirs(out, exist_ok=True)
run = tempfile.mkdtemp(prefix="nf_render_"); os.mkdir(os.path.join(run, "Files"))
for f in ["main.lua", "core.lua", "draw.lua", "screen.lua", "config.lua"]:
    shutil.copy(os.path.join(src, f), run)
shutil.copy(os.path.join(here, "render.lua"), run)
os.chdir(run)
lupa.LuaRuntime(unpack_returned_tuples=True).execute(open("render.lua", encoding="utf-8").read())
names = []
for p in sorted(glob.glob("out_*.svg")):
    name = os.path.basename(p)[4:]
    shutil.copy(p, os.path.join(out, name)); names.append(name)
with open(os.path.join(out, "index.html"), "w") as f:
    f.write("<html><body style='background:#ddd;font-family:sans-serif;margin:16px'>")
    for n in names:
        f.write(f"<h3>{n}</h3><img src='{n}' style='border:1px solid #888;background:#fff'><br>")
    f.write("</body></html>")
print("wrote", len(names), "screens to", out)
