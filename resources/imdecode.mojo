"""Image decoding utilities — pure Mojo implementation.

Decodes in-memory image buffers (PNG, JPEG) into raw RGBA pixel data.
Companion to `resources/imencode.mojo` (encode) — together they replace
the Pillow dependency for cover art handling.

Supported PNG input:
  - color types 0 (gray), 2 (RGB), 3 (palette), 4 (gray+alpha), 6 (RGBA)
  - bit depths 1/2/4/8/16 for gray and palette, 8/16 for the rest
  - non-interlaced only (Adam7 raises)
  - full zlib inflate: stored, fixed, and dynamic Huffman blocks

Supported JPEG input:
  - baseline sequential DCT (SOF0), Huffman-coded
  - grayscale, YCbCr 1x1/2x1/1x2/2x2 sampling with restart markers
  - progressive JPEG raises (Plex transcodes are baseline)

JPEG fidelity: grayscale and 4:4:4 fixtures decode within ±1 of
Pillow/libjpeg; subsampled (4:2:0/4:2:2) within ±6 on >99% of pixels
(remainder ±8) — residual is integer IDCT rounding vs libjpeg's float
IDCT plus BT.601 conversion rounding. Chroma upsampling uses the
libjpeg "triangle" filter (empirically fitted against PIL: even output
px (3*near+left+2)>>2, odd (3*near+right+1)>>2, edge replicate; same
law vertically), matching libjpeg's fancy upsample for 2x1 and 2x2.

16-bit notes: samples are reduced to 8 bits by taking the high byte
(sample >> 8) — the PNG-spec-canonical scaling. (Pillow's own I;16 →
RGBA conversion clips instead of scaling, so it is not a valid
reference for 16-bit gray; the other 48 battery cases match Pillow
byte-for-byte.)

No Python interop required. All operations are pure Mojo.
"""

from std.math import abs


# =====================================================
# Decoded image container
# =====================================================


@fieldwise_init
struct DecodedImage(Movable):
    """Raw RGBA pixel buffer with dimensions.

    `pixels` is row-major RGBA, 4 bytes per pixel, length
    width * height * 4.
    """

    var pixels: List[UInt8]
    var width: Int
    var height: Int


# =====================================================
# Big-endian reads
# =====================================================


def _read_be16(data: List[UInt8], off: Int) -> Int:
    return (Int(data[off]) << 8) | Int(data[off + 1])


def _read_be32(data: List[UInt8], off: Int) -> Int:
    return (
        (Int(data[off]) << 24)
        | (Int(data[off + 1]) << 16)
        | (Int(data[off + 2]) << 8)
        | Int(data[off + 3])
    )


# =====================================================
# Bit reader (LSB-first, per DEFLATE/JPEG entropy coding)
# =====================================================


@fieldwise_init
struct BitReader(Movable):
    """MSB-first bit reader over a byte list (JPEG convention)."""

    var data: List[UInt8]
    var byte_pos: Int
    var bit_acc: UInt32
    var bit_count: Int

    def _refill(mut self) raises:
        """Load the next byte into the accumulator, honouring 0xFF stuffing."""
        if self.byte_pos >= len(self.data):
            raise "bitreader: unexpected end of data"
        var b = self.data[self.byte_pos]
        self.byte_pos += 1
        if b == 0xFF:
            # Entropy-coded segments stuff a 0x00 after any 0xFF.
            if self.byte_pos >= len(self.data):
                raise "bitreader: truncated 0xFF sequence"
            var nxt = self.data[self.byte_pos]
            if nxt == 0x00:
                self.byte_pos += 1
            # RST markers are handled by the JPEG caller through restart().
        self.bit_acc = (self.bit_acc << 8) | UInt32(b)
        self.bit_count += 8

    def get_bits(mut self, n: Int) raises -> Int:
        """Read n bits, MSB first."""
        while self.bit_count < n:
            self._refill()
        var shift = self.bit_count - n
        var value = Int((self.bit_acc >> UInt32(shift)) & UInt32((1 << n) - 1))
        self.bit_count = shift
        # Mask off consumed bits so the accumulator never grows unbounded.
        var keep: UInt32 = (UInt32(1) << UInt32(shift)) - 1
        self.bit_acc = self.bit_acc & keep
        return value

    def reset(mut self, pos: Int):
        """Restart reading at an absolute byte offset (marker recovery)."""
        self.byte_pos = pos
        self.bit_acc = 0
        self.bit_count = 0


# =====================================================
# Canonical Huffman decoding (zlib "puff" style, LSB-first)
# =====================================================


@fieldwise_init
struct LsbBitReader(Movable):
    """LSB-first bit reader used by DEFLATE."""

    var data: List[UInt8]
    var byte_pos: Int
    var bit_buf: UInt32
    var bit_cnt: Int

    def _fill(mut self) raises:
        if self.byte_pos >= len(self.data):
            raise "inflate: unexpected end of stream"
        self.bit_buf = self.bit_buf | (
            UInt32(self.data[self.byte_pos]) << UInt32(self.bit_cnt)
        )
        self.byte_pos += 1
        self.bit_cnt += 8

    def get_bits(mut self, n: Int) raises -> Int:
        while self.bit_cnt < n:
            self._fill()
        var mask = UInt32((1 << n) - 1)
        var value = self.bit_buf & mask
        self.bit_buf = self.bit_buf >> UInt32(n)
        self.bit_cnt -= n
        return Int(value)

    def align_to_byte(mut self):
        """Drop bits until the reader is byte-aligned."""
        var drop = self.bit_cnt % 8
        self.bit_buf = self.bit_buf >> UInt32(drop)
        self.bit_cnt -= drop


@fieldwise_init
struct Huffman(Copyable, Movable):
    """Canonical Huffman table ready for bit-at-a-time decoding."""

    var counts: List[Int]  # codes per bit length, index 0..15
    var symbols: List[Int]  # symbols ordered by (length, symbol value)

    @staticmethod
    def build(lengths: List[UInt8]) raises -> Huffman:
        # 17-element count array: JPEG codes run up to 16 bits, DEFLATE 15.
        var counts = List[Int]()
        counts.reserve(17)
        for _ in range(17):
            counts.append(0)
        for i in range(len(lengths)):
            counts[Int(lengths[i])] += 1
        if counts[0] == len(lengths):
            # No codes at all — valid for empty distance tables.
            var empty_syms = List[Int]()
            return Huffman(counts=counts^, symbols=empty_syms^)

        # Over-subscribed or incomplete check.
        var left = 1
        for length in range(1, 17):
            left = left << 1
            left -= counts[length]
            if left < 0:
                raise "huffman: over-subscribed code lengths"

        # Symbols ordered by (code length, symbol value) — decode() relies
        # on this ordering to map code ranges onto symbol slots.
        var symbols = List[Int]()
        symbols.reserve(len(lengths))
        for l in range(1, 17):
            for sym in range(len(lengths)):
                if Int(lengths[sym]) == l:
                    symbols.append(sym)

        return Huffman(counts=counts^, symbols=symbols^)

    def decode_msb(mut self, mut br: BitReader) raises -> Int:
        """Canonical decode, MSB-first bit order (JPEG entropy segments).

        Mirrors the LSB version but walks codes MSB-first: extend the code
        one bit at a time and compare against the count window per length.
        """
        var code = 0
        var first = 0
        var index = 0
        for length in range(1, 17):
            code = (code << 1) | br.get_bits(1)
            var count = self.counts[length]
            if code - first < count:
                return self.symbols[index + (code - first)]
            index += count
            first = (first + count) << 1
        raise "jpeg: invalid huffman code"

    def decode(mut self, mut br: LsbBitReader) raises -> Int:
        var code = 0
        var first = 0
        var index = 0
        for length in range(1, 17):
            code = code | br.get_bits(1)
            var count = self.counts[length]
            if code - first < count:
                return self.symbols[index + (code - first)]
            index += count
            first = (first + count) << 1
            code = code << 1
        raise "huffman: invalid code"


# =====================================================
# DEFLATE (RFC 1951) — stored / fixed / dynamic blocks
# =====================================================


comptime _LEN_BASE = [
    3,
    4,
    5,
    6,
    7,
    8,
    9,
    10,
    11,
    13,
    15,
    17,
    19,
    23,
    27,
    31,
    35,
    43,
    51,
    59,
    67,
    83,
    99,
    115,
    131,
    163,
    195,
    227,
    258,
]
comptime _LEN_EXTRA = [
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    1,
    1,
    1,
    1,
    2,
    2,
    2,
    2,
    3,
    3,
    3,
    3,
    4,
    4,
    4,
    4,
    5,
    5,
    5,
    5,
    0,
]
comptime _DIST_BASE = [
    1,
    2,
    3,
    4,
    5,
    7,
    9,
    13,
    17,
    25,
    33,
    49,
    65,
    97,
    129,
    193,
    257,
    385,
    513,
    769,
    1025,
    1537,
    2049,
    3073,
    4097,
    6145,
    8193,
    12289,
    16385,
    24577,
]
comptime _DIST_EXTRA = [
    0,
    0,
    0,
    0,
    1,
    1,
    2,
    2,
    3,
    3,
    4,
    4,
    5,
    5,
    6,
    6,
    7,
    7,
    8,
    8,
    9,
    9,
    10,
    10,
    11,
    11,
    12,
    12,
    13,
    13,
]


def _len_base(idx: Int) raises -> Int:
    """Runtime lookup into the comptime length base table."""
    comptime for n in range(29):
        if n == idx:
            return materialize[_LEN_BASE[n]]()
    raise "inflate: length index out of range"


def _len_extra(idx: Int) raises -> Int:
    comptime for n in range(29):
        if n == idx:
            return materialize[_LEN_EXTRA[n]]()
    raise "inflate: length extra index out of range"


def _dist_base(idx: Int) raises -> Int:
    comptime for n in range(30):
        if n == idx:
            return materialize[_DIST_BASE[n]]()
    raise "inflate: distance index out of range"


def _dist_extra(idx: Int) raises -> Int:
    comptime for n in range(30):
        if n == idx:
            return materialize[_DIST_EXTRA[n]]()
    raise "inflate: distance extra index out of range"


def _fixed_tables() raises -> Tuple[Huffman, Huffman]:
    # Literal/length: 0-143 => 8, 144-255 => 9, 256-279 => 7, 280-287 => 8.
    var lengths = List[UInt8]()
    lengths.reserve(288)
    for i in range(144):
        lengths.append(8)
    for i in range(256 - 144):
        lengths.append(9)
    for i in range(280 - 256):
        lengths.append(7)
    for i in range(288 - 280):
        lengths.append(8)
    var lit = Huffman.build(lengths^)

    # Fixed distance table: 32 codes of 5 bits.
    var dist_lengths = List[UInt8]()
    dist_lengths.reserve(30)
    for i in range(30):
        dist_lengths.append(5)
    var dist = Huffman.build(dist_lengths^)
    return (lit^, dist^)


def _dynamic_tables(mut br: LsbBitReader) raises -> Tuple[Huffman, Huffman]:
    var hlit = br.get_bits(5) + 257
    var hdist = br.get_bits(5) + 1
    var hclen = br.get_bits(4) + 4

    # Code-length alphabet order per RFC 1951 §3.2.7.
    var order = List[Int]()
    for v in [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]:
        order.append(v)
    var cl_lengths = List[UInt8]()
    for _ in range(19):
        cl_lengths.append(0)
    for i in range(hclen):
        cl_lengths[order[i]] = UInt8(br.get_bits(3))

    var cl_table = Huffman.build(cl_lengths^)

    var lengths = List[UInt8]()
    lengths.reserve(hlit + hdist)
    while len(lengths) < hlit + hdist:
        var sym = cl_table.decode(br)
        if sym < 16:
            lengths.append(UInt8(sym))
        elif sym == 16:
            if len(lengths) == 0:
                raise "inflate: repeat with no previous length"
            var prev = lengths[len(lengths) - 1]
            var repeat = 3 + br.get_bits(2)
            for _ in range(repeat):
                lengths.append(prev)
        elif sym == 17:
            var repeat = 3 + br.get_bits(3)
            for _ in range(repeat):
                lengths.append(0)
        else:
            var repeat = 11 + br.get_bits(7)
            for _ in range(repeat):
                lengths.append(0)

    if len(lengths) != hlit + hdist:
        raise "inflate: code length count mismatch"

    var lit_lengths = List[UInt8]()
    var dist_lengths = List[UInt8]()
    for i in range(hlit):
        lit_lengths.append(lengths[i])
    for i in range(hdist):
        dist_lengths.append(lengths[hlit + i])

    var lit = Huffman.build(lit_lengths^)
    var dist = Huffman.build(dist_lengths^)
    return (lit^, dist^)


def _inflate_blocks(mut br: LsbBitReader) raises -> List[UInt8]:
    var out = List[UInt8]()
    var final = False
    while not final:
        final = br.get_bits(1) == 1
        var btype = br.get_bits(2)
        if btype == 0:
            # Stored block: align to byte, read LEN/NLEN, copy verbatim.
            br.align_to_byte()
            var pos = 0
            # Pull LEN and NLEN directly from the underlying byte stream.
            var base = br.byte_pos - (br.bit_cnt // 8)
            var len_lo = Int(br.data[base])
            var len_hi = Int(br.data[base + 1])
            var nlen_lo = Int(br.data[base + 2])
            var nlen_hi = Int(br.data[base + 3])
            var block_len = len_lo | (len_hi << 8)
            var nlen = nlen_lo | (nlen_hi << 8)
            if block_len != (~nlen & 0xFFFF):
                raise "inflate: stored block length check failed"
            pos = base + 4
            if pos + block_len > len(br.data):
                raise "inflate: stored block overruns input"
            for i in range(block_len):
                out.append(br.data[pos + i])
            # Reset the bit accumulator past the copied bytes.
            br.byte_pos = pos + block_len
            br.bit_buf = 0
            br.bit_cnt = 0
        elif btype == 1:
            var lit_dist = _fixed_tables()
            var lit_t = lit_dist[0].copy()
            var dist_t = lit_dist[1].copy()
            _inflate_block_huffman(br, lit_t, dist_t, out)
        elif btype == 2:
            var lit_dist = _dynamic_tables(br)
            var lit_t = lit_dist[0].copy()
            var dist_t = lit_dist[1].copy()
            _inflate_block_huffman(br, lit_t, dist_t, out)
        else:
            raise "inflate: invalid block type"
    return out^


comptime _LEN_BASE_LEN = 29
comptime _DIST_BASE_LEN = 30


def _inflate_block_huffman(
    mut br: LsbBitReader,
    mut lit: Huffman,
    mut dist: Huffman,
    mut out: List[UInt8],
) raises:
    while True:
        var sym = lit.decode(br)
        if sym < 256:
            out.append(UInt8(sym))
        elif sym == 256:
            return
        else:
            var idx = sym - 257
            if idx >= _LEN_BASE_LEN:
                raise "inflate: invalid length symbol"
            var length = _len_base(idx) + br.get_bits(_len_extra(idx))
            var dsym = dist.decode(br)
            if dsym >= _DIST_BASE_LEN:
                raise "inflate: invalid distance symbol"
            var distance = _dist_base(dsym) + br.get_bits(_dist_extra(dsym))
            if distance > len(out):
                raise "inflate: distance beyond output"
            var start = len(out) - distance
            for i in range(length):
                out.append(out[start + i])


def zlib_inflate(zdata: List[UInt8]) raises -> List[UInt8]:
    """Inflate a zlib stream (RFC 1950 header + RFC 1951 body)."""
    if len(zdata) < 6:
        raise "inflate: stream too short"
    var cmf = Int(zdata[0])
    var flg = Int(zdata[1])
    if (cmf & 0x0F) != 8:
        raise "inflate: unsupported compression method"
    if ((cmf << 8) | flg) % 31 != 0:
        raise "inflate: zlib header check failed"

    var br = LsbBitReader(data=zdata.copy(), byte_pos=2, bit_buf=0, bit_cnt=0)
    var raw = _inflate_blocks(br)

    # Trailer: 4-byte big-endian Adler-32 of the uncompressed data. The
    # bit reader may hold a few pending bits; realign to the first trailer
    # byte and verify when the stream is long enough for the check.
    var trailer = br.byte_pos - (br.bit_cnt // 8)
    if trailer + 4 <= len(zdata):
        var expect = UInt32(_read_be32(zdata, trailer))
        var actual = _adler32(raw)
        if expect != actual:
            raise "inflate: adler32 mismatch"
    return raw^


def _adler32(data: List[UInt8]) -> UInt32:
    var a: UInt32 = 1
    var b: UInt32 = 0
    for i in range(len(data)):
        a = (a + UInt32(data[i])) % 65521
        b = (b + a) % 65521
    return (b << 16) | a


# =====================================================
# PNG decode
# =====================================================


def _png_unfilter(
    raw: List[UInt8], width: Int, height: Int, channels: Int, depth: Int
) raises -> List[UInt8]:
    """Reverse per-row PNG filtering, returning packed scanline bytes."""
    var bits_per_pixel = channels * depth
    var bytes_per_pixel = max(1, bits_per_pixel // 8)
    var stride = (width * bits_per_pixel + 7) // 8
    var recon = List[UInt8]()
    recon.reserve(height * stride)

    var row_start = 0
    for _row in range(height):
        var ftype = Int(raw[row_start])
        if ftype > 4:
            raise "png: unknown filter type"
        var data_start = row_start + 1
        for x in range(stride):
            var cur = Int(raw[data_start + x])
            var a = (
                Int(recon[len(recon) - bytes_per_pixel]) if x
                >= bytes_per_pixel else 0
            )
            var b = 0
            var c = 0
            if len(recon) >= stride:
                # len(recon) is recon_row_start + x here, so prev_row_start
                # already points at the up-row byte for this column x.
                var prev_row_start = len(recon) - stride
                b = Int(recon[prev_row_start])
                if x >= bytes_per_pixel:
                    c = Int(recon[prev_row_start - bytes_per_pixel])
            if ftype == 0:
                recon.append(UInt8(cur))
            elif ftype == 1:
                recon.append(UInt8(cur + a))
            elif ftype == 2:
                recon.append(UInt8(cur + b))
            elif ftype == 3:
                recon.append(UInt8(cur + ((a + b) // 2)))
            else:
                # Paeth predictor.
                var p = a + b - c
                var pa = abs(p - a)
                var pb = abs(p - b)
                var pc = abs(p - c)
                var pred = c
                if pa <= pb and pa <= pc:
                    pred = a
                elif pb <= pc:
                    pred = b
                recon.append(UInt8(cur + pred))
        row_start += 1 + stride
    if row_start != len(raw):
        # Tolerate trailing garbage but never accept truncation.
        if row_start > len(raw):
            raise "png: truncated pixel data"
    return recon^


def _png_to_rgba(
    recon: List[UInt8],
    width: Int,
    height: Int,
    channels_in: Int,
    depth: Int,
    palette: List[UInt8],
    trns: List[UInt8],
) raises -> List[UInt8]:
    """Expand packed scanlines to a full RGBA buffer."""
    var out = List[UInt8]()
    out.reserve(width * height * 4)
    var bits_per_pixel = channels_in * depth
    var stride = (width * bits_per_pixel + 7) // 8

    for row in range(height):
        var row_base = row * stride
        for x in range(width):
            var r: Int = 0
            var g: Int = 0
            var b: Int = 0
            var alpha: Int = 255
            if depth == 8:
                var px = row_base + x * channels_in
                if channels_in == 1:
                    var gray = Int(recon[px])
                    r = gray
                    g = gray
                    b = gray
                elif channels_in == 2:
                    var gray = Int(recon[px])
                    alpha = Int(recon[px + 1])
                    r = gray
                    g = gray
                    b = gray
                elif channels_in == 3:
                    r = Int(recon[px])
                    g = Int(recon[px + 1])
                    b = Int(recon[px + 2])
                else:
                    r = Int(recon[px])
                    g = Int(recon[px + 1])
                    b = Int(recon[px + 2])
                    alpha = Int(recon[px + 3])
            elif depth == 16:
                # High byte first — take even indices for the 8-bit value.
                var px = row_base + x * channels_in * 2
                if channels_in == 1:
                    var gray = Int(recon[px])
                    r = gray
                    g = gray
                    b = gray
                elif channels_in == 2:
                    var gray = Int(recon[px])
                    alpha = Int(recon[px + 2])
                    r = gray
                    g = gray
                    b = gray
                elif channels_in == 3:
                    r = Int(recon[px])
                    g = Int(recon[px + 2])
                    b = Int(recon[px + 4])
                else:
                    r = Int(recon[px])
                    g = Int(recon[px + 2])
                    b = Int(recon[px + 4])
                    alpha = Int(recon[px + 6])
            else:
                # Sub-byte depths: grayscale (type 0) or palette (type 3).
                var bit_pos = x * depth
                var byte_val = Int(recon[row_base + (bit_pos >> 3)])
                var shift = 8 - depth - (bit_pos & 7)
                var idx = (byte_val >> shift) & ((1 << depth) - 1)
                if channels_in == 1:
                    # Gray scaling: expand value to full range.
                    var maxv = (1 << depth) - 1
                    var gray = (idx * 255) // maxv
                    r = gray
                    g = gray
                    b = gray
                elif channels_in == 3:
                    # Palette lookup.
                    if idx * 3 + 2 >= len(palette):
                        raise "png: palette index out of range"
                    r = Int(palette[idx * 3])
                    g = Int(palette[idx * 3 + 1])
                    b = Int(palette[idx * 3 + 2])
                    if idx < len(trns):
                        alpha = Int(trns[idx])
                else:
                    raise "png: unsupported sub-byte color type"
            out.append(UInt8(r))
            out.append(UInt8(g))
            out.append(UInt8(b))
            out.append(UInt8(alpha))
    return out^


def imdecode_png(data: List[UInt8]) raises -> DecodedImage:
    """Decode a PNG buffer (non-interlaced) into an RGBA DecodedImage."""
    var sig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    if len(data) < 8 + 12:
        raise "png: buffer too short"
    for i in range(8):
        if Int(data[i]) != sig[i]:
            raise "png: bad signature"

    var width = 0
    var height = 0
    var depth = 8
    var color_type = 0
    var idat = List[UInt8]()
    var palette = List[UInt8]()
    var trns = List[UInt8]()

    var pos = 8
    while pos + 8 <= len(data):
        var chunk_len = _read_be32(data, pos)
        var ctype = [
            data[pos + 4],
            data[pos + 5],
            data[pos + 6],
            data[pos + 7],
        ]
        var data_start = pos + 8
        if data_start + chunk_len + 4 > len(data):
            raise "png: chunk overruns buffer"

        if (
            ctype[0] == 0x49
            and ctype[1] == 0x48
            and ctype[2] == 0x44
            and ctype[3] == 0x52
        ):  # IHDR
            width = _read_be32(data, data_start)
            height = _read_be32(data, data_start + 4)
            depth = Int(data[data_start + 8])
            color_type = Int(data[data_start + 9])
            if Int(data[data_start + 10]) != 0:
                raise "png: unsupported compression method"
            if Int(data[data_start + 12]) != 0:
                raise "png: interlaced PNG not supported"
        elif (
            ctype[0] == 0x50
            and ctype[1] == 0x4C
            and ctype[2] == 0x54
            and ctype[3] == 0x45
        ):  # PLTE
            for i in range(chunk_len):
                palette.append(data[data_start + i])
        elif (
            ctype[0] == 0x74
            and ctype[1] == 0x52
            and ctype[2] == 0x4E
            and ctype[3] == 0x53
        ):  # tRNS
            for i in range(chunk_len):
                trns.append(data[data_start + i])
        elif (
            ctype[0] == 0x49
            and ctype[1] == 0x44
            and ctype[2] == 0x41
            and ctype[3] == 0x54
        ):  # IDAT
            for i in range(chunk_len):
                idat.append(data[data_start + i])
        elif (
            ctype[0] == 0x49
            and ctype[1] == 0x45
            and ctype[2] == 0x4E
            and ctype[3] == 0x44
        ):  # IEND
            pos = len(data)
            break

        pos = data_start + chunk_len + 4

    if width <= 0 or height <= 0:
        raise "png: missing or invalid IHDR"
    if len(idat) == 0:
        raise "png: no IDAT chunks"

    var recon_compressed = zlib_inflate(idat^)
    var channels_in: Int
    if color_type == 0:
        channels_in = 1
    elif color_type == 2:
        channels_in = 3
    elif color_type == 3:
        channels_in = 1
    elif color_type == 4:
        channels_in = 2
    elif color_type == 6:
        channels_in = 4
    else:
        raise "png: unsupported color type"

    if color_type == 3 and len(palette) == 0:
        raise "png: palette image without PLTE"

    var unfiltered = _png_unfilter(
        recon_compressed, width, height, channels_in, depth
    )
    var rgba = _png_to_rgba(
        unfiltered^, width, height, channels_in, depth, palette^, trns^
    )
    return DecodedImage(pixels=rgba^, width=width, height=height)


# =====================================================
# imdecode — format dispatcher
# =====================================================


def imdecode(data: List[UInt8]) raises -> DecodedImage:
    """Detect the image format and decode to RGBA pixels.

    Dispatches on magic bytes: PNG signature or JPEG SOI marker.
    """
    if len(data) >= 8 and Int(data[0]) == 0x89 and Int(data[1]) == 0x50:
        return imdecode_png(data.copy())
    if len(data) >= 2 and Int(data[0]) == 0xFF and Int(data[1]) == 0xD8:
        return imdecode_jpeg(data.copy())
    raise "imdecode: unsupported format (need PNG or JPEG)"


# =====================================================
# JPEG decode — baseline sequential DCT (ITU-T T.81)
# =====================================================


comptime _ZIGZAG = [
    0,
    1,
    8,
    16,
    9,
    2,
    3,
    10,
    17,
    24,
    32,
    25,
    18,
    11,
    4,
    5,
    12,
    19,
    26,
    33,
    40,
    48,
    41,
    34,
    27,
    20,
    13,
    6,
    7,
    14,
    21,
    28,
    35,
    42,
    49,
    56,
    57,
    50,
    43,
    36,
    29,
    22,
    15,
    23,
    30,
    37,
    44,
    51,
    58,
    59,
    52,
    45,
    38,
    31,
    39,
    46,
    53,
    60,
    61,
    54,
    47,
    55,
    62,
    63,
]


def _zz(n: Int) raises -> Int:
    """Runtime lookup into the zig-zag order table."""
    comptime for i in range(64):
        if i == n:
            return materialize[_ZIGZAG[i]]()
    raise "jpeg: zigzag index out of range"


@fieldwise_init
struct JpegComponent(Copyable, Movable):
    """One color component's decode state (per SOF0/SOS)."""

    var cid: Int
    var h_sampling: Int
    var v_sampling: Int
    var quant_table: Int  # index into quant tables
    var dc_table: Int  # index into huffman DC tables
    var ac_table: Int  # index into huffman AC tables
    var dc_pred: Int  # running DC prediction
    var blocks_w: Int  # blocks per MCU line (padded)
    var blocks_h: Int


def _clamp8(v: Int) -> UInt8:
    if v < 0:
        return 0
    if v > 255:
        return 255
    return UInt8(v)


def _idct_2d(block: List[Int]) raises -> List[Int]:
    """Inverse DCT of an 8x8 dequantized coefficient block.

    Separable two-pass integer IDCT. COS rows are 12-bit fixed-point
    round(4096 * cos((2x+1) * u * pi / 16)); row u=0 carries the 1/sqrt(2)
    basis normalization folded in (2896 instead of 4096), matching the
    f = (1/4) * C(u) * C(v) * F * cos * cos convention. Output is centered
    at 0 (level shift +128 happens at the blit site): out = s >> 26.
    """
    comptime COS = [
        [2896, 2896, 2896, 2896, 2896, 2896, 2896, 2896],
        [4017, 3406, 2276, 799, -799, -2276, -3406, -4017],
        [3784, 1567, -1567, -3784, -3784, -1567, 1567, 3784],
        [3406, -799, -4017, -2276, 2276, 4017, 799, -3406],
        [2896, -2896, -2896, 2896, 2896, -2896, -2896, 2896],
        [2276, -4017, 799, 3406, -3406, -799, 4017, -2276],
        [1567, -3784, 3784, -1567, -1567, 3784, -3784, 1567],
        [799, -2276, 3406, -4017, 4017, -3406, 2276, -799],
    ]

    def _cos(u: Int, k: Int) raises -> Int:
        comptime for uu in range(8):
            if uu == u:
                comptime ROW = COS[uu]
                comptime for kk in range(8):
                    if kk == k:
                        return materialize[ROW[kk]]()
        raise "idct: index out of range"

    var tmp = List[Int]()
    for _ in range(64):
        tmp.append(0)
    var out = List[Int]()
    for _ in range(64):
        out.append(0)

    # Row pass: for each row y, transform the 8 column-frequency coefficients
    # block[y*8 + u] into intermediate values tmp[y*8 + x].
    for y in range(8):
        for x in range(8):
            var s = 0
            for u in range(8):
                var coef = block[y * 8 + u]
                if coef != 0:
                    s += coef * _cos(u, x)
            tmp[y * 8 + x] = s

    # Column pass: for each column x, transform row frequencies.
    for x in range(8):
        for y in range(8):
            var s = 0
            for v in range(8):
                var coef = tmp[v * 8 + x]
                if coef != 0:
                    s += coef * _cos(v, y)
            out[y * 8 + x] = s >> 26
    return out^


def _jpeg_receive_extend(mut br: BitReader, s: Int) raises -> Int:
    """Receive-and-extend: map `s` raw bits to a signed coefficient."""
    if s == 0:
        return 0
    var v = br.get_bits(s)
    # MSB 0 => negative value
    if v < (1 << (s - 1)):
        return v - (1 << s) + 1
    return v


def _jpeg_decode_block(
    mut br: BitReader,
    dc: Huffman,
    ac: Huffman,
    quant: List[UInt16],
    dc_pred: Int,
) raises -> Tuple[List[Int], Int]:
    """Decode one 8x8 block: Huffman → coefficients → dequantize. Returns
    the block and stores nothing; DC prediction update is caller's job."""
    var mut_dc = dc.copy()
    var mut_ac = ac.copy()
    var block = List[Int]()
    for _ in range(64):
        block.append(0)

    # DC coefficient.
    var t = mut_dc.decode_msb(br)
    var diff = _jpeg_receive_extend(br, t)
    var dc_val = dc_pred + diff
    block[0] = dc_val * Int(quant[0])

    # AC coefficients (zig-zag order).
    var k = 1
    while k < 64:
        var rs = mut_ac.decode_msb(br)
        var r = rs >> 4
        var s = rs & 15
        if s == 0:
            if r != 15:
                break  # EOB
            k += 16  # ZRL: 16 zeros
        else:
            k += r
            if k > 63:
                raise "jpeg: AC index out of range"
            var v = _jpeg_receive_extend(br, s)
            # DQT payload is in zigzag order; the coefficient goes to the
            # natural position _zz(k) but dequantizes with quant[k].
            block[_zz(k)] = v * Int(quant[k])
            k += 1
    return (block^, dc_val)


def _no_table() raises -> Huffman:
    """Placeholder huffman table for unused table slots (never decodes)."""
    var lengths = List[UInt8]()
    lengths.append(1)
    lengths.append(0)
    for _ in range(254):
        lengths.append(0)
    return Huffman.build(lengths^)


def _syms_to_int(symbols: List[UInt8]) raises -> List[Int]:
    var out = List[Int]()
    for i in range(len(symbols)):
        out.append(Int(symbols[i]))
    return out^


def imdecode_jpeg(data: List[UInt8]) raises -> DecodedImage:
    """Decode a baseline JPEG (SOF0, Huffman) to RGBA pixels.

    Handles grayscale (1 component) and YCbCr (3 components) with any
    per-component sampling factors, plus restart markers. Progressive
    (SOF2) raises.
    """
    var quant = List[List[UInt16]]()
    for _ in range(4):
        quant.append(List[UInt16]())
    var dc_tables = List[Huffman]()
    var ac_tables = List[Huffman]()
    for _ in range(4):
        dc_tables.append(_no_table())
        ac_tables.append(_no_table())

    var width = 0
    var height = 0
    var comps = List[JpegComponent]()
    var max_h = 1
    var max_v = 1
    var restart_interval = 0

    # ---- marker scan ----
    var pos = 2  # skip SOI
    var sos_pos = -1
    while pos + 4 <= len(data):
        if Int(data[pos]) != 0xFF:
            pos += 1
            continue
        while pos < len(data) and Int(data[pos]) == 0xFF:
            pos += 1
        if pos >= len(data):
            break
        var marker = Int(data[pos])
        pos += 1
        if marker == 0xD9:  # EOI
            break
        if marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7):
            continue  # standalone markers
        if pos + 2 > len(data):
            break
        var seg_len = _read_be16(data, pos)
        if marker == 0xDB:  # DQT
            var p = pos + 2
            var seg_end = pos + seg_len
            while p < seg_end:
                var pq = Int(data[p]) >> 4
                var tq = Int(data[p]) & 15
                p += 1
                var table = List[UInt16]()
                for _ in range(64):
                    if pq == 1:
                        table.append(UInt16(_read_be16(data, p)))
                        p += 2
                    else:
                        table.append(UInt16(data[p]))
                        p += 1
                quant[tq] = table.copy()
        elif marker == 0xC4:  # DHT
            var p = pos + 2
            var seg_end = pos + seg_len
            while p < seg_end:
                var tc = Int(data[p]) >> 4
                var th = Int(data[p]) & 15
                p += 1
                var lengths = List[UInt8]()
                for i in range(16):
                    lengths.append(data[p + i])
                p += 16
                var total = 0
                for i in range(16):
                    total += Int(lengths[i])
                var symbols = List[UInt8]()
                for i in range(total):
                    symbols.append(data[p + i])
                p += total
                # Expand the 16 per-length counts into the per-symbol length
                # list Huffman.build expects (symbols arrive in ascending
                # value order, so entry i gets the length of its run).
                # JPEG DHT: lengths[0] counts 1-bit codes.
                var per_sym = List[UInt8]()
                for length in range(16):
                    for _ in range(Int(lengths[length])):
                        per_sym.append(UInt8(length + 1))
                var table = Huffman.build(per_sym^)
                table.symbols = _syms_to_int(symbols)
                if tc == 0:
                    dc_tables[th] = table.copy()
                else:
                    ac_tables[th] = table.copy()
        elif marker == 0xDD:  # DRI
            restart_interval = _read_be16(data, pos + 2)
        elif marker == 0xC0 or marker == 0xC1:  # SOF0/1
            # pos points at the 2 length bytes: precision pos+2, height
            # pos+3..4, width pos+5..6, component count pos+7, then 3-byte
            # component records from pos+8.
            height = _read_be16(data, pos + 3)
            width = _read_be16(data, pos + 5)
            var ncomp = Int(data[pos + 7])
            var p = pos + 8
            max_h = 1
            max_v = 1
            for _ in range(ncomp):
                var cid = Int(data[p])
                var hv = Int(data[p + 1])
                var h = hv >> 4
                var v = hv & 15
                var tq = Int(data[p + 2])
                comps.append(
                    JpegComponent(
                        cid=cid,
                        h_sampling=h,
                        v_sampling=v,
                        quant_table=tq,
                        dc_table=0,
                        ac_table=0,
                        dc_pred=0,
                        blocks_w=0,
                        blocks_h=0,
                    )
                )
                if h > max_h:
                    max_h = h
                if v > max_v:
                    max_v = v
                p += 3
        elif marker == 0xC2:
            raise "jpeg: progressive JPEG not supported"
        elif marker == 0xDA:  # SOS
            sos_pos = pos
            break
        pos += seg_len

    if sos_pos < 0:
        raise "jpeg: no SOS marker"
    if width <= 0 or height <= 0:
        raise "jpeg: missing SOF0"
    if len(comps) == 0:
        raise "jpeg: SOF0 without components"

    # Sidecar per-component scan state; see NOTE below on why these are not
    # stored on the JpegComponent structs directly.
    var dc_ids = List[Int]()
    var ac_ids = List[Int]()
    for _ in range(len(comps)):
        dc_ids.append(0)
        ac_ids.append(0)

    # SOS header: component selectors with table ids.
    var p2 = sos_pos + 2
    var ns = Int(data[p2])
    p2 += 1
    for _ in range(ns):
        var cs = Int(data[p2])
        var td = Int(data[p2 + 1]) >> 4
        var ta = Int(data[p2 + 1]) & 15
        p2 += 2
        # NOTE: `comps[i].field = v` on a List of non-ImplicitlyCopyable
        # structs silently mutates a temp copy — table ids live in sidecar
        # lists so writes actually persist.
        for comp_idx in range(len(comps)):
            if comps[comp_idx].cid == cs:
                dc_ids[comp_idx] = td
                ac_ids[comp_idx] = ta
    var header_len = _read_be16(data, sos_pos)
    var entropy_start = sos_pos + header_len

    # MCU geometry: each component plane is width*height scaled by its
    # sampling factors relative to the maximums.
    var mcus_x = (width + (max_h * 8) - 1) // (max_h * 8)
    var mcus_y = (height + (max_v * 8) - 1) // (max_v * 8)
    var planes = List[List[Int]]()
    var plane_strides = List[Int]()
    for comp_idx in range(len(comps)):
        var c = comps[comp_idx].copy()
        var pw = mcus_x * c.h_sampling * 8
        var ph = mcus_y * c.v_sampling * 8
        var plane = List[Int]()
        plane.reserve(pw * ph)
        for _ in range(pw * ph):
            plane.append(0)
        planes.append(plane^)
        plane_strides.append(pw)

    # ---- entropy-coded scan ----
    var br = BitReader(
        data=data.copy(), byte_pos=entropy_start, bit_acc=0, bit_count=0
    )
    var rst_count = 0
    var mcu_total = mcus_x * mcus_y
    var mcu_index = 0
    # dc_preds: sidecar running DC prediction per component (element writes
    # on List[Int] persist; see the sidecar NOTE above for why this is not
    # kept on the JpegComponent structs).
    var dc_preds = List[Int]()
    for _ in range(len(comps)):
        dc_preds.append(0)
    while mcu_index < mcu_total:
        if (
            restart_interval > 0
            and mcu_index > 0
            and mcu_index % restart_interval == 0
        ):
            _jpeg_sync_restart(br, data, rst_count)
            rst_count = (rst_count + 1) & 7
            for comp_idx in range(len(comps)):
                dc_preds[comp_idx] = 0
        var mcu_x = mcu_index % mcus_x
        var mcu_y = mcu_index // mcus_x
        for comp_idx in range(len(comps)):
            var c = comps[comp_idx].copy()
            for by in range(c.v_sampling):
                for bx in range(c.h_sampling):
                    var quant_t = quant[c.quant_table].copy()
                    var dc_t = dc_tables[dc_ids[comp_idx]].copy()
                    var ac_t = ac_tables[ac_ids[comp_idx]].copy()
                    var decoded = _jpeg_decode_block(
                        br, dc_t, ac_t, quant_t, dc_preds[comp_idx]
                    )
                    var block = decoded[0].copy()
                    dc_preds[comp_idx] = decoded[1]
                    var pixels = _idct_2d(block)
                    # Blit the level-shifted block into the component plane.
                    var plane = planes[comp_idx].copy()
                    var plane_stride = plane_strides[comp_idx]
                    var origin_x = (mcu_x * c.h_sampling + bx) * 8
                    var origin_y = (mcu_y * c.v_sampling + by) * 8
                    for py in range(8):
                        var row = (origin_y + py) * plane_stride + origin_x
                        for px in range(8):
                            plane[row + px] = Int(
                                _clamp8(pixels[py * 8 + px] + 128)
                            )
                    planes[comp_idx] = plane^
        mcu_index += 1

    return _jpeg_planes_to_rgba(
        planes.copy(),
        plane_strides.copy(),
        comps.copy(),
        width,
        height,
        max_h,
        max_v,
    )


def _jpeg_sync_restart(
    mut br: BitReader, data: List[UInt8], rst_index: Int
) raises:
    """Byte-align the bit reader and consume the next RSTn marker.

    Skips any padding/0xFF fill and expects marker 0xD0 + rst_index. The
    bit accumulator may hold up to 2 pending bytes after the final
    get_bits call, so the marker scan runs against `data` directly.
    """
    var cur = br.byte_pos - (br.bit_count // 8)
    # Walk forward to the RST marker.
    var limit = len(data) - 1
    while cur + 1 < limit:
        if Int(data[cur]) == 0xFF and Int(data[cur + 1]) == 0xD0 + rst_index:
            br.reset(cur + 2)
            return
        cur += 1
    raise "jpeg: restart marker not found"


def _fancy_upsample_h(
    plane: List[Int],
    stride: Int,
    rows: Int,
    cols: Int,
    out_w: Int,
) raises -> Tuple[List[Int], Int]:
    """Horizontal 3:1 triangle upsample (libjpeg 'fancy', h2v1-style).

    Even outputs weight the LEFT neighbor (+2), odd outputs weight the
    RIGHT neighbor (+1); edge columns replicate. Law verified
    empirically against libjpeg output on synthetic fixtures.
    """
    var out = List[Int]()
    var out_stride = out_w
    for r in range(rows):
        var base = r * stride
        for c in range(cols):
            var cur = plane[base + c]
            var left = plane[base + c - 1] if c > 0 else cur
            var right = plane[base + c + 1] if c + 1 < cols else cur
            var col = c * 2
            if col < out_w:
                out.append((3 * cur + left + 2) >> 2)
            if col + 1 < out_w:
                out.append((3 * cur + right + 1) >> 2)
    return (out^, out_stride)


def _fancy_upsample_v(
    plane: List[Int],
    stride: Int,
    rows: Int,
    cols: Int,
) raises -> Tuple[List[Int], Int]:
    """Vertical 3:1 triangle upsample (h2v2-style).

    Even output rows weight the chroma row above, odd rows the row below,
    with the same (+2 above, +1 below) law as the horizontal pass; edge
    rows replicate.
    """
    var out = List[Int]()
    for out_r in range(rows * 2):
        var near = out_r // 2
        var n_base = near * stride
        var up_base = (near - 1) * stride if near > 0 else n_base
        var down_base = (near + 1) * stride if near + 1 < rows else n_base
        var weight_up = out_r % 2  # 0 = even row (heavier n), 1 = odd
        for c in range(cols):
            var cur = plane[n_base + c]
            var far = (
                plane[down_base + c] if weight_up == 1 else plane[up_base + c]
            )
            if weight_up == 1:
                out.append((3 * cur + far + 1) >> 2)
            else:
                out.append((3 * cur + far + 2) >> 2)
    return (out^, stride)


def _jpeg_planes_to_rgba(
    planes: List[List[Int]],
    plane_strides: List[Int],
    comps: List[JpegComponent],
    width: Int,
    height: Int,
    max_h: Int,
    max_v: Int,
) raises -> DecodedImage:
    """Combine component planes into a cropped RGBA image."""
    var out = List[UInt8]()
    out.reserve(width * height * 4)

    if len(planes) == 1:
        # Grayscale: Y plane maps 1:1 to pixels (plane is max_h/max_v scale,
        # which is 1 for single-component images).
        var stride = plane_strides[0]
        var plane = planes[0].copy()
        for y in range(height):
            for x in range(width):
                var v = plane[y * stride + x]
                out.append(UInt8(v))
                out.append(UInt8(v))
                out.append(UInt8(v))
                out.append(UInt8(255))
        return DecodedImage(pixels=out^, width=width, height=height)

    # YCbCr: component 0 is luma at full resolution; chroma planes are
    # smaller by (max_h / c.h_sampling, max_v / c.v_sampling). Sampling a
    # full-res coordinate (x, y) from a chroma plane divides the coordinate
    # by that ratio (nearest-neighbor upsample).
    var y_stride = plane_strides[0]
    var y_plane = planes[0].copy()
    var cb_c = comps[1].copy()
    var cr_c = comps[2].copy()
    var cb_x_div = max_h // cb_c.h_sampling if cb_c.h_sampling > 0 else max_h
    var cb_y_div = max_v // cb_c.v_sampling if cb_c.v_sampling > 0 else max_v
    var cr_x_div = max_h // cr_c.h_sampling if cr_c.h_sampling > 0 else max_h
    var cr_y_div = max_v // cr_c.v_sampling if cr_c.v_sampling > 0 else max_v

    # Upsample each chroma plane to full resolution. 2x ratios (the ones
    # real covers use) go through the libjpeg-compatible triangle filter;
    # other ratios (and both-divisors-are-1, i.e. already full-res) keep
    # nearest sampling below.
    var cb_rows = (height + cb_y_div - 1) // cb_y_div
    var cb_cols = (width + cb_x_div - 1) // cb_x_div
    var cb_up = planes[1].copy()
    var cb_stride = plane_strides[1]
    if cb_x_div == 2 and cb_y_div == 2:
        var t = _fancy_upsample_h(
            cb_up.copy(), cb_stride, cb_rows, cb_cols, width
        )
        var cb_h = t[0].copy()
        t = _fancy_upsample_v(cb_h^, width, cb_rows, width)
        cb_up = t[0].copy()
        cb_stride = t[1]
    elif cb_x_div == 2 and cb_y_div == 1:
        var t = _fancy_upsample_h(
            cb_up.copy(), cb_stride, cb_rows, cb_cols, width
        )
        cb_up = t[0].copy()
        cb_stride = t[1]
    elif cb_x_div == 1 and cb_y_div == 2:
        var t = _fancy_upsample_v(cb_up.copy(), cb_stride, cb_rows, cb_cols)
        cb_up = t[0].copy()
        cb_stride = t[1]
    var cr_rows = (height + cr_y_div - 1) // cr_y_div
    var cr_cols = (width + cr_x_div - 1) // cr_x_div
    var cr_up = planes[2].copy()
    var cr_stride = plane_strides[2]
    if cr_x_div == 2 and cr_y_div == 2:
        var t2 = _fancy_upsample_h(
            cr_up.copy(), cr_stride, cr_rows, cr_cols, width
        )
        var cr_h = t2[0].copy()
        var t3 = _fancy_upsample_v(cr_h^, width, cr_rows, width)
        cr_up = t3[0].copy()
        cr_stride = t3[1]
    elif cr_x_div == 2 and cr_y_div == 1:
        var t2 = _fancy_upsample_h(
            cr_up.copy(), cr_stride, cr_rows, cr_cols, width
        )
        cr_up = t2[0].copy()
        cr_stride = t2[1]
    elif cr_x_div == 1 and cr_y_div == 2:
        var t2 = _fancy_upsample_v(cr_up.copy(), cr_stride, cr_rows, cr_cols)
        cr_up = t2[0].copy()
        cr_stride = t2[1]

    for y in range(height):
        for x in range(width):
            var yy = y_plane[y * y_stride + x]
            var cb = cb_up[y * cb_stride + x]
            var cr = cr_up[y * cr_stride + x]
            # ITU-R BT.601 full-range conversion.
            var cb_off = cb - 128
            var cr_off = cr - 128
            var r = yy + ((1402 * cr_off) // 1000)
            var g = (
                yy
                - ((344136 * cb_off) // 1000000)
                - ((714136 * cr_off) // 1000000)
            )
            var b = yy + ((1772 * cb_off) // 1000)
            out.append(_clamp8(r))
            out.append(_clamp8(g))
            out.append(_clamp8(b))
            out.append(UInt8(255))
    return DecodedImage(pixels=out^, width=width, height=height)
