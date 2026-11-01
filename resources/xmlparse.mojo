"""Quire — minimal XML parser (pure safe Mojo).

Implementation: recursive descent with a byte-positioned UTF-8 cursor.
`String[byte=N]` on a codepoint boundary yields the codepoint starting
at N plus its byte width (probed), so next() is an O(1) decode step and
multi-byte UTF-8 survives byte-for-byte; byte N mid-codepoint aborts
(and codepoint-index rescan would be O(n) per read), so pos is only
ever advanced by a codepoint's decoded width.
"""

from std.collections import List


# ---------------------------------------------------------------------------
# Parse tree
# ---------------------------------------------------------------------------


struct XmlElement(Copyable, Deinitable, Movable):
    """One parsed element: tag, attributes, children.

    Copyable so the bridge layer (functions.plex_bridge accessors) can
    lift children out of a parse tree into its own lists — a response
    tree is read through borrowed refs everywhere else."""

    var tag: String
    var attrs: Dict[String, String]
    var children: List[XmlElement]

    def __init__(out self, tag: String):
        self.tag = tag
        self.attrs = Dict[String, String]()
        self.children = List[XmlElement]()

    def __init__(out self, *, copy: Self):
        self.tag = copy.tag
        self.attrs = copy.attrs.copy()
        self.children = copy.children.copy()

    def __deinit__(deinit self):
        pass

    def __init__(out self, *, deinit move: Self):
        self.tag = move.tag^
        self.attrs = move.attrs^
        self.children = move.children^


# ---------------------------------------------------------------------------
# Cursor: byte-positioned UTF-8 walker with one-slot pushback
# ---------------------------------------------------------------------------


struct _Cursor:
    """Forward-only UTF-8 cursor with one-slot pushback. next() decodes
    exactly one codepoint at the cursor's byte offset: String[byte=N] at
    a codepoint boundary (probed) yields the codepoint starting there
    plus its byte width, so each step is O(1) and multi-byte UTF-8
    survives byte-for-byte. pos rests on a codepoint boundary whenever
    it is not the sentinel end."""

    var src: String
    var pos: Int  # byte offset of the next read
    var pushback: Int  # codepoint value; -1 when empty

    def __init__(out self, src: String):
        self.src = src
        self.pos = 0
        self.pushback = -1

    def next(mut self) -> Int:
        if self.pushback >= 0:
            var cp = self.pushback
            self.pushback = -1
            return cp
        var end = self.src.byte_length()
        if self.pos >= end:
            return -1
        var at = self.src[byte=self.pos]
        self.pos += at.byte_length()
        return ord(String(at))

    def unread(mut self, cp: Int):
        self.pushback = cp


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


def _entity_codepoint(body: String, start_cp: Int, hex_mode: Bool) -> Int:
    """Numeric value of the digit run at codepoint index start_cp; -1 on
    an empty run, a non-digit character, or an out-of-range value (the
    caller then keeps the entity as literal text, like an unknown name).

    Entity bodies are ASCII (digits x/X only), so byte and codepoint
    indices agree here and the digit run is always well-formed to walk.
    """
    var value = 0
    var count = 0
    var i = 0
    for cp in body.codepoints():
        if i < start_cp:
            i += 1
            continue
        var c = Int(cp)
        var digit: Int
        if c >= 48 and c <= 57:  # 0-9
            digit = c - 48
        elif hex_mode and c >= 97 and c <= 102:  # a-f
            digit = c - 87
        elif hex_mode and c >= 65 and c <= 70:  # A-F
            digit = c - 55
        else:
            return -1
        value = value * (16 if hex_mode else 10) + digit
        count += 1
        if value > 0x10FFFF:
            return -1
    if count == 0 or value < 1:
        return -1
    return value


def _decode_entity(body: String) -> String:
    """Decode one entity body (the text between '&' and ';').

    The five predefined XML entities plus numeric character references —
    decimal (&#39;) and hex (&#x27;). Plex serializes apostrophes and
    quotes inside titles/attributes as numeric refs, so they must decode
    or every "it's" renders as "it&#39;s". Anything else passes through
    unchanged (matching ET's leniency for unknown entities)."""
    if body.byte_length() > 0 and String(body[byte=0]) == "#":
        var cp: Int
        if body.byte_length() > 2 and (
            String(body[byte=1]) == "x" or String(body[byte=1]) == "X"
        ):
            # Hex form: &#x27; / &#X27;
            cp = _entity_codepoint(body, 2, True)
        else:
            # Decimal form: &#39;
            cp = _entity_codepoint(body, 1, False)
        if cp > 0 and cp <= 0x10FFFF and not (cp >= 0xD800 and cp <= 0xDFFF):
            return String(chr(cp))
        return "&" + body + ";"
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
        var cp = c.next()
        if cp < 0:
            raise Error("xml: unterminated attribute value")
        if cp == quote:
            return value
        if cp == ord("&"):
            value += _read_entity(c)
        else:
            value += String(chr(cp))


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
