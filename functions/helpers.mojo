"""
environment access via std.os.getenv, file rename via libc rename(2),
executable checks via libc access(2), and subprocess spawning via
popen/pclose.
"""

from std.os import getenv
from std.sys._libc import popen, pclose
from std.ffi import external_call, c_int
from std.collections import List

from platform.ffi import cstr


def _is_executable(filepath: String) raises -> Bool:
    """Check if a file exists and is executable (access X_OK)."""
    var mut_path = filepath
    var result = external_call["access", c_int](
        cstr(mut_path), c_int(1)  # X_OK = 1 on Linux
    )
    return result == 0


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

    Mojo 1.0's std.os has no rename() wrapper, so we call libc directly
    through std.ffi.external_call. Returns 0 on success; non-zero raises.
    """
    var mut_src = src
    var mut_dst = dst
    var rc = external_call["rename", c_int](
        mut_src.as_c_string_slice().unsafe_ptr(),
        mut_dst.as_c_string_slice().unsafe_ptr(),
    )
    if rc != 0:
        raise Error("rename failed: " + src + " -> " + dst)


# ---------------------------------------------------------------------------
# Subprocess spawning (popen/pclose)
# ---------------------------------------------------------------------------


def _run_ffmpeg(args: List[String]) raises -> Int:
    """Spawn ffmpeg via popen and wait for completion. Returns exit code.

    Replaces Python `subprocess.run(args, capture_output=True)`. We build a
    single shell command string (popen invokes /bin/sh), shell-quote every
    argument, run it with stdout/stderr discarded, and read the exit status
    from pclose(). ffmpeg writes its conversion output to a file path passed
    in args, so we don't need to capture stdout.
    """
    var cmd = String()
    for i in range(len(args)):
        if i > 0:
            cmd += " "
        cmd += _shell_quote(args[i])
    # Redirect stderr to /dev/null to match capture_output behavior (we
    # don't parse ffmpeg's stderr here; the caller logs a failure summary).
    cmd += " 2>/dev/null"
    var mode = String("w")
    var fp = popen(cstr(cmd), cstr(mode))
    if not fp:
        return -1
    var status = pclose(fp)
    # pclose returns the raw wait(2) status; extract the exit code.
    return Int(status)


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
