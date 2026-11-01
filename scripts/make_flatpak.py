#!/usr/bin/env python3
"""Package the dist/quire AppDir into a flatpak bundle.

Requires scripts/make_bundle.py to have run first (pixi run dist), and
flatpak(1) on PATH with a Freedesktop runtime installed. Produces
dist/quire-linux-x86_64.flatpak (single-file bundle) plus dist/flatpak-repo
(a local flatpak repository for `flatpak install --user`).

The AppDir is self-contained (own libs, Python runtime, ffmpeg), so the
freedesktop runtime is only a sandbox shell — no dependencies are taken
from it. Pipeline (no flatpak-builder needed):

  flatpak build-init    dev.quire.Quire  <- build dir with chosen runtime
  cp dist/quire/.       build dir root (/app)
  + share/applications, share/metainfo, share/icons
  flatpak build-finish  sandbox permissions
  flatpak build-export  -> dist/flatpak-repo
  flatpak build-bundle  -> dist/quire-linux-x86_64.flatpak

Install/run:
  flatpak install --user ./dist/quire-linux-x86_64.flatpak
  flatpak run dev.quire.Quire
"""
import os
import pathlib
import shutil
import struct
import subprocess
import sys
import zlib

REPO = pathlib.Path(__file__).resolve().parent.parent
DIST = REPO / "dist"
APPDIR = DIST / "quire"
BUILD = DIST / "flatpak-build"
REPO_DIR = DIST / "flatpak-repo"
OUT = DIST / "quire-linux-x86_64.flatpak"

CID = "dev.quire.Quire"
CMD = "quire"  # name exported from /app/bin (flatpak puts /app/bin on PATH)

# The SDK/Platform only provide the sandbox; the bundle ships everything.
RUNTIME = os.environ.get("QUIRE_FLATPAK_RUNTIME", "org.freedesktop.Platform")
SDK = os.environ.get("QUIRE_FLATPAK_SDK", "org.freedesktop.Sdk")
BRANCH = os.environ.get("QUIRE_FLATPAK_BRANCH", "25.08")
ARCH = os.environ.get("QUIRE_FLATPAK_ARCH", "x86_64")

# Wayland-only window; audio via PulseAudio (libpulse-simple); network for
# the Plex server; config/sidecars live in ~/.config/quire on the host.
PERMS = [
    "--command", CMD,
    "--share=network",
    "--socket=wayland",
    "--socket=fallback-x11",
    "--socket=pulseaudio",
    "--device=dri",
    # Keep config on the host's standard path so it is shared with
    # non-flatpak installs of the app.
    "--filesystem=xdg-config/quire:create",
]

ICON_SIZES = (16, 32, 48, 64, 128, 256, 512)
# Preferred source first: the project logo, then any other repo PNG.
ICON_SOURCES = (
    REPO / "assets" / "quire-logo-background.png",
    *sorted((REPO / "resources").glob("*.png")),
)


def fail(msg: str) -> None:
    print(f"flatpak: {msg}", file=sys.stderr)
    sys.exit(1)


def flatpak(*args, **kw) -> None:
    result = subprocess.run(["flatpak", *args], cwd=str(DIST), **kw)
    if result.returncode != 0:
        fail(f"flatpak {' '.join(args[:2])} failed")


def png_size(path: pathlib.Path) -> tuple[int, int]:
    """Read w/h straight out of the IHDR chunk."""
    header = path.read_bytes()[:33]
    if header[:8] != b"\x89PNG\r\n\x1a\n":
        fail(f"{path} is not a PNG")
    w, h = struct.unpack(">II", header[16:24])
    return w, h


def placeholder_icon(size: int) -> bytes:
    """Solid dark square PNG — same trick as make_appimage.py."""
    raw = b"".join(b"\x00" + b"\x2a\x34\x44\xff" * size for _ in range(size))

    def chunk(tag: bytes, data: bytes) -> bytes:
        c = tag + data
        return (
            struct.pack(">I", len(data))
            + c
            + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


def downscale_icon(src: pathlib.Path) -> pathlib.Path:
    """Return a square 512x512 RGBA copy of `src` (fit + transparent pad).

    flatpak build-export rejects icons larger than 512x512.
    """
    ffmpeg = shutil.which("ffmpeg") or (REPO / ".pixi/envs/default/bin/ffmpeg")
    if not ffmpeg:
        fail(f"{src.name} exceeds 512x512 and ffprobe/ffmpeg not available "
             "to downscale")
    out = pathlib.Path("/tmp/opencode") / f"{src.stem}-512.png"
    subprocess.run(
        [str(ffmpeg), "-y", "-loglevel", "error", "-i", str(src), "-frames:v",
         "1", "-vf",
         "scale=512:512:force_original_aspect_ratio=decrease,"
         "pad=512:512:(ow-iw)/2:(oh-ih)/2:color=black@0.0,format=rgba",
         str(out)],
        check=True,
    )
    return out


def install_icon(app: pathlib.Path) -> None:
    """Place the icon under hicolor at its (nearest standard) size."""
    src = next((p for p in ICON_SOURCES if p.is_file()), None)
    if src is not None:
        w, h = png_size(src)
        if max(w, h) > 512:
            src = downscale_icon(src)
            w, h = png_size(src)
    else:
        src, w, h = None, 128, 128
    size = min(ICON_SIZES, key=lambda s: abs(s - max(w, h)))
    icon_dir = app / "share" / "icons" / "hicolor" / f"{size}x{size}" / "apps"
    icon_dir.mkdir(parents=True, exist_ok=True)
    dst = icon_dir / f"{CID}.png"
    if src is not None:
        shutil.copyfile(src, dst)
    else:
        dst.write_bytes(placeholder_icon(size))


def main() -> None:
    if not APPDIR.is_dir():
        fail(f"{APPDIR} missing — run `pixi run dist` first")
    if shutil.which("flatpak") is None:
        fail("flatpak not on PATH")

    shutil.rmtree(BUILD, ignore_errors=True)
    shutil.rmtree(REPO_DIR, ignore_errors=True)

    # build-init: BUILD_DIR APPNAME SDK RUNTIME [BRANCH].
    # BUILD_DIR/files is what build-export publishes as /app.
    flatpak("build-init", BUILD.name, CID, SDK, RUNTIME, BRANCH)

    # dist/quire becomes /app: bin/, lib/, python3.14/, assets/, ...
    # symlinks=True: copy SONAME symlinks as-is — with default (follow)
    # semantics a symlink could be visited before its target file and be
    # silently dropped as "dangling".
    shutil.copytree(APPDIR, BUILD / "files", symlinks=True,
                    dirs_exist_ok=True)

    install_icon(BUILD / "files")

    desktop_dir = BUILD / "files" / "share" / "applications"
    desktop_dir.mkdir(parents=True, exist_ok=True)
    (desktop_dir / f"{CID}.desktop").write_text(f"""\
[Desktop Entry]
Type=Application
Name=Quire
Comment=Plex audiobook client
Exec={CMD}
Icon={CID}
Categories=Audio;AudioVideo;
""")

    metainfo_dir = BUILD / "files" / "share" / "metainfo"
    metainfo_dir.mkdir(parents=True, exist_ok=True)
    (metainfo_dir / f"{CID}.metainfo.xml").write_text(f"""\
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>{CID}</id>
  <name>Quire</name>
  <summary>Plex audiobook client</summary>
  <metadata_license>MIT</metadata_license>
  <project_license>MIT</project_license>
  <launchable type="desktop-id">{CID}.desktop</launchable>
  <releases>
    <release version="0.1.0" date="2026-11-01"/>
  </releases>
  <description>
    <p>Quire is a Linux desktop client for browsing and listening to
    audiobooks from a Plex Media Server, with playback progress synced
    back to the server.</p>
  </description>
</component>
""")

    flatpak("build-finish", *PERMS, BUILD.name)
    flatpak("build-export", REPO_DIR.name, BUILD.name)
    flatpak("build-bundle",
            "--arch", ARCH,
            REPO_DIR.name, OUT.name, CID)
    print(f"wrote {OUT}")
    print(f"install: flatpak install --user ./{OUT.relative_to(REPO)}")
    print(  # repo alternative
        f"or      flatpak --user remote-add "
        f"--if-not-exists quire-flatpak-repo "
        f"{REPO_DIR.relative_to(REPO)} "
        f"&& flatpak --user install quire-flatpak-repo {CID}")


if __name__ == "__main__":
    main()