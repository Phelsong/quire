# platform/text.mojo — FreeType-based text rendering for Quire.
#
# external_call layer over libfreetype.so.6 (26.x), baking
# per-size glyph atlases at load time (same FontSet 13-size pattern as the
# old ui/font.mojo).
#
# Approach:
#   TextEngine.init(font_path) -> 1 FT_Library + FT_Face (shared; sizes set
#   per bake via FT_Set_Pixel_Sizes).
#   bake_atlas(pixel_size, codepoints) -> TextAtlas:
#     for each codepoint: FT_Load_Glyph(LOAD_RENDER) into slot, copy the
#     8-bit gray bitmap into a packed atlas row-layout buffer, record
#     per-glyph metrics (bearing, advance, atlas rect).
#   Atlas is ONE big RGBA bitmap (BGRX, alpha = coverage) in a single
#   malloc block — uploaded at draw time by Canvas.blit_mask per glyph row.
#
# Glyph placement rule (matches raster conventions):
#   pen origin at baseline; bitmap drawn at (pen_x + bitmap_left,
#   baseline_y - bitmap_top); advance from glyph metrics.horiAdvance / 64.
#
# Text measurement: sum of advances (round 26.6 → px). Kerning ignored
# (mono font — CaskaydiaCove — so kerning is ~0 anyway).

from std.ffi import external_call
from std.collections import Optional
from std.memory import stack_allocation
from std.memory.unsafe_pointer import Pointer

from platform.ffi import c_null as _null
from platform.ffi import cstr as _cstr
from platform.ffi import heap_malloc as _malloc


# ---------------------------------------------------------------------------
# FreeType constants (freetype.h / ftimage.h)
# ---------------------------------------------------------------------------

comptime FT_LOAD_RENDER = 4  # (1L << 2)
comptime FT_PIXEL_MODE_GRAY = 2
comptime FT_RENDER_MODE_NORMAL = 0

# FT_GlyphSlotRec / FT_FaceRec / FT_SizeRec field offsets (64-bit x86_64,
# verified with offsetofprobe gcc run — see /tmp/opencode/ftoffsetof.c):
comptime OFF_FACE_GLYPH = 152
comptime OFF_FACE_SIZE = 160
comptime OFF_SIZE_METRICS = 24
comptime OFF_METRICS_X_PPEM = 0  # within FT_Size_Metrics
comptime OFF_METRICS_Y_PPEM = 2
comptime OFF_SLOT_METRICS = 48
comptime OFF_SLOT_BITMAP = 152
comptime OFF_SLOT_BITMAP_LEFT = 192
comptime OFF_SLOT_BITMAP_TOP = 196
comptime OFF_BMP_ROWS = 0
comptime OFF_BMP_WIDTH = 4
comptime OFF_BMP_PITCH = 8
comptime OFF_BMP_BUFFER = 16
comptime OFF_BMP_PIXEL_MODE = 26
comptime OFF_MET_WIDTH = 0  # within FT_Glyph_Metrics
comptime OFF_MET_HEIGHT = 8
comptime OFF_MET_BEARING_X = 16
comptime OFF_MET_BEARING_Y = 24
comptime OFF_MET_ADVANCE = 32

# ---------------------------------------------------------------------------
# FreeType FFI
# ---------------------------------------------------------------------------


def ft_init() -> Pointer[NoneType, MutUntrackedOrigin]:
    """FT_Init_FreeType; returns library ptr or NULL."""
    var lib_ptr = stack_allocation[1, Pointer[NoneType, MutUntrackedOrigin]]()
    var rc = external_call["FT_Init_FreeType", Int32](lib_ptr)
    if rc != 0:
        return _null[NoneType]()
    return lib_ptr[unsafe_offset=0]


def ft_new_face(
    lib: Pointer[NoneType, MutUntrackedOrigin], mut path: String
) -> Pointer[NoneType, MutUntrackedOrigin]:
    var face_ptr = stack_allocation[1, Pointer[NoneType, MutUntrackedOrigin]]()
    var rc = external_call["FT_New_Face", Int32](
        lib, _cstr(path), UInt64(0), face_ptr
    )
    if rc != 0:
        return _null[NoneType]()
    return face_ptr[unsafe_offset=0]


def ft_set_pixel_sizes(
    face: Pointer[NoneType, MutUntrackedOrigin], px: UInt32
) -> Int32:
    return external_call["FT_Set_Pixel_Sizes", Int32](
        face, UInt64(0), UInt64(px)
    )


def ft_get_char_index(
    face: Pointer[NoneType, MutUntrackedOrigin], codepoint: UInt32
) -> UInt32:
    return external_call["FT_Get_Char_Index", UInt32](face, codepoint)


def ft_load_glyph(
    face: Pointer[NoneType, MutUntrackedOrigin], index: UInt32
) -> Int32:
    return external_call["FT_Load_Glyph", Int32](
        face, index, UInt64(FT_LOAD_RENDER)
    )


def ft_done_face(face: Pointer[NoneType, MutUntrackedOrigin]):
    external_call["FT_Done_Face", NoneType](face)


def ft_done_library(lib: Pointer[NoneType, MutUntrackedOrigin]):
    external_call["FT_Done_FreeType", NoneType](lib)


# --- raw memory readers (little-endian x86_64) for FT struct field access ---


def read_u32_at(addr: Int) -> UInt32:
    var p = Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=addr)
    return p[unsafe_offset=0]


def read_i32_at(addr: Int) -> Int32:
    var p = Pointer[Int32, MutUntrackedOrigin](unsafe_from_address=addr)
    return p[unsafe_offset=0]


def read_i64_at(addr: Int) -> Int:
    var p = Pointer[Int64, MutUntrackedOrigin](unsafe_from_address=addr)
    return Int(p[unsafe_offset=0])


# ---------------------------------------------------------------------------
# Glyph data
# ---------------------------------------------------------------------------


struct GlyphInfo(Copyable, Movable):
    var codepoint: Int32
    var bitmap_x: Int32  # atlas placement
    var bitmap_y: Int32
    var bitmap_w: Int32  # atlas width/height in px
    var bitmap_h: Int32
    var bearing_x: Int32  # dist from pen to glyph left
    var bearing_y: Int32  # dist from baseline to glyph top
    var advance_px: Int32  # pen advance in px (26.6 rounded)

    def __init__(out self):
        self.codepoint = 0
        self.bitmap_x = 0
        self.bitmap_y = 0
        self.bitmap_w = 0
        self.bitmap_h = 0
        self.bearing_x = 0
        self.bearing_y = 0
        self.advance_px = 0

    def __copyinit__(mut self, existing: Self):
        self.codepoint = existing.codepoint
        self.bitmap_x = existing.bitmap_x
        self.bitmap_y = existing.bitmap_y
        self.bitmap_w = existing.bitmap_w
        self.bitmap_h = existing.bitmap_h
        self.bearing_x = existing.bearing_x
        self.bearing_y = existing.bearing_y
        self.advance_px = existing.advance_px


# Atlas layout: single row of glyphs (line atlas). Width = sum(bw + pad),
# height = max(bh). ASCII-only (95 glyphs + bullet + check) so a row is fine
# (96 * ~48px = ~4.6k px wide worst case at size 96 — under 8k texture limit
# if we ever upload, but we draw by sampling the mask buffer directly, so
# no hardware limit matters).
comptime ATLAS_PAD = 2


struct TextAtlas(Copyable, Movable):
    """Baked glyphs for ONE pixel size."""

    var codepoints: List[Int32]  # parallel to glyphs
    var glyphs: List[GlyphInfo]
    var mask: Optional[
        Pointer[UInt8, MutUntrackedOrigin]
    ]  # 8-bit coverage atlas
    var atlas_w: Int
    var atlas_h: Int
    var pixel_size: Int32
    # font metrics for this size (px)
    var ascent: Int32  # max bitmap_top over glyphs (approximate ascender)
    var descent: Int32  # max (bitmap_h - bitmap_top) below baseline
    var line_height: Int32

    def __init__(out self):
        self.codepoints = List[Int32]()
        self.glyphs = List[GlyphInfo]()
        self.mask = _null[UInt8]()
        self.atlas_w = 0
        self.atlas_h = 0
        self.pixel_size = 0
        self.ascent = 0
        self.descent = 0
        self.line_height = 0

    def __copyinit__(mut self, existing: Self):
        self.codepoints = List[Int32]()
        for i in range(existing.codepoints.__len__()):
            self.codepoints.append(existing.codepoints[i])
        self.glyphs = List[GlyphInfo]()
        for i in range(existing.glyphs.__len__()):
            self.glyphs.append(existing.glyphs[i].copy())
        self.mask = existing.mask
        self.atlas_w = existing.atlas_w
        self.atlas_h = existing.atlas_h
        self.pixel_size = existing.pixel_size
        self.ascent = existing.ascent
        self.descent = existing.descent
        self.line_height = existing.line_height

    def close(mut self):
        """Free the mask buffer (heap-allocated at bake)."""
        if self.mask:
            external_call["free", NoneType](self.mask.value())
        self.mask = Optional[Pointer[UInt8, MutUntrackedOrigin]]()

    def find_glyph(mut self, codepoint: Int32) -> Int:
        """Index into glyphs or -1 if not baked."""
        var n = self.codepoints.__len__()
        for i in range(n):
            if self.codepoints[i] == codepoint:
                return i
        return -1

    def text_width(mut self, mut text: String) -> Int:
        """Advance-width in pixels. Walks UTF-8 CODEPOINTS (not bytes) so
        multi-byte glyphs (Nerd Font PUA icons) measure as one glyph."""
        var total = 0
        var bytes = text.as_bytes()
        var i = 0
        var n = len(bytes)
        while i < n:
            var b = bytes[i]
            # Widen to Int32 BEFORE shifting: UInt8 shift-or wraps 8-bit and
            # destroys multi-byte codepoints (3 << 18 == 0 in 8-bit).
            var cp = Int32(b)
            var seq = 1
            if b >= 0xF0:
                cp = Int32(b & 0x07)
                cp <<= 18
                if i + 1 < n:
                    cp |= Int32(bytes[i + 1] & 0x3F) << 12
                if i + 2 < n:
                    cp |= Int32(bytes[i + 2] & 0x3F) << 6
                if i + 3 < n:
                    cp |= Int32(bytes[i + 3] & 0x3F)
                seq = 4
            elif b >= 0xE0:
                cp = Int32(b & 0x0F)
                cp <<= 12
                if i + 1 < n:
                    cp |= Int32(bytes[i + 1] & 0x3F) << 6
                if i + 2 < n:
                    cp |= Int32(bytes[i + 2] & 0x3F)
                seq = 3
            elif b >= 0xC0:
                cp = Int32(b & 0x1F)
                cp <<= 6
                if i + 1 < n:
                    cp |= Int32(bytes[i + 1] & 0x3F)
                seq = 2
            var idx = self.find_glyph(cp)
            if idx >= 0:
                var g = self.glyphs[idx].copy()
                total += g_advance(g)
            else:
                # fallback: ~half advance of 'M' or 12px
                total += Int(self.pixel_size) // 2
            i += seq
        return total

    def text_height(mut self) -> Int:
        return Int(self.line_height)


def g_advance(g: GlyphInfo) -> Int:
    return Int(g.advance_px)


# ---------------------------------------------------------------------------
# TextEngine
# ---------------------------------------------------------------------------


struct TextEngine(Copyable, Movable):
    var lib: Optional[Pointer[NoneType, MutUntrackedOrigin]]
    var face: Optional[Pointer[NoneType, MutUntrackedOrigin]]
    var ok: Bool

    def __init__(out self):
        self.lib = Optional[Pointer[NoneType, MutUntrackedOrigin]]()
        self.face = Optional[Pointer[NoneType, MutUntrackedOrigin]]()
        self.ok = False

    def __copyinit__(mut self, existing: Self):
        self.lib = existing.lib
        self.face = existing.face
        self.ok = existing.ok

    def init_engine(mut self, mut font_path: String) raises:
        self.lib = Optional[Pointer[NoneType, MutUntrackedOrigin]](ft_init())
        if not self.lib:
            raise Error("freetype: FT_Init_FreeType failed")
        self.face = Optional[Pointer[NoneType, MutUntrackedOrigin]](
            ft_new_face(self.lib.value(), font_path)
        )
        if not self.face:
            raise Error("freetype: failed to load font '" + font_path + "'")
        self.ok = True

    def close(mut self):
        if self.face:
            ft_done_face(self.face.value())
            self.face = Optional[Pointer[NoneType, MutUntrackedOrigin]]()
        if self.lib:
            ft_done_library(self.lib.value())
            self.lib = Optional[Pointer[NoneType, MutUntrackedOrigin]]()
        self.ok = False

    def bake_atlas(
        mut self, pixel_size: Int32, mut codepoints: List[Int32]
    ) raises -> TextAtlas:
        """Bake an atlas for one pixel size. Caller owns the returned atlas
        (close() to free the mask buffer)."""
        if not self.ok:
            raise Error("freetype: engine not initialized")
        var face = self.face.value()
        var rc = ft_set_pixel_sizes(face, UInt32(pixel_size))
        if rc != 0:
            raise Error(
                "freetype: FT_Set_Pixel_Sizes("
                + String(pixel_size)
                + ") failed"
            )

        var atlas = TextAtlas()
        atlas.pixel_size = pixel_size

        # First pass: load each glyph to measure widths/heights.
        var total_w = 0
        var max_h = 0
        var n = codepoints.__len__()
        for i in range(n):
            var cp_codepoint = Int32(codepoints[i])
            var gindex = ft_get_char_index(face, UInt32(cp_codepoint))
            if gindex == 0:
                # missing glyph — record a zero-size stub so lookups stay aligned
                var gi = GlyphInfo()
                gi.codepoint = cp_codepoint
                gi.bitmap_x = 0
                gi.bitmap_y = 0
                gi.bitmap_w = 0
                gi.bitmap_h = 0
                gi.advance_px = pixel_size // 2
                atlas.codepoints.append(cp_codepoint)
                atlas.glyphs.append(gi.copy())
                continue

            var rc2 = ft_load_glyph(face, gindex)
            if rc2 != 0:
                var gi = GlyphInfo()
                gi.advance_px = pixel_size // 2
                atlas.codepoints.append(cp_codepoint)
                atlas.glyphs.append(gi.copy())
                continue

            # read glyph slot fields (slot is a POINTER field: read ptr value)
            var slot_addr = 0
            var sp = Pointer[UInt64, MutUntrackedOrigin](
                unsafe_from_address=Int(face) + OFF_FACE_GLYPH
            )
            slot_addr = Int(sp[unsafe_offset=0])
            if slot_addr == 0:
                var gi = GlyphInfo()
                gi.advance_px = pixel_size // 2
                atlas.codepoints.append(cp_codepoint)
                atlas.glyphs.append(gi.copy())
                continue

            var metrics_addr = slot_addr + OFF_SLOT_METRICS
            var advance = read_i64_at(metrics_addr + OFF_MET_ADVANCE)  # 26.6
            var adv_px = (advance + 32) // 64

            var bmp_addr = slot_addr + OFF_SLOT_BITMAP
            var rows = read_u32_at(bmp_addr + OFF_BMP_ROWS)
            var width = read_u32_at(bmp_addr + OFF_BMP_WIDTH)
            var pitch = read_i32_at(bmp_addr + OFF_BMP_PITCH)

            var gi = GlyphInfo()
            gi.codepoint = cp_codepoint
            gi.advance_px = Int32(adv_px)
            gi.bearing_x = Int32(
                read_i64_at(slot_addr + OFF_SLOT_METRICS + OFF_MET_BEARING_X)
                // 64
            )
            gi.bearing_y = Int32(
                read_i64_at(slot_addr + OFF_SLOT_METRICS + OFF_MET_BEARING_Y)
                // 64
            )
            gi.bitmap_w = Int32(width)
            gi.bitmap_h = Int32(rows)

            # reserve atlas slot (single-row layout)
            gi.bitmap_x = Int32(total_w)
            gi.bitmap_y = 0
            total_w += Int(width) + ATLAS_PAD
            if Int(rows) > max_h:
                max_h = Int(rows)

            atlas.codepoints.append(cp_codepoint)
            atlas.glyphs.append(gi.copy())

        # Second pass: copy bitmaps into the packed atlas.
        atlas.atlas_w = total_w
        atlas.atlas_h = max_h
        var mask_size = total_w * max_h
        if mask_size > 0:
            atlas.mask = Optional[Pointer[UInt8, MutUntrackedOrigin]](
                Pointer[UInt8, MutUntrackedOrigin](
                    unsafe_from_address=Int(_malloc(mask_size))
                )
            )
            # zero
            for i in range(mask_size):
                atlas.mask.value()[unsafe_offset=i] = 0

            for i in range(n):
                var gi = atlas.glyphs[i].copy()
                if gi.bitmap_w == 0 or gi.bitmap_h == 0:
                    continue
                # reload glyph (slot content may be stale from earlier loop)
                var gindex = ft_get_char_index(face, UInt32(gi.codepoint))
                if gindex == 0:
                    continue
                _ = ft_load_glyph(face, gindex)
                var sp = Pointer[UInt64, MutUntrackedOrigin](
                    unsafe_from_address=Int(face) + OFF_FACE_GLYPH
                )
                var slot_addr = Int(sp[unsafe_offset=0])
                if slot_addr == 0:
                    continue
                var bmp_addr = slot_addr + OFF_SLOT_BITMAP
                var rows = Int(read_u32_at(bmp_addr + OFF_BMP_ROWS))
                var width = Int(read_u32_at(bmp_addr + OFF_BMP_WIDTH))
                var pitch = Int(read_i32_at(bmp_addr + OFF_BMP_PITCH))
                var buf_ptr = Pointer[UInt64, MutUntrackedOrigin](
                    unsafe_from_address=bmp_addr + OFF_BMP_BUFFER
                )
                var src = Int(buf_ptr[unsafe_offset=0])
                if src == 0:
                    continue
                var src_bytes = Pointer[UInt8, MutUntrackedOrigin](
                    unsafe_from_address=src
                )
                var dst_x = Int(gi.bitmap_x)
                for yy in range(rows):
                    for xx in range(width):
                        var cov = src_bytes[unsafe_offset=yy * pitch + xx]
                        atlas.mask.value()[
                            unsafe_offset=yy * total_w + dst_x + xx
                        ] = cov

        # font metrics for the atlas (max bitmap_top = ascent proxy)
        var max_top = 0
        var max_below = 0
        for i in range(atlas.glyphs.__len__()):
            var gi = atlas.glyphs[i].copy()
            if Int(gi.bearing_y) > max_top:
                max_top = Int(gi.bearing_y)
            var below = Int(gi.bitmap_h) - Int(gi.bearing_y)
            if below > max_below:
                max_below = below
        atlas.ascent = Int32(max_top)
        atlas.descent = Int32(max_below)
        atlas.line_height = Int32(max_top + max_below + 2)

        return atlas^
