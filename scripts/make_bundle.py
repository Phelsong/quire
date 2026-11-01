#!/usr/bin/env python3
"""Build a shippable AppDir + tar.gz for Quire.

Produces:
  dist/quire/            AppDir tree:
    bin/quire            launcher script (sets env, execs quire.bin)
    bin/quire.bin        the linked Mojo binary
    bin/ffmpeg, bin/ffprobe
    lib/                 recursive pixi-owned shared-lib closure (+ libpython)
    python3.14/          Python home: lib/python3.14 = stdlib + site-packages
  dist/quire-linux-x86_64.tar.gz

Run from the repo root (or via `pixi run dist`).
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ENV_LIB = REPO / ".pixi/envs/default/lib"
PIXI_LIB = REPO / ".pixi/lib"
ENV_BIN = REPO / ".pixi/envs/default/bin"
MAIN = REPO / ".pixi/main"

DIST = REPO / "dist"
APPDIR = DIST / "quire"

# System libs we must NOT bundle (present on every linux-64 host).
SYSTEM_PREFIXES = ("/usr/lib", "/lib", "libc.so", "libm.so", "ld-linux",
                   "linux-vdso", "libpthread.so", "libdl.so", "librt.so")


def ldd_closure(entry: Path, index: dict[str, Path]) -> set:
    """Recursive pixi-owned .so closure of `entry` (resolved via env libs)."""
    env = dict(os.environ)
    env["LD_LIBRARY_PATH"] = f"{PIXI_LIB}:{ENV_LIB}"
    found, stack = [], [entry]
    while stack:
        cur = stack.pop()
        out = subprocess.run(["ldd", str(cur)], capture_output=True, text=True,
                             env=env).stdout
        for line in out.splitlines():
            if "=>" not in line:
                continue
            lib = line.split("=>")[1].split("(")[0].strip()
            if not lib or not lib.startswith("/"):
                continue
            p = Path(lib).resolve()
            # Record both names: the loader matches DT_NEEDED against the
            # SONAME file (often a versioned symlink like libavdevice.so.63),
            # while the walk needs the resolved real file for transitive
            # deps. Recording only the real name shipped `.so.63.1.102`
            # without the `.so.63` link the loader looks for.
            if p.name not in found:
                found.append(p.name)
            if Path(lib).name not in found:
                found.append(Path(lib).name)
            if (not p.as_posix().startswith(SYSTEM_PREFIXES) or
                    "pixi" in p.as_posix()):
                if p.name not in [s.name for s in stack]:
                    stack.append(p)
    # keep only pixi-owned libs
    return {n for n in found if n in index}


def build_lib_index() -> dict[str, Path]:
    """Map lib file name -> source path, recursively under ENV_LIB/PIXI_LIB.

    ENV_LIB entries win, so a name resolves to its env copy. Subdirectories
    matter: conda scatters deps in them (e.g. lib/pulseaudio/
    libpulsecommon-17.0.so, which libpulse finds via its $ORIGIN RPATH).
    """
    index: dict[str, Path] = {}
    for d in (ENV_LIB, PIXI_LIB):
        for p in d.rglob("*"):
            if p.is_symlink() or p.is_file():
                index.setdefault(p.name, p)
    return index


def find_lib(name: str, index: dict[str, Path]) -> Path | None:
    return index.get(name)


def copy_lib(name: str, dst_dir: Path, copied: set,
             index: dict[str, Path]) -> None:
    if name in copied:
        return
    src = find_lib(name, index)
    if src is None:
        print(f"WARN: lib not found in pixi env: {name}", file=sys.stderr)
        return
    if src.is_symlink():
        target = src.resolve()
        shutil.copy2(target, dst_dir / target.name)
        # keep a symlink copy for versioned SONAMEs (libz.so.1 style)
        (dst_dir / src.name).symlink_to(target.name)
        copied.add(src.name)
        copied.add(target.name)
        # recurse on symlink chain
        copy_lib(target.name, dst_dir, copied, index)
    else:
        shutil.copy2(src, dst_dir / name)
        copied.add(name)


def main() -> None:
    if not MAIN.exists():
        sys.exit("error: .pixi/main missing — run `pixi run build` first")
    if dist_marker := (APPDIR / ".bundle_built"):
        _ = dist_marker  # unused; keep APPDIR rebuilds clean each run
    shutil.rmtree(APPDIR, ignore_errors=True)
    (APPDIR / "bin").mkdir(parents=True)
    (APPDIR / "lib").mkdir(parents=True)

    # -- binary ---------------------------------------------------------------
    shutil.copy2(MAIN, APPDIR / "bin/quire.bin")

    # -- shared library closure ------------------------------------------------
    # Cover quire.bin AND the bundled ffmpeg/ffprobe, or their libav* deps
    # only resolve via the build machine's system libs (silently works on
    # the dev box, breaks in flatpak/any sandbox).
    index = build_lib_index()
    closure: set = set()
    for entry in (MAIN, ENV_BIN / "ffmpeg", ENV_BIN / "ffprobe"):
        if entry.exists():
            closure |= ldd_closure(entry, index)
    copied: set = set()
    for name in sorted(closure):
        copy_lib(name, APPDIR / "lib", copied, index)
    # Mojo's Python interop dlopens libpython; pull it explicitly.
    # It probes the unversioned "libpython3.14.so" name, so ship the
    # symlink trio (libpython3.so -> libpython3.14.so -> .so.1.0) too.
    copy_lib("libpython3.14.so.1.0", APPDIR / "lib", copied, index)
    for sym in ("libpython3.14.so", "libpython3.so"):
        src = ENV_LIB / sym
        if src.is_symlink():
            (APPDIR / "lib" / sym).symlink_to(src.resolve().name)

    # -- ffmpeg / ffprobe ------------------------------------------------------
    for tool in ("ffmpeg", "ffprobe"):
        src = ENV_BIN / tool
        if src.exists():
            shutil.copy2(src, APPDIR / "bin" / tool)
        else:
            print(f"WARN: {tool} not in env bin", file=sys.stderr)

    # -- python runtime ---------------------------------------------------------
    # Layout: <pyhome>/lib/python3.14 = the env's lib/. Python getpath
    # resolves stdlib as <PYTHONHOME>/lib/<platlibdir>/python3.14 and
    # site processing picks up <stdlib>/site-packages — so pointing
    # PYTHONHOME at py_dest works on any machine (see bin/quire launcher).
    py_dest = APPDIR / "python3.14"
    if py_dest.exists():
        shutil.rmtree(py_dest)
    shutil.copytree(ENV_LIB.parent / "lib", py_dest / "lib", symlinks=True,
                    ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))

    # -- data assets -------------------------------------------------------------
    # The binary loads its UI font from a relative `assets/` path (main.mojo);
    # ship the tree and make the launcher chdir to the bundle root so the
    # relative path resolves regardless of where the user starts it.
    assets_src = REPO / "assets"
    if assets_src.is_dir():
        shutil.copytree(assets_src, APPDIR / "assets",
                        ignore=shutil.ignore_patterns("__pycache__"))
    else:
        print("WARN: no assets/ dir found", file=sys.stderr)

    # -- launcher ----------------------------------------------------------------
    launcher = APPDIR / "bin/quire"
    launcher.write_text("""#!/usr/bin/env bash
# Quire bundle launcher — resolves its own location, wires env, execs binary.
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ROOT="$(dirname "$HERE")"
export LD_LIBRARY_PATH="$ROOT/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# python3.14/ is a python home (<pyhome>/lib/<platlibdir>/python3.14 = stdlib).
# Without PYTHONHOME, getpath falls back to the build machine's compiled-in
# prefix (e.g. the dev .pixi env), which breaks the bundle on any other
# machine — and inside flatpak sandboxes.
export PYTHONHOME="$ROOT/python3.14"
export PYTHONPATH="$ROOT/python3.14/lib/python3.14/site-packages${PYTHONPATH:+:$PYTHONPATH}"
export CONDA_PREFIX="$ROOT"
# Mojo's Python interop loads libpython via this exact path (no guessing).
export MOJO_PYTHON_LIBRARY="$ROOT/lib/libpython3.14.so.1.0"
# The binary resolves assets/ (UI font) relative to CWD — pin it to the root.
cd "$ROOT"
exec "$ROOT/bin/quire.bin" "$@"
""")
    launcher.chmod(0o755)
    (APPDIR / "bin/quire.bin").chmod(0o755)

    # -- sanity: bundled binaries resolve all libs against bundle lib/ ---------
    env = dict(os.environ)
    env["LD_LIBRARY_PATH"] = str(APPDIR / "lib")
    for exe in ("bin/quire.bin", "bin/ffmpeg", "bin/ffprobe"):
        exe_path = APPDIR / exe
        if not exe_path.exists():
            print(f"WARN: {exe} missing from bundle", file=sys.stderr)
            continue
        out = subprocess.run(["ldd", str(exe_path)],
                             capture_output=True, text=True, env=env)
        missing = [ln for ln in out.stdout.splitlines() if "not found" in ln]
        if missing:
            print(f"--- {exe}", file=sys.stderr)
            print("\n".join(missing), file=sys.stderr)
            sys.exit(f"error: unresolved libs in bundle ({exe})")

    # -- tarball -----------------------------------------------------------------
    tarball = DIST / "quire-linux-x86_64.tar.gz"
    if tarball.exists():
        tarball.unlink()
    subprocess.run(["tar", "-czf", str(tarball), "-C", str(DIST), "quire"],
                   check=True)

    size = subprocess.run(["du", "-sh", str(APPDIR), str(tarball)],
                          capture_output=True, text=True).stdout
    print(size)
    print(f"bundle ok: {APPDIR} + {tarball}")


if __name__ == "__main__":
    main()