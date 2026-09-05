from resources.color import Color


# ---------------------------------------------------------------------------
# Color palette — sourced from resources/current-theme.conf
#
# background    #08131a   deep sea-green (app + panels)
# foreground    #deb88d   warm sand (primary text)
# color3/accent #fba02f   amber-orange (primary accent)
# color12       #1abcdd   cyan (links, focus)
# selection_bg  #1e4862   steel teal (active/selected surfaces)
# ---------------------------------------------------------------------------

comptime WHITE = Color(255, 255, 255, 255)  # Full white for texture tinting
comptime LOGIN_BG = Color(0x08, 0x13, 0x1A, 255)  # background #08131a
comptime GREEN = Color(0xFB, 0xA0, 0x2F, 255)  # color3 #fba02f accent amber
comptime INPUT_BG = Color(0x17, 0x38, 0x4C, 255)  # color0 #17384c input wells
comptime TEXT_BRIGHT = Color(
    0xFE, 0xE3, 0xCD, 255
)  # color15 #fee3cd bright text
comptime TEXT_LIGHT = Color(0xDE, 0xB8, 0x8D, 255)  # color7/fg #deb88d sand
comptime TEXT_DIM = Color(0x86, 0xAB, 0xB3, 255)  # color14 #86abb3 muted text
comptime ACCENT_DARK = Color(0x08, 0x13, 0x1A, 255)  # text on amber buttons
comptime ERROR_COLOR = Color(0xD0, 0x50, 0x23, 255)  # color1 #d05023 error red
comptime BORDER_FOCUS = Color(0x1A, 0xBC, 0xDD, 255)  # color12 #1abcdd focus
comptime BORDER_IDLE = Color(0x42, 0x4B, 0x52, 255)  # color8 #424b52 dim border
comptime CARD_BG = Color(0x06, 0x0F, 0x15, 255)  # inactive_tab_bg #060f15 cards
comptime FOOTER_COLOR = Color(0x86, 0xAB, 0xB3, 255)  # color14 muted footer

# Library screen colors
comptime LIBRARY_BG = Color(0x08, 0x13, 0x1A, 255)  # background #08131a
comptime LIB_CARD_BG = Color(0x17, 0x38, 0x4C, 230)  # color0 #17384c row hover
comptime LOGOUT_RED = Color(0xD0, 0x50, 0x23, 255)  # color1 #d05023 destructive
comptime DOWNLOAD_BLUE = Color(0x50, 0xA3, 0xB5, 255)  # color6 #50a3b5 save
comptime DOWNLOADED_GREEN = Color(0x02, 0x7B, 0x9B, 255)  # color2 #027b9b teal
comptime BTN_DARK_LIB = Color(0x1D, 0x48, 0x50, 255)  # color4 #1d4850 buttons
comptime PLACEHOLDER_BG = Color(0x17, 0x38, 0x4C, 255)  # color0 #17384c wells
comptime TEXT_MUTED = Color(0x61, 0x8C, 0x98, 255)  # color10 #618c98 muted
comptime SELECTED_BG = Color(0x1E, 0x48, 0x62, 255)  # selection_bg #1e4862

# Player screen colors
comptime PLAYER_BG = Color(0x08, 0x13, 0x1A, 255)  # background #08131a
comptime PLAYER_INFO_BG = Color(0x06, 0x0F, 0x15, 255)  # inactive_tab_bg cards
comptime SLIDER_BG = Color(0x42, 0x4B, 0x52, 255)  # color8 #424b52 track
comptime SLIDER_FILL = Color(0xFB, 0xA0, 0x2F, 255)  # color3 #fba02f fill
comptime CHAPTER_HIGHLIGHT = Color(0x1E, 0x48, 0x62, 255)  # selection_bg
comptime BTN_CONTROL = Color(0x1D, 0x48, 0x50, 255)  # color4 #1d4850 controls

# Background gradient (subtle, teal-tinted top fading into the base)
comptime BG_GRADIENT_TOP = Color(0x11, 0x2C, 0x38, 255)  # lifted teal sea
comptime BG_GRADIENT_BOTTOM = Color(0x05, 0x0C, 0x11, 255)  # near-black base

# Unicode characters as UTF-8 byte sequences (Mojo string literals)
comptime BULLET = "\0xE2\0x80\0x94"  # U+2022 • (bullet for password masking)
comptime CHECKMARK = "\0xE2\0x9C\0x93"  # U+2713 ✓ (checkmark)

comptime SCREEN_W = 1800  # Default window width (logical pixels)
comptime SCREEN_H = 1000  # Default window height (logical pixels)
