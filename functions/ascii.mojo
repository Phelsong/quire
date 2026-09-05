# ---------------------------------------------------------------------------
# ASCII lookup table — converts codepoints 32..126 to single-char strings
#
# Pure Mojo: no Python interop. The full printable ASCII range (space through
# tilde) is stored as a single comptime string literal. Byte-indexing into
# this literal yields the correct single-character StringSlice because all 95
# characters are single-byte UTF-8 (they ARE ASCII).
# ---------------------------------------------------------------------------

comptime ASCII_FIRST = 32
comptime ASCII_LAST = 126

# All 95 printable ASCII characters, codepoints 32 (space) through 126 (~).
# Indexing: char_at(codepoint) -> ASCII_PRINTABLE[byte=codepoint-32]
comptime ASCII_PRINTABLE = (
    " !\"#$%&'()*+,-./"
    "0123456789:;<=>?"
    "@ABCDEFGHIJKLMNO"
    "PQRSTUVWXYZ[\\]^_"
    "`abcdefghijklmno"
    "pqrstuvwxyz{|}~"
)


struct AsciiTable:
    var chars: List[String]
    var initialized: Bool

    def __init__(out self):
        self.chars = List[String]()
        self.initialized = False

    def init(mut self) raises:
        """Build lookup from a comptime ASCII string literal — no Python needed.
        """
        if self.initialized:
            return
        for i in range(ASCII_FIRST, ASCII_LAST + 1):
            # ASCII_PRINTABLE contains exactly the chars for codepoints 32..126,
            # so byte index (i - ASCII_FIRST) maps directly to the right char.
            self.chars.append(String(ASCII_PRINTABLE[byte=(i - ASCII_FIRST)]))
        self.initialized = True

    def lookup(self, codepoint: Int) -> String:
        """Return the string for a printable ASCII codepoint, or empty."""
        if codepoint < ASCII_FIRST or codepoint > ASCII_LAST:
            return ""
        return self.chars[codepoint - ASCII_FIRST]
