"""
environment access via std.os.getenv, file rename via libc rename(2),
executable checks via std.os.fstat mode bits.
"""

from std.os import getenv, fstat
from std.ffi import external_call, c_int


def _is_executable(filepath: String) raises -> Bool:
    """Check if a file exists and is executable.

    Safe Mojo: std.os.fstat.stat + mode bits replace libc access(X_OK).
    Linux st_mode: low 9 bits are rwxrwxrwx; any execute bit set + regular
    file == executable by someone. access(X_OK) under our uid means "owner,
    group, or other x-bit" — the union of the three x-bits is the faithful
    check for a single-user desktop app.
    """
    try:
        var st = fstat.stat(filepath)
        # S_IFMT check: must be a regular file (or symlink-resolved regular).
        if st.st_mode & 0o170000 != 0o100000:
            return False
        return st.st_mode & 0o111 != 0
    except:
        return False


def _which(binary: String) raises -> String:
    """Locate a binary on $PATH by scanning each directory for an executable
    file. Returns the full path of the first match, or "" if not found."""
    var path_env = getenv("PATH")
    if path_env.byte_length() == 0:
        return ""
    var dirs = path_env.split(":")
    for i in range(len(dirs)):
        var dir = String(dirs[i])
        if dir.byte_length() == 0:
            continue
        var candidate = dir + "/" + binary
        if _is_executable(candidate):
            return candidate
    return ""


# ---------------------------------------------------------------------------
# Shell quoting
# ---------------------------------------------------------------------------


def _shell_quote(s: String) -> String:
    """Single-quote a string for safe shell interpolation.

    Wraps the value in single quotes and escapes any internal single quotes
    using the standard `'\''` sequence. Safe for URLs, file paths, and
    multi-line header blobs.
    """
    var out = String("'")
    for i in range(s.byte_length()):
        var ch = s[byte=i]
        if ch == "'":
            out += "'\\''"
        else:
            out += String(ch)
    out += "'"
    return out


# ---------------------------------------------------------------------------
# Native file operations (libc rename via external_call)
# ---------------------------------------------------------------------------


def _mojo_rename(src: String, dst: String) raises:
    """Rename a file via libc rename(2).

    std.os has no rename() wrapper on this toolchain, so we call libc
    directly through std.ffi.external_call. Raises on failure.
    """
    var mut_src = src
    var mut_dst = dst
    var rc = external_call["rename", c_int](
        mut_src.as_c_string_span().ptr(),
        mut_dst.as_c_string_span().ptr(),
    )
    if rc != 0:
        raise Error("rename failed: " + src + " -> " + dst)


def format_time(seconds: Float64) -> String:
    """Format time in seconds as H:MM:SS or MM:SS."""
    var secs = Int(seconds)
    if secs < 0:
        secs = 0
    var hours = secs // 3600
    var minutes = (secs % 3600) // 60
    var remaining = secs % 60
    if hours > 0:
        var min_str = String(minutes)
        if minutes < 10:
            min_str = "0" + String(minutes)
        var sec_str = String(remaining)
        if remaining < 10:
            sec_str = "0" + String(remaining)
        return String(hours) + ":" + min_str + ":" + sec_str
    var sec_str = String(remaining)
    if remaining < 10:
        sec_str = "0" + String(remaining)
    return String(minutes) + ":" + sec_str


def truncate_string(var text: String, ref length: Int) -> String:
    """Return the first `length` characters of a string, safe for UTF-8.

    Pure-Mojo implementation via codepoint_slices(): never splits inside
    multi-byte UTF-8 continuation bytes (which would corrupt the string or
    abort at runtime). Called from the UI draw path many times per frame,
    so it must stay free of Python interop calls.
    """
    if length <= 0:
        return String()
    if text.byte_length() == 0:
        return String()
    # Fast path: requested length covers every codepoint.
    if length >= text.count_codepoints():
        return text
    var result = String("")
    var count = 0
    for cp_slice in text.codepoint_slices():
        if count >= length:
            break
        result += String(cp_slice)
        count += 1
    return result


def truncate_to_width(
    text: String,
    max_width_px: Float64,
    font_scale: Float64,
    avg_char_px: Float64,
) -> String:
    """Truncate `text` (with an ellipsis) to roughly `max_width_px`.

    Character widths are estimated at `avg_char_px` design px per codepoint
    scaled by `font_scale`; callers pass a per-font-size constant measured
    once (see the caller comment in player_screen._draw_info_popover).
    """
    var max_chars = Int(max_width_px / (avg_char_px * font_scale))
    if max_chars < 1:
        max_chars = 1
    var measured = text.count_codepoints()
    if measured <= max_chars:
        return text
    if max_chars <= 3:
        return truncate_string(text, max_chars)
    return truncate_string(text, max_chars - 3) + "..."


def split_wrap_chars(text: String, chars_per_line: Int) -> List[String]:
    """Hard-wrap `text` into lines of `chars_per_line` codepoints.

    Prefers breaking at the last space in each window so words don't split
    mid-word; a line with no space (longer than the window) breaks hard.
    """
    var lines = List[String]()
    if text.byte_length() == 0:
        lines.append(String(""))
        return lines^

    var codepoints = List[String]()
    for cp_slice in text.codepoint_slices():
        codepoints.append(String(cp_slice))

    var total = len(codepoints)
    var pos = 0
    while pos < total:
        var end = pos + chars_per_line
        if end >= total:
            var tail = String("")
            for i in range(pos, total):
                tail += codepoints[i]
            lines.append(tail^)
            break
        # Prefer a space break inside the window (search backwards).
        var break_at = -1
        var i = end
        while i > pos:
            if codepoints[i] == " ":
                break_at = i
                break
            i -= 1
        if break_at == -1 or break_at <= pos:
            break_at = end
        var line = String("")
        for j in range(pos, break_at):
            line += codepoints[j]
        lines.append(line^)
        pos = break_at
        # Skip the space itself so lines don't start with a gap.
        if codepoints[pos] == " ":
            pos += 1
    return lines^
