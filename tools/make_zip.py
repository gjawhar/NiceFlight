"""Builds the release ZIP in the shape FrSky Suite's Lua installer requires.

    python3 tools/make_zip.py            # -> ~/Downloads/NiceFlight-v<version>.zip

Rules, read out of FrSky Suite 2.0.1's own installer code (2026-09-30):
- `ethos_lua_manifest.json` must sit at the ZIP ROOT, or it refuses with
  "No ethos_lua_manifest.json found at zip root."
- manifestVersion must be the number 1; name <= 128 chars; key matches
  ^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,127}$; version parses as a version number;
  folder matches ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$.
- files: non-empty list of relative paths inside the ZIP ("*" globs within a
  segment, "**" as a whole segment). Every non-glob entry must exist, every
  glob must match something, and main.lua (or main.luac) must be among them.
- Install target is scripts/<folder>/<path>, where a leading "<folder>/" is
  stripped from each path. So the app folder goes at the ZIP root, NOT under
  "scripts/". Only the listed files are written and nothing is deleted, so an
  upgrade never touches Files/*.csv.
"""
import json, os, re, sys, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
FOLDER, KEY, NAME = "NiceFlt", "niceflt", "Nice Flight!"
MANIFEST = "ethos_lua_manifest.json"

def version():
    src = open(os.path.join(ROOT, FOLDER, "core.lua"), encoding="utf-8").read()
    return re.search(r'core\.VERSION = "([^"]+)"', src).group(1)

def manifest(ver):
    return {
        "manifestVersion": 1,
        "name": NAME,
        "key": KEY,
        "version": ver,
        "folder": FOLDER,
        "files": [FOLDER + "/main.lua", FOLDER + "/core.lua", FOLDER + "/draw.lua", FOLDER + "/screen.lua",
                  FOLDER + "/config.lua", FOLDER + "/icons/*.png", FOLDER + "/Files/.gitkeep"],
        "introduction": "Celebrates and records good DLG flights: a recap with launch height, max altitude, "
                        "flight time, climbs, a simplified altitude graph and badges. Needs Mike Shellim's "
                        "DLG for Ethos template (or matching flight modes) and an Altitude sensor.",
        "releaseNotes": {"format": "markdown",
                         "content": "See https://github.com/gjawhar/NiceFlight/releases for what changed in " + ver + "."},
    }

def validate(m, names):
    """The same checks FrSky Suite makes. Returns a list of problems (empty = installable)."""
    bad = []
    if m.get("manifestVersion") != 1: bad.append("manifestVersion must be the number 1")
    if not (isinstance(m.get("name"), str) and 0 < len(m["name"].strip()) and len(m["name"]) <= 128): bad.append("name")
    if not re.match(r"^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,127}$", str(m.get("key", "")).strip()): bad.append("key")
    if not re.match(r"^\d+(\.\d+){0,3}", str(m.get("version", ""))): bad.append("version")
    if not re.match(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$", str(m.get("folder", ""))): bad.append("folder")
    if len(m.get("introduction", "")) > 1024: bad.append("introduction longer than 1024")
    files = m.get("files")
    if not (isinstance(files, list) and files): return bad + ["files must be a non-empty list"]
    entries = [n for n in names if not n.endswith("/") and n.split("/")[-1].lower() != MANIFEST]
    lower = {n.lower() for n in entries}
    matched = []
    for f in files:
        if f.startswith("/") or ".." in f.split("/") or "" in f.split("/"): bad.append("unsafe path " + f); continue
        if "*" not in f:
            if f.lower() not in lower: bad.append("listed file missing from the ZIP: " + f)
            else: matched.append(f)
            continue
        rx = "^" + "/".join(".*" if seg == "**" else re.escape(seg).replace(r"\*", "[^/]*") for seg in f.split("/")) + "$"
        hits = [n for n in entries if re.match(rx, n, re.I)]
        if not hits: bad.append("glob matches nothing: " + f)
        matched += hits
    if not any(n.split("/")[-1].lower() in ("main.lua", "main.luac") for n in matched): bad.append("main.lua not among the files")
    if MANIFEST not in names: bad.append(MANIFEST + " is not at the ZIP root")
    return bad

def build(out=None):
    ver = version()
    out = out or os.path.expanduser("~/Downloads/NiceFlight-v%s.zip" % ver)
    m = manifest(ver)
    src = os.path.join(ROOT, FOLDER)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(MANIFEST, json.dumps(m, indent=2) + "\n")
        for f in ["main.lua", "core.lua", "draw.lua", "screen.lua", "config.lua"]:
            z.write(os.path.join(src, f), FOLDER + "/" + f)
        for f in sorted(os.listdir(os.path.join(src, "icons"))):
            if f.endswith(".png"): z.write(os.path.join(src, "icons", f), FOLDER + "/icons/" + f)
        z.writestr(FOLDER + "/Files/.gitkeep", "")
    names = zipfile.ZipFile(out).namelist()
    problems = validate(json.loads(zipfile.ZipFile(out).read(MANIFEST)), names)
    return out, names, problems

if __name__ == "__main__":
    out, names, problems = build(sys.argv[1] if len(sys.argv) > 1 else None)
    print(out)
    for n in names: print("  ", n)
    print("FrSky Suite manifest check:", "OK, installable" if not problems else "PROBLEMS: " + "; ".join(problems))
    sys.exit(1 if problems else 0)
