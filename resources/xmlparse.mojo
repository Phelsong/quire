"""Quire — minimal XML parser (pure safe Mojo).

Implementation: recursive descent over codepoints. String indexing by
byte traps on non-ASCII on this toolchain (probed), so the cursor walks
codepoint indices and value runs are sliced from the source by index
(UTF-8 titles survive byte-for-byte).
"""

from std.collections import List


# ---------------------------------------------------------------------------
# Parse tree
# ---------------------------------------------------------------------------


struct XmlElement(Deinitable, Movable):
    """One parsed element: tag, attributes, children."""

    var tag: String
    var attrs: Dict[String, String]
    var children: List[XmlElement]

    def __init__(out self, tag: String):
        self.tag = tag
        self.attrs = Dict[String, String]()
        self.children = List[XmlElement]()

    def __deinit__(deinit self):
        pass

    def __init__(out self, *, deinit move: Self):
        self.tag = move.tag^
        self.attrs = move.attrs^
        self.children = move.children^


# ---------------------------------------------------------------------------
# Cursor: codepoint-index walker with one-slot pushback
# ---------------------------------------------------------------------------


struct _Cursor:
    """Codepoint cursor with one-slot pushback. next() yields the
    codepoint value (Int, -1 at end); slices are recovered by index via
    _slice so multi-byte codepoints append intact."""

    var src: String
    var slices: List[String]  # codepoint slices, materialized lazily
    var pos: Int  # codepoint index of the next read
    var pushback: Int  # -1 when empty

    def __init__(out self, src: String):
        self.src = src
        self.slices = List[String]()
        self.pos = 0
        self.pushback = -1

    def count(self) -> Int:
        return self.src.count_codepoints()

    def next(mut self) -> Int:
        if self.pushback >= 0:
            var cp = self.pushback
            self.pushback = -1
            return cp
        if self.pos >= self.count():
            return -1
        var idx = self.pos
        self.pos += 1
        return _codepoint_at(self.src, idx)

    def unread(mut self, cp: Int):
        self.pushback = cp

    def consume_index(mut self) -> Int:
        """Codepoint index of the most recent next() (for slicing)."""
        if self.pushback >= 0:
            return self.pos - 2
        return self.pos - 1


def _codepoint_at(src: String, idx: Int) -> Int:
    var i = 0
    for cp in src.codepoints():
        if i == idx:
            return Int(cp)
        i += 1
    return -1


def _slice_at(src: String, idx: Int) -> String:
    var i = 0
    for cp in src.codepoint_slices():
        if i == idx:
            return String(cp)
        i += 1
    return String()


# ---------------------------------------------------------------------------
# Character classes
# ---------------------------------------------------------------------------


def _is_ws(cp: Int) -> Bool:
    return (
        cp == ord(" ") or cp == ord("\t") or cp == ord("\n") or cp == ord("\r")
    )


def _is_name_char(cp: Int) -> Bool:
    return (
        (cp >= ord("a") and cp <= ord("z"))
        or (cp >= ord("A") and cp <= ord("Z"))
        or (cp >= ord("0") and cp <= ord("9"))
        or cp == ord("_")
        or cp == ord("-")
        or cp == ord(".")
        or cp == ord(":")
    )


def _decode_entity(body: String) -> String:
    """The five predefined XML entities; anything else passes through
    unchanged (matching ET's leniency for unknown entities)."""
    if body == "amp":
        return "&"
    if body == "lt":
        return "<"
    if body == "gt":
        return ">"
    if body == "quot":
        return '"'
    if body == "apos":
        return "'"
    return "&" + body + ";"


# ---------------------------------------------------------------------------
# Recursive descent
# ---------------------------------------------------------------------------


def _skip_ws(mut c: _Cursor):
    while True:
        var cp = c.next()
        if cp < 0:
            return
        if not _is_ws(cp):
            c.unread(cp)
            return


def _read_name(mut c: _Cursor) -> String:
    """Tag/attribute name from the current position."""
    var name = String()
    while True:
        var cp = c.next()
        if cp < 0:
            return name
        if not _is_name_char(cp):
            c.unread(cp)
            return name
        name += String(chr(cp))


def _read_attr_value(mut c: _Cursor) raises -> String:
    """Quoted attribute value with entity decoding."""
    var quote = c.next()
    if quote != ord('"') and quote != ord("'"):
        raise Error("xml: attribute value not quoted")

    var value = String()
    while True:
        var idx_before = c.consume_index() + 1  # index of the next read
        var cp = c.next()
        if cp < 0:
            raise Error("xml: unterminated attribute value")
        if cp == quote:
            return value
        if cp == ord("&"):
            value += _read_entity(c)
        else:
            value += _slice_at(c.src, idx_before)


def _read_entity(mut c: _Cursor) -> String:
    """Entity body after '&' up to ';', decoded."""
    var body = String()
    while True:
        var cp = c.next()
        if cp < 0:
            return "&" + body  # truncated entity — literal
        if cp == ord(";"):
            return _decode_entity(body)
        if _is_ws(cp) or cp == ord("<"):
            c.unread(cp)
            return "&" + body  # not an entity — literal ampersand
        body += String(chr(cp))


def _expect(mut c: _Cursor, want: Int, context: String) raises:
    var cp = c.next()
    if cp < 0:
        raise Error("xml: end of input, expected " + context)
    if cp != want:
        raise Error("xml: expected " + context)


def _parse_element(mut c: _Cursor) raises -> XmlElement:
    """Parse one element starting just after its '<'."""
    var tag = _read_name(c)
    if tag.byte_length() == 0:
        raise Error("xml: empty tag name")
    var elem = XmlElement(tag)

    # Attribute loop until '>' or self-closing '/>'.
    while True:
        _skip_ws(c)
        var cp = c.next()
        if cp < 0:
            raise Error("xml: end of input in <" + tag)
        if cp == ord(">"):
            break
        if cp == ord("/"):
            _expect(c, ord(">"), "'>' after self-closing <" + tag)
            return elem^
        if cp == ord("<"):
            raise Error("xml: '<' inside tag <" + tag)

        # Attribute name (first char already consumed).
        var attr_name = String(chr(cp))
        attr_name += _read_name(c)
        _skip_ws(c)
        _expect(c, ord("="), "'=' after attribute " + attr_name)
        elem.attrs[attr_name] = _read_attr_value(c)

    # Children until the matching close tag.
    while True:
        var cp = c.next()
        if cp < 0:
            raise Error("xml: unclosed element <" + tag + ">")
        if cp != ord("<"):
            continue  # text content: dropped (matches the old helper)
        var next_cp = c.next()
        if next_cp < 0:
            raise Error("xml: unclosed element <" + tag + ">")

        if next_cp == ord("/"):
            # Close tag: read the name, expect '>'.
            var close_tag = _read_name(c)
            _skip_ws(c)
            _expect(c, ord(">"), "'>' after </" + close_tag)
            if close_tag != tag:
                raise Error(
                    "xml: mismatched close </"
                    + close_tag
                    + "> for <"
                    + tag
                    + ">"
                )
            return elem^

        if next_cp == ord("?") or next_cp == ord("!"):
            # Declaration, comment, or DOCTYPE: skip to '>'.
            _skip_to_gt(c)
            continue

        c.unread(next_cp)
        elem.children.append(_parse_element(c))


def _skip_to_gt(mut c: _Cursor):
    """Skip markup (declaration/comment/DOCTYPE) up to the next '>'."""
    while True:
        var cp = c.next()
        if cp < 0:
            return
        if cp == ord(">"):
            return


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def parse_xml(text: String) raises -> XmlElement:
    """Parse an XML document into its root XmlElement.

    Raises Error on malformed input (unclosed tags, mismatched close
    tags, truncated attribute values).
    """
    var c = _Cursor(text)
    while True:
        _skip_ws(c)
        var cp = c.next()
        if cp < 0:
            raise Error("xml: no root element found")
        if cp != ord("<"):
            continue  # stray text before the root: ignored
        var next_cp = c.next()
        if next_cp < 0:
            raise Error("xml: end of input after '<'")
        if next_cp == ord("?") or next_cp == ord("!"):
            _skip_to_gt(c)
            continue
        c.unread(next_cp)
        return _parse_element(c)
