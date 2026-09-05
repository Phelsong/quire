# ui/font.mojo — font atlas cache backed by the FreeType shim.
#
# bake_scale multiplies the pixel sizes
# so HiDPI displays get physical-resolution atlases (crisp text): drawing at
# the logical size with a bake_scale'd atlas yields a 1:1 atlas-to-pixel match.
#
# Codepoints baked: ASCII 32..126 + bullet 8226 (password mask) + checkmark
# 10003
#
# Storage design: atlases live in ONE heap-allocated 13-slot block. TextAtlas
# is a non-copyable resource (owns a mask buffer); the heap block lets us
# hand out Pointer[TextAtlas] handles (the ladder accessor) without
# needing field-address gymnastics. load() replaces slots in place; unload()
# closes in place. Moves of FontSet just re-point the block (Movable move
# ctor nulls the source).

from std.memory import alloc, Layout
from std.collections import Optional
from platform.text import TextEngine, TextAtlas


comptime FONT_SIZES = (12, 14, 16, 18, 20, 22, 26, 32, 48, 56, 64, 81, 96)
comptime FONT_SIZE_COUNT = 13


struct FontSet(Copyable, Movable):
    # Heap-backed atlas block (13 slots, ladder order 12..96). Empty until
    # the first load(); load replaces slot contents in place.
    var slots: Optional[Pointer[TextAtlas, MutUntrackedOrigin]]
    var load_ok: Bool

    def __init__(out self):
        self.slots = Optional[Pointer[TextAtlas, MutUntrackedOrigin]]()
        self.load_ok = False

    def __copyinit__(mut self, existing: Self):
        # Deep copy: allocate our own block, copy each atlas resource.
        self.slots = alloc(Layout[TextAtlas](count=13)).unsafe_leak()
        for i in range(FONT_SIZE_COUNT):
            self.slots.value().unsafe_offset(i).unsafe_write(
                existing.slots.value()[unsafe_offset=i].copy()
            )
        self.load_ok = existing.load_ok

    def __moveinit__(mut self, existing: Self):
        # Steal the block. `existing` is consumed by the move — semantic
        # ownership transfers; the source holds a stale pointer but is never
        # touched again after the move (1.0.0 moveinit has no mutable source).
        if existing.slots:
            self.slots = Optional[Pointer[TextAtlas, MutUntrackedOrigin]](
                existing.slots.value()
            )
        else:
            self.slots = Optional[Pointer[TextAtlas, MutUntrackedOrigin]]()
        self.load_ok = existing.load_ok

    def _ensure_slots(mut self):
        """Lazily allocate the empty-atlas block on first use."""
        if not self.slots:
            self.slots = alloc(Layout[TextAtlas](count=13)).unsafe_leak()
            for i in range(FONT_SIZE_COUNT):
                self.slots.value().unsafe_offset(i).unsafe_write(TextAtlas())

    def load(mut self, font_path: String, bake_scale: Float64 = 1.0) raises:
        """Bake all 13 font sizes from the given TTF via the TextEngine.

        bake_scale multiplies the base sizes (12,14,...96) so that on HiDPI
        displays the atlas is baked at physical resolution. For a 2x DPI
        display, pass bake_scale=2.0 so the atlas for logical 16px is baked
        at 32px — a 1:1 atlas-to-pixel match when drawn at logical size.
        """
        var sizes = List[Int]()
        sizes.append(12)
        sizes.append(14)
        sizes.append(16)
        sizes.append(18)
        sizes.append(20)
        sizes.append(22)
        sizes.append(26)
        sizes.append(32)
        sizes.append(48)
        sizes.append(56)
        sizes.append(64)
        sizes.append(81)
        sizes.append(96)

        var codepoints = List[Int32]()
        for i in range(32, 127):
            codepoints.append(Int32(i))
        codepoints.append(Int32(8226))  # bullet (password mask)
        codepoints.append(Int32(10003))  # checkmark
        # Nerd Font Material Design icon glyphs (PUA range, present in the
        # bundled CaskaydiaCove Nerd Font).
        codepoints.append(Int32(0xF040D))  # play
        codepoints.append(Int32(0xF03E4))  # pause
        codepoints.append(Int32(0xF048A))  # skip-previous
        codepoints.append(Int32(0xF0492))  # skip-next
        codepoints.append(Int32(0xF0142))  # arrow-left (back)
        codepoints.append(Int32(0xF0384))  # cog (settings)
        codepoints.append(Int32(0xF01E5))  # dots-vertical (overflow)
        codepoints.append(Int32(0xF02D6))  # logout
        codepoints.append(Int32(0xF0482))  # volume-high
        codepoints.append(Int32(0xF057E))  # tune (equalizer)

        self._ensure_slots()

        var engine = TextEngine()
        var path_var = String(font_path)

        engine.init_engine(path_var)
        for i in range(FONT_SIZE_COUNT):
            var px = Int(Float64(sizes[i]) * bake_scale)
            self.slots.value().unsafe_offset(i).unsafe_write(
                engine.bake_atlas(Int32(px), codepoints)
            )
        engine.close()

        # Sanity: a successful bake yields a nonzero atlas (ASCII never sums
        # to 0 width).
        if self.slots.value()[unsafe_offset=8].atlas_w <= 0:
            self.load_ok = False
        else:
            self.load_ok = True

    def unload(mut self):
        """Free loaded atlas resources."""
        if not self.slots:
            self.load_ok = False
            return
        for i in range(FONT_SIZE_COUNT):
            self.slots.value()[unsafe_offset=i].close()
        self.slots.value().unsafe_free()
        self.slots = Optional[Pointer[TextAtlas, MutUntrackedOrigin]]()
        self.load_ok = False

    def get_atlas(mut self, px: Int) -> Pointer[TextAtlas, MutUntrackedOrigin]:
        """Pointer to the ladder rung for a native pixel size.

        Callers use the returned pointer read-only ([0].ascent etc.) — the
        FontSet outlives the UIContext that borrows it within a frame, and
        the atlases are only replaced by load()/unload() outside the loop.
        Empty FontSet (never loaded) yields slots[8] (48px stub)."""
        self._ensure_slots()
        if px <= 12:
            return self.slots.value().unsafe_offset(0)
        elif px <= 14:
            return self.slots.value().unsafe_offset(1)
        elif px <= 16:
            return self.slots.value().unsafe_offset(2)
        elif px <= 18:
            return self.slots.value().unsafe_offset(3)
        elif px <= 20:
            return self.slots.value().unsafe_offset(4)
        elif px <= 22:
            return self.slots.value().unsafe_offset(5)
        elif px <= 26:
            return self.slots.value().unsafe_offset(6)
        elif px <= 32:
            return self.slots.value().unsafe_offset(7)
        elif px <= 48:
            return self.slots.value().unsafe_offset(8)
        elif px <= 56:
            return self.slots.value().unsafe_offset(9)
        elif px <= 64:
            return self.slots.value().unsafe_offset(10)
        elif px <= 81:
            return self.slots.value().unsafe_offset(11)
        else:
            return self.slots.value().unsafe_offset(12)
