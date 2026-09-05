"""Named icon glyphs from the bundled CaskaydiaCove Nerd Font.

All codepoints are Material Design icons in the Nerd Font PUA range.
The glyphs must be baked by FontSet.load() (ui/font.mojo) before use.
Strings are Writable so ui.label() draws them like any other text.

Mojo note: \\u is exactly 4 hex digits; 5-digit codepoints need the \\U
form with 8 hex digits (\\U000F040D, not \\uF040D).
"""


comptime ICON_PLAY = "\U000f040d"
comptime ICON_PAUSE = "\U000f03e4"
comptime ICON_PREV = "\U000f048a"
comptime ICON_NEXT = "\U000f0492"
comptime ICON_BACK = "\U000f0142"
comptime ICON_SETTINGS = "\U000f0384"
comptime ICON_OVERFLOW = "\U000f01e5"
comptime ICON_LOGOUT = "\U000f02d6"
comptime ICON_VOLUME = "\U000f0482"
comptime ICON_TUNE = "\U000f057e"
