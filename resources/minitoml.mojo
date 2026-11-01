"""Quire — minimal hand-rolled TOML for config + offline sidecar files.

Every value lands in the TomlSection dict matching its type, so readers
fetch typed maps directly (`section.strings.get(key, "")`,
`section.ints.get(key, 0)`) — nothing to downcast, missing keys resolve
to a caller default. Anything outside the subset raises; load paths
catch and fall back to defaults, so a corrupt cache file can never take
the app down.

"""

from std.collections import Dict, List


# ---------------------------------------------------------------------------
# Parsed document
# ---------------------------------------------------------------------------


@fieldwise_init
struct TomlSection(Copyable, Defaultable, Movable):
    """One table's typed values (the root table is keyed "")."""

    var strings: Dict[String, String]
    var ints: Dict[String, Int]
    var floats: Dict[String, Float64]
    var bools: Dict[String, Bool]
    var str_arrays: Dict[String, List[String]]

    def __init__(out self):
        self.strings = Dict[String, String]()
        self.ints = Dict[String, Int]()
        self.floats = Dict[String, Float64]()
        self.bools = Dict[String, Bool]()
        self.str_arrays = Dict[String, List[String]]()


# ---------------------------------------------------------------------------
# Decode helpers
# ---------------------------------------------------------------------------


def _cp_at(src: String, idx: Int) -> Int:
    """Codepoint at codepoint index `idx` (-1 past the end).

    Byte indexing traps on non-ASCII on this toolchain, so — like
    resources.xmlparse — cursors walk codepoint indices.
    """
    var i = 0
    for cp in src.codepoints():
        if i == idx:
            return Int(cp)
        i += 1
    return -1


def _is_space(c: Int) -> Bool:
    """Line-internal whitespace: space, tab, CR (from CRLF files)."""
    return c == 32 or c == 9 or c == 13


def _is_key_char(c: Int) -> Bool:
    """Bare-key and section-name characters: alnum, '_', '-'."""
    return (
        (c >= 48 and c <= 57)
        or (c >= 65 and c <= 90)
        or (c >= 97 and c <= 122)
        or c == 95
        or c == 45
    )


def _hex_nibble(c: Int) -> Int:
    """Hex digit value, or -1 when not a hex character."""
    if c >= 48 and c <= 57:
        return c - 48
    if c >= 65 and c <= 70:
        return c - 55
    if c >= 97 and c <= 102:
        return c - 87
    return -1


def utf8_string(raw: List[UInt8]) -> String:
    """Decode file bytes into a String (real UTF-8).

    The old JSON path rebuilt Strings one byte at a time; a multi-byte
    title decoded as junk codepoints. Invalid sequences are skipped —
    never a crash for a cache file.
    """
    var out = String()
    var i = 0
    while i < len(raw):
        var b = Int(raw[i])
        var cp: Int
        var size = 1
        if b < 0x80:
            cp = b
        elif (b & 0xE0) == 0xC0:
            cp = b & 0x1F
            size = 2
        elif (b & 0xF0) == 0xE0:
            cp = b & 0x0F
            size = 3
        elif (b & 0xF8) == 0xF0:
            cp = b & 0x07
            size = 4
        else:
            i += 1
            continue
        if i + size > len(raw):
            i += 1
            continue
        var valid = True
        var j = 1
        while j < size:
            var cont = Int(raw[i + j])
            if (cont & 0xC0) != 0x80:
                valid = False
                break
            cp = (cp << 6) | (cont & 0x3F)
            j += 1
        if not valid or cp < 0 or cp > 0x10FFFF:
            i += 1
            continue
        out += String(chr(cp))
        i += size
    return out^


# ---------------------------------------------------------------------------
# Reader
# ---------------------------------------------------------------------------


def _skip_space(line: String, mut i: Int):
    """Advance the codepoint cursor past whitespace."""
    while True:
        var c = _cp_at(line, i)
        if c < 0 or not _is_space(c):
            return
        i = i + 1


def _rest_ok(line: String, mut i: Int) raises:
    """Only whitespace and/or a trailing comment may follow a value.

    Enforced so a hand-edited file with a typo never silently drops a
    key while appearing to load cleanly.
    """
    _skip_space(line, i)
    var c = _cp_at(line, i)
    if c < 0 or c == 0x23:
        return
    raise Error("toml: unexpected text after value")


def _read_quoted(line: String, mut i: Int, mut res: String) raises:
    """Read a basic "..." string (i starts at the quote), decoding
    \\ \\" \\n \\t \\r \\b \\f and \\uXXXX escapes; i ends past the
    closing quote. Single-line only — the file is processed line by
    line, which also makes a multi-line array unparseable by design."""
    i = i + 1  # consume the opening quote
    var run = String()
    while True:
        var c = _cp_at(line, i)
        if c < 0:
            raise Error("toml: string without closing quote")
        if c == 0x22:
            res = run^
            i = i + 1
            return
        if c == 0x5C:
            var esc = _cp_at(line, i + 1)
            if esc == 0x6E:
                run += "\n"
            elif esc == 0x74:
                run += "\t"
            elif esc == 0x72:
                run += "\r"
            elif esc == 0x22:
                run += '"'
            elif esc == 0x5C:
                run += "\\"
            elif esc == 0x62:
                run += String(chr(8))
            elif esc == 0x66:
                run += String(chr(12))
            elif esc == 0x75:
                var cpv = 0
                for j in range(4):
                    var nib = _hex_nibble(_cp_at(line, i + 2 + j))
                    if nib < 0:
                        raise Error("toml: bad \\u escape")
                    cpv = cpv * 16 + nib
                run += String(chr(cpv))
                i = i + 6
                continue
            else:
                raise Error("toml: unsupported escape")
            i = i + 2
            continue
        run += String(chr(c))
        i = i + 1


def _read_bare(line: String, mut i: Int, mut res: String) raises:
    """Read an unquoted value token (number or true/false): alnum with
    '-', '+', '.'. Stops at whitespace/'#'/end; the caller validates the
    remainder and dispatches on the token."""
    var run = String()
    while True:
        var c = _cp_at(line, i)
        if (
            c < 0
            or _is_space(c)
            or c == 0x23
            or not (
                (c >= 48 and c <= 57)
                or (c >= 65 and c <= 90)
                or (c >= 97 and c <= 122)
                or c == 45
                or c == 43
                or c == 46
            )
        ):
            break
        run += String(chr(c))
        i = i + 1
    if run.byte_length() == 0:
        raise Error("toml: empty value token")
    res = run^


def _read_array_of_strings(
    line: String, mut i: Int, mut res: List[String]
) raises:
    """Inline array of basic strings: [\"a\", \"b\"] (entry strings may
    span no newline — see _read_quoted)."""
    i = i + 1  # consume '['
    var items = List[String]()
    while True:
        _skip_space(line, i)
        var c = _cp_at(line, i)
        if c < 0:
            raise Error("toml: array without closing bracket")
        if c == 0x5D:
            res = items^
            i = i + 1
            return
        if c != 0x22:
            raise Error("toml: array entries must be quoted strings")
        var entry = String()
        _read_quoted(line, i, entry)
        items.append(entry^)
        _skip_space(line, i)
        var sep = _cp_at(line, i)
        if sep == 0x2C:
            i = i + 1
        elif sep == 0x5D:
            res = items^
            i = i + 1
            return
        else:
            raise Error("toml: expected ',' or ']' in array")


def _parse_line(
    line: String,
    mut tables: Dict[String, TomlSection],
    mut section: String,
) raises:
    """Parse one logical line: blank/comment, [section], or key = value.

    Values are typed into the section's maps (last one wins on a repeat
    key); anything malformed raises."""
    var i = 0
    _skip_space(line, i)
    var c = _cp_at(line, i)
    if c < 0 or c == 0x23:
        return  # blank or comment-only line
    if c == 0x5B:
        # [section] — bare name, then anything but spaces/comment is junk.
        i = i + 1
        var name = String()
        while True:
            var h = _cp_at(line, i)
            if h < 0:
                raise Error("toml: section header without closing bracket")
            if h == 0x5D:
                i = i + 1
                break
            if not _is_key_char(h):
                raise Error("toml: unexpected character in section name")
            name += String(chr(h))
            i = i + 1
        _skip_space(line, i)
        var t = _cp_at(line, i)
        if t >= 0 and t != 0x23:
            raise Error("toml: unexpected text after section header")
        section = name
        if not (section in tables):
            tables[section] = TomlSection()
        return
    # key = value
    var key = String()
    while True:
        var k = _cp_at(line, i)
        if k < 0:
            raise Error("toml: key without '='")
        if k == 0x3D:
            i = i + 1
            break
        if _is_space(k):
            # Spaces before '=' are legal; the '=' must come next.
            _skip_space(line, i)
            var eq = _cp_at(line, i)
            if eq != 0x3D:
                raise Error("toml: expected '=' after key")
            i = i + 1
            break
        if not _is_key_char(k):
            raise Error("toml: unexpected character in key")
        key += String(chr(k))
        i = i + 1
    if key.byte_length() == 0:
        raise Error("toml: empty key")
    _skip_space(line, i)
    var vc = _cp_at(line, i)
    if vc < 0:
        raise Error("toml: key without value")
    if vc == 0x22:
        var v = String()
        _read_quoted(line, i, v)
        _rest_ok(line, i)
        tables[section].strings[key] = v
        return
    if vc == 0x5B:
        var items = List[String]()
        _read_array_of_strings(line, i, items)
        _rest_ok(line, i)
        tables[section].str_arrays[key] = items^
        return
    var token = String()
    _read_bare(line, i, token)
    _rest_ok(line, i)
    if token == "true" or token == "false":
        tables[section].bools[key] = token == "true"
        return
    # Parse first, insert after — keeps the Error-raising parse calls out
    # of the same statement as the (DictKeyError-raising) assignment.
    var iv: Int = 0
    var fv: Float64 = 0.0
    var is_int = False
    var is_float = False
    try:
        iv = Int(token)
        is_int = True
    except:
        pass
    if not is_int:
        try:
            fv = Float64(token)
            is_float = True
        except:
            pass
    if is_int:
        tables[section].ints[key] = iv
        return
    if is_float:
        tables[section].floats[key] = fv
        return
    raise Error("toml: cannot parse value for key '" + key + "'")


def parse_toml(text: String) raises -> Dict[String, TomlSection]:
    """Parse TOML text into section tables (root keyed "").

    Raises on any input outside the subset — callers catch and rebuild
    defaults."""
    var tables = Dict[String, TomlSection]()
    tables[""] = TomlSection()
    var section = ""
    var line = String()
    for cp in text.codepoints():
        if Int(cp) == 10:
            _parse_line(line, tables, section)
            line = String()
        else:
            line += String(chr(Int(cp)))
    if line.count_codepoints() > 0:
        _parse_line(line, tables, section)
    return tables^


# ---------------------------------------------------------------------------
# Writer
# ---------------------------------------------------------------------------


def _hex_digit(v: Int) -> String:
    """One uppercase hex digit (0..15)."""
    if v < 10:
        return String(chr(48 + v))
    return String(chr(65 + v - 10))


def _toml_string(value: String) -> String:
    """One basic-quoted TOML string with escapes for quotes, backslashes,
    newlines, tabs, CRs, and any other control character."""
    var out = String()
    out += '"'
    for cp in value.codepoints():
        var c = Int(cp)
        if c == 0x5C:
            out += "\\\\"
        elif c == 0x22:
            out += '\\"'
        elif c == 0x0A:
            out += "\\n"
        elif c == 0x09:
            out += "\\t"
        elif c == 0x0D:
            out += "\\r"
        elif c < 0x20 or c == 0x7F:
            # Control char: \u00XX (uppercase hex, zero-padded).
            out += "\\u00" + _hex_digit(Int(c) >> 4) + _hex_digit(Int(c) & 0xF)
        else:
            out += String(chr(c))
    out += '"'
    return out^


struct TomlDoc(Movable):
    """Lines-in-progress for writing a TOML file.

    Contract: add root-table keys first, then call set_section() before
    adding section keys (sections and root keys do not interleave —
    neither user of this module needs them to)."""

    var lines: List[String]
    var section: String  # "" = root table

    def __init__(out self):
        self.lines = List[String]()
        self.section = ""

    def set_section(mut self, name: String):
        """Emit a [name] header; subsequent adds live inside it."""
        self.section = name
        self.lines.append("")
        self.lines.append("[" + name + "]")

    def add(mut self, key: String, value: String):
        self.lines.append(key + " = " + _toml_string(value))

    def add(mut self, key: String, value: Int):
        self.lines.append(key + " = " + String(value))

    def add(mut self, key: String, value: Float64):
        self.lines.append(key + " = " + String(value))

    def add(mut self, key: String, value: Bool):
        if value:
            self.lines.append(key + " = true")
        else:
            self.lines.append(key + " = false")

    def add(mut self, key: String, value: List[String]):
        var arr = String()
        arr += "["
        var first = True
        for i in range(len(value)):
            if not first:
                arr += ", "
            first = False
            arr += _toml_string(String(value[i]))
        arr += "]"
        self.lines.append(key + " = " + arr)

    def dump(self) -> String:
        """The full file text: one '\n'-separated line per entry."""
        var out = String()
        for i in range(len(self.lines)):
            out += self.lines[i]
            if i < len(self.lines) - 1:
                out += "\n"
        out += "\n"
        return out^
