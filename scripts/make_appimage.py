#!/usr/bin/env python3
"""Package the dist/quire AppDir into a standalone AppImage.

Requires scripts/make_bundle.py to have run first (pixi run dist), and
appimagetool(1) on PATH. Produces dist/quire-linux-x86_64.AppImage.

AppDir requirements applied here:
  - quire.AppData/ share metadata (Name/Exec/Icon) — minimal but valid.
  - .DirIcon + a PNG icon so appimagetool accepts the tree.
"""
import os
import pathlib
import shutil
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
DIST = REPO / "dist"
APPDIR = DIST / "quire"
OUT = DIST / "quire-linux-x86_64.AppImage"

# AppStream conventions: metainfo filename must match the component id,
# and the desktop-file id must equal the component id.
CID = "dev.quire.Quire"

DESKTOP = f"""[Desktop Entry]
Type=Application
Name=Quire
Comment=Plex audiobook client
Exec=quire
Icon=quire
Categories=Audio;AudioVideo;
"""

UPSTREAM_PNG = REPO / "resources" / "icon.png"


def fail(msg: str) -> None:
    print(f"appimage: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    if not APPDIR.is_dir():
        fail(f"{APPDIR} missing — run `pixi run dist` first")
    if shutil.which("appimagetool") is None:
        fail("appimagetool not on PATH")

    # Desktop entry + AppStream metadata. dist/quire IS the AppDir root —
    # appimagetool expects <desktop-file-id>.desktop at its top level, and
    # the metainfo filename must match the component id.
    desktop_name = f"{CID}.desktop"
    (APPDIR / "usr" / "share" / "applications").mkdir(parents=True, exist_ok=True)
    (APPDIR / desktop_name).write_text(DESKTOP)
    (APPDIR / "usr" / "share" / "metainfo").mkdir(parents=True, exist_ok=True)
    (APPDIR / "usr" / "share" / "metainfo" / f"{CID}.metainfo.xml").write_text(
        f"""<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>{CID}</id>
  <name>Quire</name>
  <summary>Plex audiobook client</summary>
  <metadata_license>MIT</metadata_license>
  <project_license>MIT</project_license>
  <launchable type="desktop-id">{desktop_name}</launchable>
  <description>
    <p>Quire is a Linux desktop client for browsing and listening to
    audiobooks from a Plex Media Server, with playback progress synced
    back to the server.</p>
  </description>
</component>
"""
    )

    # Icon: reuse any repo PNG; placeholder if none exists yet.
    icon_dst = APPDIR / "quire.png"
    if not icon_dst.exists():
        candidates = list((REPO / "resources").glob("*.png"))
        if candidates:
            shutil.copyfile(candidates[0], icon_dst)
        else:
            # 16x16 dark placeholder so appimagetool has something valid.
            import struct
            import zlib

            w = h = 16
            raw = b"".join(
                b"\x00" + b"\x2a\x34\x44\xff" * w for _ in range(h)
            )

            def chunk(tag: bytes, data: bytes) -> bytes:
                c = tag + data
                return (
                    struct.pack(">I", len(data))
                    + c
                    + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
                )

            ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
            png = (
                b"\x89PNG\r\n\x1a\n"
                + chunk(b"IHDR", ihdr)
                + chunk(b"IDAT", zlib.compress(raw))
                + chunk(b"IEND", b"")
            )
            icon_dst.write_bytes(png)
    shutil.copyfile(icon_dst, APPDIR / ".DirIcon")

    # The launcher's relative-path logic needs Exec to resolve via PATH;
    # AppImage's runtime puts the squashfs root in PATH, so `Exec=quire`
    # inside the desktop file is enough — but the desktop file's Exec is
    # also used by the AppImage runtime when run with --appimage-extract.
    subprocess.run(["chmod", "+x", str(APPDIR / "bin" / "quire")], check=True)

    # AppRun is the AppImage entry point the runtime execs after mounting.
    # appimagetool does not auto-generate one — without it the image has
    # nothing to exec ('execv error'). It just delegates to bin/quire,
    # which already exports LD_LIBRARY_PATH/PYTHONPATH/CONDA_PREFIX/
    # MOJO_PYTHON_LIBRARY relative to its own location.
    apprun = APPDIR / "AppRun"
    apprun.write_text(
        "#!/bin/bash\n"
        'HERE="$(cd "$(dirname "$0")" && pwd)"\n'
        'exec "$HERE/bin/quire" "$@"\n'
    )
    apprun.chmod(0o755)

    result = subprocess.run(
        ["appimagetool", str(APPDIR), str(OUT)],
        cwd=str(DIST),
    )
    if result.returncode != 0:
        fail("appimagetool failed")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()