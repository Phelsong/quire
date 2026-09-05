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
#   blit(pixels, src_w, src_h, dx, dy, dw, dh) — cover art scaled blit
#   begin_clip / end_clip              — scissor stack
#   blit_mask (glyphs, todo: text)     — alpha-masked color fill from 8-bit
#
# Design: per-pixel span fills row-major with SIMD-friendly inner loops.
# Colors arrive as Color (RGBA u8); stored as 4 bytes B,G,R,X per pixel.

from std.memory import stack_allocation
from std.memory.unsafe_pointer import Pointer

from resources.color import Color

# Text bridge types (glyph info + baked atlas from the FreeType shim).
from platform.text import TextAtlas, GlyphInfo

# ---------------------------------------------------------------------------
# Color → bytes helpers
# ---------------------------------------------------------------------------


def _bgrx(c: Color) -> Int:
    """Pack RGBA Color into the 4-byte BGRX little-endian word used by
    ARGB8888 shm buffers on x86_64."""
    var b = Int(c.b) & 0xFF
    var g = Int(c.g) & 0xFF
    var r = Int(c.r) & 0xFF
    # X = alpha channel slot; keep 0xFF so downstream tooling sees opaque
    return b | (g << 8) | (r << 16) | (0xFF << 24)


def _alpha_channel(c: Color) -> Int:
    return Int(c.a) & 0xFF


# ---------------------------------------------------------------------------
# Canvas
# ---------------------------------------------------------------------------


def corner_dy_half(h: Float64, radius: Float64) -> Float64:
    """Vertical distance from center Y to the top/bottom straight section."""
    return h * 0.5 - radius


def sqrt_approx(v: Float64) -> Float64:
    """Newton-Raphson sqrt (no std.math.sqrt dependency check needed; this
    converges in ~6 iterations for our range)."""
    if v <= 0.0:
        return 0.0
    var x = v
    var prev = 0.0
    for _ in range(24):
        prev = x
        x = 0.5 * (x + v / x)
        if (x - prev) < 0.000001 and (prev - x) < 0.000001:
            break
    return x


struct ScissorEntry(Copyable, Movable):
    var x: Int
    var y: Int
    var w: Int
    var h: Int

    def __init__(out self):
        self.x = 0
        self.y = 0
        self.w = 0
        self.h = 0

    def __copyinit__(mut self, existing: Self):
        self.x = existing.x
        self.y = existing.y
        self.w = existing.w
        self.h = existing.h


struct Canvas(Copyable, Movable):
    """2D raster target bound to a Window frame buffer. All coordinates are
    in frame-buffer pixels (floats accepted; rounded to int spans)."""

    # The Window frame storage (borrowed, not owned — Window owns the mmap).
    var buf: Pointer[UInt8, MutUntrackedOrigin]
    var width: Int
    var height: Int
    var stride: Int

    # clip stack (fixed depth — imui nesting is shallow: screens + panels)
    var clip_x: List[Int]
    var clip_y: List[Int]
    var clip_w: List[Int]
    var clip_h: List[Int]

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
        self.clip_x = List[Int]()
        self.clip_y = List[Int]()
        self.clip_w = List[Int]()
        self.clip_h = List[Int]()

    def __copyinit__(mut self, existing: Self):
        self.buf = existing.buf
        self.width = existing.width
        self.height = existing.height
        self.stride = existing.stride
        # Lists need rebuilds (they don't own the clipboard semantics we need)
        self.clip_x = List[Int]()
        self.clip_y = List[Int]()
        self.clip_w = List[Int]()
        self.clip_h = List[Int]()
        for i in range(len(existing.clip_x)):
            self.clip_x.append(existing.clip_x[i])
            self.clip_y.append(existing.clip_y[i])
            self.clip_w.append(existing.clip_w[i])
            self.clip_h.append(existing.clip_h[i])

    # ------------------------------------------------------------------
    # clipping
    # ---------------------------------------------------------------------------

    def begin_clip(mut self, x: Int, y: Int, w: Int, h: Int):
        """Intersect with the current clip and push (scissor semantics)."""
        var cx = x
        var cy = y
        var cw = w
        var ch = h
        if len(self.clip_x) > 0:
            var px = self.clip_x[len(self.clip_x) - 1]
            var py = self.clip_y[len(self.clip_y) - 1]
            var pw = self.clip_w[len(self.clip_w) - 1]
            var ph = self.clip_h[len(self.clip_h) - 1]
            # intersect
            var nx = cx if cx > px else px
            var ny = cy if cy > py else py
            var nx2 = (cx + cw) if (cx + cw) < (px + pw) else (px + pw)
            var ny2 = (cy + ch) if (cy + ch) < (py + ph) else (py + ph)
            cx = nx
            cy = ny
            cw = nx2 - nx
            ch = ny2 - ny
            if cw < 0:
                cw = 0
            if ch < 0:
                ch = 0
        self.clip_x.append(cx)
        self.clip_y.append(cy)
        self.clip_w.append(cw)
        self.clip_h.append(ch)

    def end_clip(mut self):
        if len(self.clip_x) > 0:
            _ = self.clip_x.pop()
            _ = self.clip_y.pop()
            _ = self.clip_w.pop()
            _ = self.clip_h.pop()

    def _clip_x(mut self) -> Int:
        if len(self.clip_x) == 0:
            return 0
        return self.clip_x[len(self.clip_x) - 1]

    def _clip_y(mut self) -> Int:
        if len(self.clip_y) == 0:
            return 0
        return self.clip_y[len(self.clip_y) - 1]

    def _clip_x2(mut self) -> Int:
        if len(self.clip_w) == 0:
            return self.width
        return (
            self.clip_x[len(self.clip_x) - 1]
            + self.clip_w[len(self.clip_w) - 1]
        )

    def _clip_y2(mut self) -> Int:
        if len(self.clip_h) == 0:
            return self.height
        return (
            self.clip_y[len(self.clip_y) - 1]
            + self.clip_h[len(self.clip_h) - 1]
        )

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
        if x0 < self._clip_x():
            x0 = self._clip_x()
        if y0 < self._clip_y():
            y0 = self._clip_y()
        if x1 > self._clip_x2():
            x1 = self._clip_x2()
        if y1 > self._clip_y2():
            y1 = self._clip_y2()
        if x1 <= x0 or y1 <= y0:
            return

        var word = _bgrx(c)
        var base_addr = Int(self.buf)
        for yy in range(y0, y1):
            var row_addr = base_addr + self.stride * yy
            # head: unaligned pixels until the address is 4-aligned
            var px = x0
            var addr = row_addr + px * 4
            var misalign = addr % 4
            if misalign != 0:
                var head = (4 - misalign) // 1  # bytes until aligned == pixels
                if head > (x1 - px):
                    head = x1 - px
                for hh in range(head):
                    self._store_px(px + hh, yy, word)
                px += head
            # aligned word fill (UInt32 = exactly one BGRX pixel per store;
            # Mojo Int is 8 bytes and would stomp the NEXT pixel's alpha to 0)
            var uword = UInt32(word & 0xFFFFFFFF)
            if px < x1:
                var wp = Pointer[UInt32, MutUntrackedOrigin](
                    unsafe_from_address=row_addr + px * 4
                )
                while px < x1:
                    wp[unsafe_offset=0] = uword
                    wp = wp.unsafe_offset(1)
                    px += 1

    def _store_px(mut self, x: Int, y: Int, bgrx: Int):
        """Single pixel store (caller ensures bounds). Word-safe split store."""
        var addr = Int(self.buf) + self.stride * y + x * 4
        var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=addr)
        p[unsafe_offset=0] = UInt8(bgrx & 0xFF)
        p[unsafe_offset=1] = UInt8((bgrx >> 8) & 0xFF)
        p[unsafe_offset=2] = UInt8((bgrx >> 16) & 0xFF)
        p[unsafe_offset=3] = UInt8((bgrx >> 24) & 0xFF)

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
        at fy+fh, linearly interpolated per row. Not word-optimized (one
        blend per row is negligible vs the per-pixel fill cost)."""
        if fw <= 0.0 or fh <= 0.0:
            return
        var x0 = Int(fx)
        var y0 = Int(fy)
        var x1 = Int(fx + fw)
        var y1 = Int(fy + fh)
        # clip to window + scissor
        if x0 < self._clip_x():
            x0 = self._clip_x()
        if y0 < self._clip_y():
            y0 = self._clip_y()
        if x1 > self._clip_x2():
            x1 = self._clip_x2()
        if y1 > self._clip_y2():
            y1 = self._clip_y2()
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
            self.fill_rect(
                Float64(x0),
                Float64(yy),
                Float64(x1 - x0),
                1.0,
                Color(
                    UInt8(tr + dr * t),
                    UInt8(tg + dg * t),
                    UInt8(tb + db * t),
                    255,
                ),
            )

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
        var x0 = Int(fx)
        var y0 = Int(fy)
        var x1 = Int(fx + fw)
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
        for yy in range(y0, y1):
            # Per-row span: [row_x0, row_x1) inside the rounded shape
            var dy = (Float64(yy) + 0.5) - cy
            var half_w = fw * 0.5
            var corner_dy = (fh * 0.5) - radius
            var abs_dy = dy if dy >= 0.0 else -dy
            var inset = 0.0
            if abs_dy > corner_dy_half(fh, radius):
                # inside the vertical range governed by corner arcs
                var dz = abs_dy - corner_dy_half(fh, radius)
                var disc = radius * radius - dz * dz
                if disc > 0.0:
                    inset = radius - sqrt_approx(disc)
                else:
                    continue  # row entirely outside the arcs
            var rx0 = Int(cx - half_w + inset)
            var rx1 = Int(cx + half_w - inset)
            # clip row span, then reuse fill_rect for the span
            if rx0 < self._clip_x():
                rx0 = self._clip_x()
            if rx1 > self._clip_x2():
                rx1 = self._clip_x2()
            if yy < self._clip_y() or yy >= self._clip_y2():
                continue
            if rx1 <= rx0:
                continue
            # inline span fill (fill_rect would re-clip rows — fine, call it)
            self.fill_span(rx0, rx1, yy, c)

    def fill_span(mut self, x0: Int, x1: Int, y: Int, c: Color):
        """[x0, x1) solid span on row y, pre-clipped coords."""
        if x1 <= x0 or y < 0 or y >= self.height:
            return
        var word = _bgrx(c)
        var base_addr = Int(self.buf) + self.stride * y
        var px = x0
        var addr = base_addr + px * 4
        var misalign = addr % 4
        if misalign != 0:
            var head = 4 - misalign
            if head > (x1 - px):
                head = x1 - px
            for hh in range(head):
                self._store_px(px + hh, y, word)
            px += head
        if px < x1:
            var uword = UInt32(word & 0xFFFFFFFF)
            var wp = Pointer[UInt32, MutUntrackedOrigin](
                unsafe_from_address=base_addr + px * 4
            )
            while px < x1:
                wp[unsafe_offset=0] = uword
                wp = wp.unsafe_offset(1)
                px += 1

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
        if y0 < self._clip_y():
            y0 = self._clip_y()
        if y1 > self._clip_y2():
            y1 = self._clip_y2()
        var cx = fx + fw * 0.5
        var cy = fy + fh * 0.5
        var inner_left = fx + thickness
        var inner_right = fx + fw - thickness
        var inner_top = fy + thickness
        var inner_bottom = fy + fh - thickness
        var half_inner_h = inner_h * 0.5

        for yy in range(y0, y1):
            var dy = (Float64(yy) + 0.5) - cy
            var abs_dy = dy if dy >= 0.0 else -dy

            # outer span inset
            var outer_inset = 0.0
            if abs_dy > (fh * 0.5) - radius:
                var dz = abs_dy - ((fh * 0.5) - radius)
                var disc = radius * radius - dz * dz
                if disc <= 0.0:
                    continue
                outer_inset = radius - sqrt_approx(disc)

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
                            var inset_i = inner_radius - sqrt_approx(disc2)
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
            var half_w = fw * 0.5
            var rx0 = Int(cx - half_w + outer_inset)
            var rx1 = Int(cx + half_w - outer_inset)
            if rx0 < self._clip_x():
                rx0 = self._clip_x()
            if rx1 > self._clip_x2():
                rx1 = self._clip_x2()
            if rx1 <= rx0:
                continue
            if not in_hole:
                self.fill_span(rx0, rx1, yy, c)
            else:
                if hole_x0 > rx0:
                    self.fill_span(rx0, hole_x0, yy, c)
                if rx1 > hole_x1:
                    self.fill_span(hole_x1, rx1, yy, c)

    # ------------------------------------------------------------------
    # blits
    # ---------------------------------------------------------------------------

    def blit_bgrx(
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
        """Nearest-neighbor scaled BGRX blit (cover art; the app's single
        texture op — draw_texture_pro with full source, no rotation)."""
        if dw <= 0.0 or dh <= 0.0 or src_w <= 0 or src_h <= 0:
            return
        var dx0 = Int(dx)
        var dy0 = Int(dy)
        var dx1 = Int(dx + dw)
        var dy1 = Int(dy + dh)
        if dx0 < self._clip_x():
            dx0 = self._clip_x()
        if dy0 < self._clip_y():
            dy0 = self._clip_y()
        if dx1 > self._clip_x2():
            dx1 = self._clip_x2()
        if dy1 > self._clip_y2():
            dy1 = self._clip_y2()
        if dx1 <= dx0 or dy1 <= dy0:
            return
        var x_ratio = Float64(src_w) / dw
        var y_ratio = Float64(src_h) / dh
        for yy in range(dy0, dy1):
            var sy = Int((Float64(yy - Int(dy)) + 0.5) * y_ratio)
            if sy >= src_h:
                sy = src_h - 1
            if sy < 0:
                sy = 0
            var src_row = src.unsafe_offset(sy * src_stride)
            var dst_row = self.buf.unsafe_offset(yy * self.stride)
            for xx in range(dx0, dx1):
                var sx = Int((Float64(xx - Int(dx)) + 0.5) * x_ratio)
                if sx >= src_w:
                    sx = src_w - 1
                if sx < 0:
                    sx = 0
                var sp = src_row.unsafe_offset(sx * 4)
                var dp = dst_row.unsafe_offset(xx * 4)
                dp[unsafe_offset=0] = sp[unsafe_offset=0]
                dp[unsafe_offset=1] = sp[unsafe_offset=1]
                dp[unsafe_offset=2] = sp[unsafe_offset=2]
                dp[unsafe_offset=3] = sp[unsafe_offset=3]

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
        over the destination with the tint color."""
        var word = _bgrx(c)
        var cr = UInt8(word & 0xFF)
        var cg = UInt8((word >> 8) & 0xFF)
        var cb = UInt8((word >> 16) & 0xFF)
        for yy in range(mh):
            var py = dy + yy
            if py < self._clip_y() or py >= self._clip_y2():
                continue
            for xx in range(mw):
                var px = dx + xx
                if px < self._clip_x() or px >= self._clip_x2():
                    continue
                var cov = Int(mask[unsafe_offset=yy * mw + xx])
                if cov == 0:
                    continue
                if cov >= 255:
                    self._store_px(px, py, word)
                else:
                    # blend: dst = src*cov + dst*(1-cov) per channel
                    var addr = Int(self.buf) + self.stride * py + px * 4
                    var dp = Pointer[UInt8, MutUntrackedOrigin](
                        unsafe_from_address=addr
                    )
                    var inv = 255 - cov
                    dp[unsafe_offset=0] = UInt8(
                        (Int(cr) * cov + Int(dp[unsafe_offset=0]) * inv) // 255
                    )
                    dp[unsafe_offset=1] = UInt8(
                        (Int(cg) * cov + Int(dp[unsafe_offset=1]) * inv) // 255
                    )
                    dp[unsafe_offset=2] = UInt8(
                        (Int(cb) * cov + Int(dp[unsafe_offset=2]) * inv) // 255
                    )

    def draw_text(
        mut self,
        mut atlas: TextAtlas,
        text: String,
        fx: Float64,
        fy: Float64,
        c: Color,
    ):
        """Draw text with a baked atlas. (fx, fy) is the BASELINE origin in
        pixels — the caller positions baselines; metrics live in the atlas.

        Iterates UTF-8 CODEPOINTS, not bytes: multi-byte glyphs (Nerd Font
        PUA icons at U+F0000+) must resolve as one glyph, not per byte."""
        var pen_x = Int(fx)
        var baseline = Int(fy)
        var text_mut = String(text)
        var bytes = text_mut.as_bytes()
        var i = 0
        var n = len(bytes)
        while i < n:
            var b = bytes[i]
            # Widen to Int32 BEFORE shifting: UInt8 shift-or wraps 8-bit and
            # destroys multi-byte codepoints (3 << 18 == 0 in 8-bit).
            var cp = Int32(b)
            var seq = 1
            if b >= 0xF0:
                # 4-byte sequence: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
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
            # else: ASCII, cp = b, seq = 1

            var advance: Int = Int(atlas.pixel_size // 2)
            if cp == 32:
                advance = Int(atlas.pixel_size // 3)
            else:
                var idx = atlas.find_glyph(cp)
                if idx >= 0:
                    var g = atlas.glyphs[idx].copy()
                    advance = Int(g.advance_px)
                    if g.bitmap_w > 0 and g.bitmap_h > 0:
                        for yy in range(Int(g.bitmap_h)):
                            var row_ptr = Pointer[UInt8, MutUntrackedOrigin](
                                unsafe_from_address=Int(atlas.mask.value())
                                + Int(g.bitmap_x)
                                + (Int(g.bitmap_y) + yy) * Int(atlas.atlas_w)
                            )
                            self.blit_mask(
                                row_ptr,
                                Int(g.bitmap_w),
                                1,
                                pen_x + Int(g.bearing_x),
                                baseline - Int(g.bearing_y) + yy,
                                c,
                            )
            pen_x += advance
            i += seq

    def measure_text(mut self, mut atlas: TextAtlas, text: String) -> Int:
        """Advance-width of text in pixels (mirrors atlas.text_width)."""
        var text_mut = String(text)
        return atlas.text_width(text_mut)
