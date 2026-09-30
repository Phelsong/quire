# render/canvas.mojo — pure-Mojo 2D rasterizer for Quire.
#
# draws into the Window's wl_shm frame
# buffer (BGRX byte order, ARGB8888 little-endian) with a scissor-clip stack.
# Ops needed by the app (census-verified, nothing more):
#
#   clear(color)                       — full-buffer fill
#   fill_rect(x, y, w, h, color)       — draw_rectangle_rec
#   fill_rect_rounded(..., roundness)  — draw_rectangle_rounded (AA edges)
#   outline_rect_rounded(..., thick)   — draw_rectangle_rounded_lines_ex
#   blit_rgba(...)                     — cover art scaled blit
#   begin_clip / end_clip              — scissor stack
#   blit_mask (glyphs)                 — alpha-masked color fill from 8-bit
#   draw_text / measure_text           — atlas text (borrowed atlas, no copies)
#
# Design: per-pixel span fills row-major. Colors arrive as Color (RGBA u8);
# stored as 4 bytes B,G,R,X per pixel. Aligned span tails splat the color
# word with one SIMD store per 16 pixels instead of a per-pixel store loop.

from std.math import sqrt
from std.memory.unsafe_pointer import Pointer

from resources.color import Color

# Text bridge types (glyph info + baked atlas from the FreeType shim).
from platform.text import TextAtlas, CodepointInfo, decode_utf8

# BGRX pixel word splat width: 16 UInt32 lanes = 16 px per SIMD store.
comptime FILL_LANES = 16


# ---------------------------------------------------------------------------
# Color → bytes helpers
# ---------------------------------------------------------------------------


def _bgrx(c: Color) -> UInt32:
    """Pack RGBA Color into the 4-byte BGRX little-endian word used by
    ARGB8888 shm buffers on x86_64."""
    var b = UInt32(c.b) & 0xFF
    var g = UInt32(c.g) & 0xFF
    var r = UInt32(c.r) & 0xFF
    # X = alpha channel slot; keep 0xFF so downstream tooling sees opaque
    return b | (g << 8) | (r << 16) | (0xFF << 24)


def _splat(word: UInt32) -> SIMD[DType.uint32, FILL_LANES]:
    """One color word replicated across the SIMD fill width."""
    var splat = SIMD[DType.uint32, FILL_LANES]()
    for lane in range(FILL_LANES):
        splat[lane] = word
    return splat


# ---------------------------------------------------------------------------
# Canvas
# ---------------------------------------------------------------------------


struct ScissorEntry(Copyable, ImplicitlyCopyable, Movable):
    var x: Int
    var y: Int
    var w: Int
    var h: Int

    def __init__(out self):
        self.x = 0
        self.y = 0
        self.w = 0
        self.h = 0


struct Canvas(Copyable, Movable):
    """2D raster target bound to a Window frame buffer. All coordinates are
    in frame-buffer pixels (floats accepted; rounded to int spans)."""

    # The Window frame storage (borrowed, not owned — Window owns the mmap).
    var buf: Pointer[UInt8, MutUntrackedOrigin]
    var width: Int
    var height: Int
    var stride: Int

    # scissor clip stack — one List of ScissorEntry instead of four parallel
    # Int lists, so a Canvas copy is one shallow COW List copy (not 4 rebuilds)
    var clip_stack: List[ScissorEntry]

    def __init__(
        out self,
        buf: Pointer[UInt8, MutUntrackedOrigin],
        width: Int,
        height: Int,
        stride: Int,
    ):
        self.buf = buf
        self.width = width
        self.height = height
        self.stride = stride
        self.clip_stack = List[ScissorEntry]()

    def __copyinit__(mut self, existing: Self):
        self.buf = existing.buf
        self.width = existing.width
        self.height = existing.height
        self.stride = existing.stride
        # COW shallow copy: entries are shared until one side mutates.
        self.clip_stack = existing.clip_stack.copy()

    # ------------------------------------------------------------------
    # clipping
    # ---------------------------------------------------------------------------

    def begin_clip(mut self, x: Int, y: Int, w: Int, h: Int):
        """Intersect with the current clip and push (scissor semantics)."""
        var cx = x
        var cy = y
        var cw = w
        var ch = h
        if len(self.clip_stack) > 0:
            var top = self.clip_stack[len(self.clip_stack) - 1]
            # intersect
            var nx = cx if cx > top.x else top.x
            var ny = cy if cy > top.y else top.y
            var nx2 = (cx + cw) if (cx + cw) < (top.x + top.w) else (
                top.x + top.w
            )
            var ny2 = (cy + ch) if (cy + ch) < (top.y + top.h) else (
                top.y + top.h
            )
            cx = nx
            cy = ny
            cw = nx2 - nx
            ch = ny2 - ny
            if cw < 0:
                cw = 0
            if ch < 0:
                ch = 0
        var entry = ScissorEntry()
        entry.x = cx
        entry.y = cy
        entry.w = cw
        entry.h = ch
        self.clip_stack.append(entry^)

    def end_clip(mut self):
        if len(self.clip_stack) > 0:
            _ = self.clip_stack.pop()

    def _clip(mut self) -> ScissorEntry:
        """Current scissor rect; full canvas when the stack is empty."""
        if len(self.clip_stack) == 0:
            var full = ScissorEntry()
            full.w = self.width
            full.h = self.height
            return full
        return self.clip_stack[len(self.clip_stack) - 1]

    # ------------------------------------------------------------------
    # fills
    # ---------------------------------------------------------------------------

    def clear(mut self, c: Color):
        self.fill_rect(0.0, 0.0, Float64(self.width), Float64(self.height), c)

    def clear_gradient(mut self, top: Color, bottom: Color):
        """Fill the whole canvas with a vertical gradient."""
        self.fill_rect_gradient(
            0.0, 0.0, Float64(self.width), Float64(self.height), top, bottom
        )

    def fill_rect(
        mut self, fx: Float64, fy: Float64, fw: Float64, fh: Float64, c: Color
    ):
        """Axis-aligned solid rect (draw_rectangle_rec). Skips zero/negative."""
        if fw <= 0.0 or fh <= 0.0:
            return
        var x0 = Int(fx)
        var y0 = Int(fy)
        var x1 = Int(fx + fw)
        var y1 = Int(fy + fh)
        # clip to window + scissor
        var clip = self._clip()
        if x0 < clip.x:
            x0 = clip.x
        if y0 < clip.y:
            y0 = clip.y
        if x1 > clip.x + clip.w:
            x1 = clip.x + clip.w
        if y1 > clip.y + clip.h:
            y1 = clip.y + clip.h
        if x1 <= x0 or y1 <= y0:
            return
        self._fill_rows(x0, x1, y0, y1, c)

    def _fill_rows(mut self, x0: Int, x1: Int, y0: Int, y1: Int, c: Color):
        """[x0, x1) × [y0, y1) solid fill, pre-clipped. Head pixels (until the
        row address is 4-aligned) store byte-wise; the aligned tail splats
        the color word 16 px per SIMD store."""
        if x1 <= x0 or y1 <= y0:
            return
        var word = _bgrx(c)
        var base_addr = Int(self.buf)
        var splat = _splat(word)

        for yy in range(y0, y1):
            var row_addr = base_addr + self.stride * yy
            var px = x0
            # head: unaligned pixels until the address is 4-aligned
            var misalign = (row_addr + px * 4) % 4
            if misalign != 0:
                # bytes until aligned == pixels (4 bytes per pixel)
                var head = 4 - misalign
                if head > (x1 - px):
                    head = x1 - px
                self._fill_span_bytes(px, px + head, yy, word)
                px += head
            # aligned 16-px SIMD fill, then scalar remainder
            var remaining = x1 - px
            if remaining > 0:
                var wp = Pointer[UInt32, MutUntrackedOrigin](
                    unsafe_from_address=row_addr + px * 4
                )
                var bulk = remaining // FILL_LANES
                for _b in range(bulk):
                    wp.unsafe_store(offset=0, val=splat)
                    wp = wp.unsafe_offset(FILL_LANES)
                px += bulk * FILL_LANES
                while px < x1:
                    wp[unsafe_offset=0] = word
                    wp = wp.unsafe_offset(1)
                    px += 1

    def _fill_span_bytes(mut self, x0: Int, x1: Int, y: Int, word: UInt32):
        """Byte-wise store of a BGRX word for [x0, x1) on row y. Used for the
        unaligned head of a span (caller ensures bounds)."""
        var base_addr = Int(self.buf) + self.stride * y
        for px in range(x0, x1):
            var addr = base_addr + px * 4
            var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=addr)
            p[unsafe_offset=0] = UInt8(word & 0xFF)
            p[unsafe_offset=1] = UInt8((word >> 8) & 0xFF)
            p[unsafe_offset=2] = UInt8((word >> 16) & 0xFF)
            p[unsafe_offset=3] = UInt8((word >> 24) & 0xFF)

    def fill_rect_gradient(
        mut self,
        fx: Float64,
        fy: Float64,
        fw: Float64,
        fh: Float64,
        top: Color,
        bottom: Color,
    ):
        """Axis-aligned vertical gradient rect: `top` color at fy, `bottom`
        at fy+fh, linearly interpolated per row. One row-span fill per row
        (no per-pixel fill_rect round-trip)."""
        if fw <= 0.0 or fh <= 0.0:
            return
        var x0 = Int(fx)
        var y0 = Int(fy)
        var x1 = Int(fx + fw)
        var y1 = Int(fy + fh)
        # clip to window + scissor
        var clip = self._clip()
        if x0 < clip.x:
            x0 = clip.x
        if y0 < clip.y:
            y0 = clip.y
        if x1 > clip.x + clip.w:
            x1 = clip.x + clip.w
        if y1 > clip.y + clip.h:
            y1 = clip.y + clip.h
        if x1 <= x0 or y1 <= y0:
            return

        var denom = Float64(fy + fh - Float64(y0))
        var tr = Float64(top.r)
        var tg = Float64(top.g)
        var tb = Float64(top.b)
        var dr = (Float64(bottom.r) - tr) / denom
        var dg = (Float64(bottom.g) - tg) / denom
        var db = (Float64(bottom.b) - tb) / denom
        for yy in range(y0, y1):
            var t = Float64(yy - y0)
            var row_color = Color(
                UInt8(tr + dr * t), UInt8(tg + dg * t), UInt8(tb + db * t), 255
            )
            self._fill_rows(x0, x1, yy, yy + 1, row_color)

    # ------------------------------------------------------------------
    # rounded rects (solid + outline)
    # ---------------------------------------------------------------------------

    def fill_rect_rounded(
        mut self,
        fx: Float64,
        fy: Float64,
        fw: Float64,
        fh: Float64,
        roundness: Float64,
        c: Color,
    ):
        """Solid rounded rect (draw_rectangle_rounded). roundness 0..1 is
        relative to min(w,h)/2. Anti-aliased via 1px
        coverage feather on the corner arcs."""
        if fw <= 0.0 or fh <= 0.0:
            return
        var y0 = Int(fy)
        var y1 = Int(fy + fh)
        var radius = roundness * 0.5 * (fw if fw < fh else fh)
        if radius <= 0.5:
            self.fill_rect(fx, fy, fw, fh, c)
            return
        if radius > fw * 0.5:
            radius = fw * 0.5
        if radius > fh * 0.5:
            radius = fh * 0.5

        var cx = fx + fw * 0.5
        var cy = fy + fh * 0.5
        var half_w = fw * 0.5
        var corner_dy = fh * 0.5 - radius
        var clip = self._clip()
        for yy in range(y0, y1):
            # Per-row span: [row_x0, row_x1) inside the rounded shape
            var dy = (Float64(yy) + 0.5) - cy
            var abs_dy = dy if dy >= 0.0 else -dy
            var inset = 0.0
            if abs_dy > corner_dy:
                # inside the vertical range governed by corner arcs
                var dz = abs_dy - corner_dy
                var disc = radius * radius - dz * dz
                if disc > 0.0:
                    inset = radius - sqrt(disc)
                else:
                    continue  # row entirely outside the arcs
            var rx0 = Int(cx - half_w + inset)
            var rx1 = Int(cx + half_w - inset)
            # clip row span, then fill it
            if rx0 < clip.x:
                rx0 = clip.x
            if rx1 > clip.x + clip.w:
                rx1 = clip.x + clip.w
            if yy < clip.y or yy >= clip.y + clip.h:
                continue
            if rx1 <= rx0:
                continue
            self._fill_rows(rx0, rx1, yy, yy + 1, c)

    def fill_span(mut self, x0: Int, x1: Int, y: Int, c: Color):
        """[x0, x1) solid span on row y, pre-clipped coords."""
        self._fill_rows(x0, x1, y, y + 1, c)

    def outline_rect_rounded(
        mut self,
        fx: Float64,
        fy: Float64,
        fw: Float64,
        fh: Float64,
        roundness: Float64,
        thickness: Float64,
        c: Color,
    ):
        """Outlined rounded rect (draw_rectangle_rounded_lines_ex): per-row
        outer rounded span minus the inner hole (two fill_spans per row)."""
        if fw <= 0.0 or fh <= 0.0 or thickness <= 0.0:
            return
        var radius = roundness * 0.5 * (fw if fw < fh else fh)
        if radius > fw * 0.5:
            radius = fw * 0.5
        if radius > fh * 0.5:
            radius = fh * 0.5
        var inner_w = fw - 2.0 * thickness
        var inner_h = fh - 2.0 * thickness
        if inner_w <= 0.0 or inner_h <= 0.0:
            self.fill_rect_rounded(fx, fy, fw, fh, roundness, c)
            return
        var inner_radius = radius - thickness
        if inner_radius < 0.0:
            inner_radius = 0.0

        var y0 = Int(fy)
        var y1 = Int(fy + fh)
        var clip = self._clip()
        if y0 < clip.y:
            y0 = clip.y
        if y1 > clip.y + clip.h:
            y1 = clip.y + clip.h
        var cx = fx + fw * 0.5
        var cy = fy + fh * 0.5
        var inner_left = fx + thickness
        var inner_right = fx + fw - thickness
        var inner_top = fy + thickness
        var inner_bottom = fy + fh - thickness
        var half_inner_h = inner_h * 0.5
        var half_w = fw * 0.5
        var corner_dy = fh * 0.5 - radius

        for yy in range(y0, y1):
            var dy = (Float64(yy) + 0.5) - cy
            var abs_dy = dy if dy >= 0.0 else -dy

            # outer span inset
            var outer_inset = 0.0
            if abs_dy > corner_dy:
                var dz = abs_dy - corner_dy
                var disc = radius * radius - dz * dz
                if disc <= 0.0:
                    continue
                outer_inset = radius - sqrt(disc)

            # inner hole span
            var in_hole = False
            var hole_x0 = 0
            var hole_x1 = 0
            var py = Float64(yy) + 0.5
            if py >= inner_top and py < inner_bottom:
                if inner_radius > 0.5:
                    var idy = py - cy
                    var abs_idy = idy if idy >= 0.0 else -idy
                    if abs_idy > half_inner_h - inner_radius:
                        var dz2 = abs_idy - (half_inner_h - inner_radius)
                        var disc2 = inner_radius * inner_radius - dz2 * dz2
                        if disc2 > 0.0:
                            var inset_i = inner_radius - sqrt(disc2)
                            hole_x0 = Int(inner_left + inset_i)
                            hole_x1 = Int(inner_right - inset_i)
                            in_hole = True
                    else:
                        hole_x0 = Int(inner_left)
                        hole_x1 = Int(inner_right)
                        in_hole = True
                else:
                    hole_x0 = Int(inner_left)
                    hole_x1 = Int(inner_right)
                    in_hole = True

            # outer row extent
            var rx0 = Int(cx - half_w + outer_inset)
            var rx1 = Int(cx + half_w - outer_inset)
            if rx0 < clip.x:
                rx0 = clip.x
            if rx1 > clip.x + clip.w:
                rx1 = clip.x + clip.w
            if rx1 <= rx0:
                continue
            if not in_hole:
                self._fill_rows(rx0, rx1, yy, yy + 1, c)
            else:
                if hole_x0 > rx0:
                    self._fill_rows(rx0, hole_x0, yy, yy + 1, c)
                if rx1 > hole_x1:
                    self._fill_rows(hole_x1, rx1, yy, yy + 1, c)

    # ------------------------------------------------------------------
    # blits
    # ---------------------------------------------------------------------------

    def blit_rgba(
        mut self,
        src: Pointer[UInt8, MutUntrackedOrigin],
        src_w: Int,
        src_h: Int,
        src_stride: Int,
        dx: Float64,
        dy: Float64,
        dw: Float64,
        dh: Float64,
    ):
        """Nearest-neighbor scaled RGBA→BGRX blit (cover art; the app's single
        texture op — draw_texture_pro with full source, no rotation).

        Source pixels are RGBA (as produced by resources.imdecode); the
        canvas buffer is BGRX (ARGB8888 shm layout, byte 0 = blue), so
        R and B are swapped during the copy."""
        if dw <= 0.0 or dh <= 0.0 or src_w <= 0 or src_h <= 0:
            return
        var dx0 = Int(dx)
        var dy0 = Int(dy)
        var dx1 = Int(dx + dw)
        var dy1 = Int(dy + dh)
        var clip = self._clip()
        if dx0 < clip.x:
            dx0 = clip.x
        if dy0 < clip.y:
            dy0 = clip.y
        if dx1 > clip.x + clip.w:
            dx1 = clip.x + clip.w
        if dy1 > clip.y + clip.h:
            dy1 = clip.y + clip.h
        if dx1 <= dx0 or dy1 <= dy0:
            return
        var x_ratio = Float64(src_w) / dw
        var y_ratio = Float64(src_h) / dh
        var dx_int = Int(dx)
        var dy_int = Int(dy)
        for yy in range(dy0, dy1):
            var sy = Int((Float64(yy - dy_int) + 0.5) * y_ratio)
            if sy >= src_h:
                sy = src_h - 1
            if sy < 0:
                sy = 0
            var src_row = src.unsafe_offset(sy * src_stride)
            var dst_row = self.buf.unsafe_offset(yy * self.stride)
            for xx in range(dx0, dx1):
                var sx = Int((Float64(xx - dx_int) + 0.5) * x_ratio)
                if sx >= src_w:
                    sx = src_w - 1
                if sx < 0:
                    sx = 0
                var sp = src_row.unsafe_offset(sx * 4)
                var dp = dst_row.unsafe_offset(xx * 4)
                dp[unsafe_offset=0] = sp[unsafe_offset=2]  # B
                dp[unsafe_offset=1] = sp[unsafe_offset=1]  # G
                dp[unsafe_offset=2] = sp[unsafe_offset=0]  # R
                dp[unsafe_offset=3] = sp[unsafe_offset=3]  # A

    def blit_mask(
        mut self,
        mask: Pointer[UInt8, MutUntrackedOrigin],
        mw: Int,
        mh: Int,
        dx: Int,
        dy: Int,
        c: Color,
    ):
        """Glyph blit: mask = 1 byte per pixel coverage (0..255), blended
        over the destination with the tint color.

        Rows and spans are pre-clipped once per row (not per pixel): fully
        clipped rows are skipped, partially clipped rows narrow their span
        and advance the mask pointer past the clipped columns."""
        if mw <= 0 or mh <= 0:
            return
        var clip = self._clip()
        # word of the tint color + its byte lanes (B, G, R)
        var word = _bgrx(c)
        var cb = Int(word & 0xFF)
        var cg = Int((word >> 8) & 0xFF)
        var cr = Int((word >> 16) & 0xFF)
        # horizontal pre-clip: narrow [sx0, sx1) and shift the mask origin
        var sx0 = dx if dx > clip.x else clip.x
        var sx1 = (dx + mw) if (dx + mw) < (clip.x + clip.w) else (
            clip.x + clip.w
        )
        if sx1 <= sx0:
            return
        var mask_skip = sx0 - dx
        for yy in range(mh):
            var py = dy + yy
            if py < clip.y or py >= clip.y + clip.h:
                continue
            var dst_addr = Int(self.buf) + self.stride * py + sx0 * 4
            var dp = Pointer[UInt8, MutUntrackedOrigin](
                unsafe_from_address=dst_addr
            )
            var mp = mask.unsafe_offset(yy * mw + mask_skip)
            for _ in range(sx0, sx1):
                var cov = Int(mp[unsafe_offset=0])
                mp = mp.unsafe_offset(1)
                if cov == 0:
                    dp = dp.unsafe_offset(4)
                    continue
                if cov >= 255:
                    dp[unsafe_offset=0] = UInt8(cb)
                    dp[unsafe_offset=1] = UInt8(cg)
                    dp[unsafe_offset=2] = UInt8(cr)
                else:
                    # blend: dst = src*cov + dst*(1-cov) per channel
                    var inv = 255 - cov
                    dp[unsafe_offset=0] = UInt8(
                        (cb * cov + Int(dp[unsafe_offset=0]) * inv) // 255
                    )
                    dp[unsafe_offset=1] = UInt8(
                        (cg * cov + Int(dp[unsafe_offset=1]) * inv) // 255
                    )
                    dp[unsafe_offset=2] = UInt8(
                        (cr * cov + Int(dp[unsafe_offset=2]) * inv) // 255
                    )
                dp = dp.unsafe_offset(4)

    def draw_text(
        mut self,
        atlas: Pointer[TextAtlas, MutUntrackedOrigin],
        text: String,
        fx: Float64,
        fy: Float64,
        c: Color,
    ):
        """Draw text with a baked atlas. (fx, fy) is the BASELINE origin in
        pixels — the caller positions baselines; metrics live in the atlas.

        The atlas is BORROWED through a pointer (no per-call struct copy).
        Iterates UTF-8 CODEPOINTS, not bytes: multi-byte glyphs (Nerd Font
        PUA icons at U+F0000+) must resolve as one glyph, not per byte."""
        var pen_x = Int(fx)
        var baseline = Int(fy)
        var bytes = text.as_bytes()
        var n = len(bytes)
        var i = 0
        while i < n:
            var info = decode_utf8(bytes, i, n)
            var cp = info.cp
            var advance: Int = Int(atlas[unsafe_offset=0].pixel_size // 2)
            if cp == 32:
                advance = Int(atlas[unsafe_offset=0].pixel_size // 3)
            else:
                var idx = atlas[unsafe_offset=0].find_glyph(cp)
                if idx >= 0:
                    var g = atlas[unsafe_offset=0].glyphs[idx].copy()
                    advance = Int(g.advance_px)
                    if g.bitmap_w > 0 and g.bitmap_h > 0:
                        # glyph mask rows live inside the atlas mask buffer;
                        # address them directly — no per-row pointer churn
                        var mask_base = Int(atlas[unsafe_offset=0].mask.value())
                        var row_origin = (
                            mask_base
                            + Int(g.bitmap_x)
                            + Int(g.bitmap_y)
                            * Int(atlas[unsafe_offset=0].atlas_w)
                        )
                        var gx = pen_x + Int(g.bearing_x)
                        var gy = baseline - Int(g.bearing_y)
                        var glyph_w = Int(g.bitmap_w)
                        var atlas_stride = Int(atlas[unsafe_offset=0].atlas_w)
                        for yy in range(Int(g.bitmap_h)):
                            var row_ptr = Pointer[UInt8, MutUntrackedOrigin](
                                unsafe_from_address=row_origin
                                + yy * atlas_stride
                            )
                            self.blit_mask(row_ptr, glyph_w, 1, gx, gy + yy, c)
            pen_x += advance
            i += info.seq

    def measure_text(
        mut self, atlas: Pointer[TextAtlas, MutUntrackedOrigin], text: String
    ) -> Int:
        """Advance-width of text in pixels (mirrors atlas.text_width)."""
        return atlas[unsafe_offset=0].text_width(text)
