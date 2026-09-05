"""Quire — Key-name to keycode resolver.

Maps config keybind strings (e.g. "KEY_SPACE") to Int keycodes
(e.g. 32). Config stores keybinds as Dict[String, List[String]] where each
String is a key constant name. This module bridges the string ↔ Int
gap so the UI layer can call is_key_pressed(Int).

Gamepad buttons are resolved to a tagged value: GAMEPAD_SENTINEL + button
code, so the UI layer can distinguish a keyboard keycode from a gamepad
button code (which share the 0-17 range with keyboard keys).
"""

# Sentinel added to gamepad button codes so the UI layer can tell them
# apart from keyboard keycodes (which overlap the 0-17 range). Any
# resolved code >= GAMEPAD_SENTINEL is a gamepad button; subtract the
# sentinel to get the raw gamepad button code.
comptime GAMEPAD_SENTINEL = 10000

# --- Key constants (GLFW keycodes)
# --- these replace; stored keybind configs stay valid across the swap)
comptime KEY_NULL = 0
comptime KEY_APOSTROPHE = 39
comptime KEY_COMMA = 44
comptime KEY_MINUS = 45
comptime KEY_PERIOD = 46
comptime KEY_SLASH = 47
comptime KEY_ZERO = 48
comptime KEY_ONE = 49
comptime KEY_TWO = 50
comptime KEY_THREE = 51
comptime KEY_FOUR = 52
comptime KEY_FIVE = 53
comptime KEY_SIX = 54
comptime KEY_SEVEN = 55
comptime KEY_EIGHT = 56
comptime KEY_NINE = 57
comptime KEY_SEMICOLON = 59
comptime KEY_EQUAL = 61
comptime KEY_A = 65
comptime KEY_B = 66
comptime KEY_C = 67
comptime KEY_D = 68
comptime KEY_E = 69
comptime KEY_F = 70
comptime KEY_G = 71
comptime KEY_H = 72
comptime KEY_I = 73
comptime KEY_J = 74
comptime KEY_K = 75
comptime KEY_L = 76
comptime KEY_M = 77
comptime KEY_N = 78
comptime KEY_O = 79
comptime KEY_P = 80
comptime KEY_Q = 81
comptime KEY_R = 82
comptime KEY_S = 83
comptime KEY_T = 84
comptime KEY_U = 85
comptime KEY_V = 86
comptime KEY_W = 87
comptime KEY_X = 88
comptime KEY_Y = 89
comptime KEY_Z = 90
comptime KEY_LEFT_BRACKET = 91
comptime KEY_BACKSLASH = 92
comptime KEY_RIGHT_BRACKET = 93
comptime KEY_GRAVE = 96
comptime KEY_SPACE = 32
comptime KEY_ESCAPE = 256
comptime KEY_ENTER = 257
comptime KEY_TAB = 258
comptime KEY_BACKSPACE = 259
comptime KEY_INSERT = 260
comptime KEY_DELETE = 261
comptime KEY_RIGHT = 262
comptime KEY_LEFT = 263
comptime KEY_DOWN = 264
comptime KEY_UP = 265
comptime KEY_PAGE_UP = 266
comptime KEY_PAGE_DOWN = 267
comptime KEY_HOME = 268
comptime KEY_END = 269
comptime KEY_CAPS_LOCK = 280
comptime KEY_SCROLL_LOCK = 281
comptime KEY_NUM_LOCK = 282
comptime KEY_PRINT_SCREEN = 283
comptime KEY_PAUSE = 284
comptime KEY_F1 = 290
comptime KEY_F2 = 291
comptime KEY_F3 = 292
comptime KEY_F4 = 293
comptime KEY_F5 = 294
comptime KEY_F6 = 295
comptime KEY_F7 = 296
comptime KEY_F8 = 297
comptime KEY_F9 = 298
comptime KEY_F10 = 299
comptime KEY_F11 = 300
comptime KEY_F12 = 301
comptime KEY_LEFT_SHIFT = 340
comptime KEY_LEFT_CONTROL = 341
comptime KEY_LEFT_ALT = 342
comptime KEY_LEFT_SUPER = 343
comptime KEY_RIGHT_SHIFT = 344
comptime KEY_RIGHT_CONTROL = 345
comptime KEY_RIGHT_ALT = 346
comptime KEY_RIGHT_SUPER = 347
comptime KEY_KB_MENU = 348
comptime KEY_KP_0 = 320
comptime KEY_KP_1 = 321
comptime KEY_KP_2 = 322
comptime KEY_KP_3 = 323
comptime KEY_KP_4 = 324
comptime KEY_KP_5 = 325
comptime KEY_KP_6 = 326
comptime KEY_KP_7 = 327
comptime KEY_KP_8 = 328
comptime KEY_KP_9 = 329
comptime KEY_KP_DECIMAL = 330
comptime KEY_KP_DIVIDE = 331
comptime KEY_KP_MULTIPLY = 332
comptime KEY_KP_SUBTRACT = 333
comptime KEY_KP_ADD = 334
comptime KEY_KP_ENTER = 335
comptime KEY_KP_EQUAL = 336
comptime KEY_BACK = 4
comptime KEY_MENU = 5
comptime KEY_VOLUME_UP = 24
comptime KEY_VOLUME_DOWN = 25

# --- Gamepad button constants (GamepadButton enum values) ---
comptime GAMEPAD_BUTTON_UNKNOWN = 0
comptime GAMEPAD_BUTTON_LEFT_FACE_UP = 1
comptime GAMEPAD_BUTTON_LEFT_FACE_RIGHT = 2
comptime GAMEPAD_BUTTON_LEFT_FACE_DOWN = 3
comptime GAMEPAD_BUTTON_LEFT_FACE_LEFT = 4
comptime GAMEPAD_BUTTON_RIGHT_FACE_UP = 5
comptime GAMEPAD_BUTTON_RIGHT_FACE_RIGHT = 6
comptime GAMEPAD_BUTTON_RIGHT_FACE_DOWN = 7
comptime GAMEPAD_BUTTON_RIGHT_FACE_LEFT = 8
comptime GAMEPAD_BUTTON_LEFT_TRIGGER_1 = 9
comptime GAMEPAD_BUTTON_LEFT_TRIGGER_2 = 10
comptime GAMEPAD_BUTTON_RIGHT_TRIGGER_1 = 11
comptime GAMEPAD_BUTTON_RIGHT_TRIGGER_2 = 12
comptime GAMEPAD_BUTTON_MIDDLE_LEFT = 13
comptime GAMEPAD_BUTTON_MIDDLE = 14
comptime GAMEPAD_BUTTON_MIDDLE_RIGHT = 15
comptime GAMEPAD_BUTTON_LEFT_THUMB = 16
comptime GAMEPAD_BUTTON_RIGHT_THUMB = 17


def key_code(name: String) -> Int:
    """Resolve a key-name string to its Int keycode.

    Returns 0 (KEY_NULL) for unrecognized names — 0 is treated as
    "no keybind" throughout the UI layer.
    """
    if name == "KEY_NULL":
        return KEY_NULL
    elif name == "KEY_APOSTROPHE":
        return KEY_APOSTROPHE
    elif name == "KEY_COMMA":
        return KEY_COMMA
    elif name == "KEY_MINUS":
        return KEY_MINUS
    elif name == "KEY_PERIOD":
        return KEY_PERIOD
    elif name == "KEY_SLASH":
        return KEY_SLASH
    elif name == "KEY_ZERO":
        return KEY_ZERO
    elif name == "KEY_ONE":
        return KEY_ONE
    elif name == "KEY_TWO":
        return KEY_TWO
    elif name == "KEY_THREE":
        return KEY_THREE
    elif name == "KEY_FOUR":
        return KEY_FOUR
    elif name == "KEY_FIVE":
        return KEY_FIVE
    elif name == "KEY_SIX":
        return KEY_SIX
    elif name == "KEY_SEVEN":
        return KEY_SEVEN
    elif name == "KEY_EIGHT":
        return KEY_EIGHT
    elif name == "KEY_NINE":
        return KEY_NINE
    elif name == "KEY_SEMICOLON":
        return KEY_SEMICOLON
    elif name == "KEY_EQUAL":
        return KEY_EQUAL
    elif name == "KEY_A":
        return KEY_A
    elif name == "KEY_B":
        return KEY_B
    elif name == "KEY_C":
        return KEY_C
    elif name == "KEY_D":
        return KEY_D
    elif name == "KEY_E":
        return KEY_E
    elif name == "KEY_F":
        return KEY_F
    elif name == "KEY_G":
        return KEY_G
    elif name == "KEY_H":
        return KEY_H
    elif name == "KEY_I":
        return KEY_I
    elif name == "KEY_J":
        return KEY_J
    elif name == "KEY_K":
        return KEY_K
    elif name == "KEY_L":
        return KEY_L
    elif name == "KEY_M":
        return KEY_M
    elif name == "KEY_N":
        return KEY_N
    elif name == "KEY_O":
        return KEY_O
    elif name == "KEY_P":
        return KEY_P
    elif name == "KEY_Q":
        return KEY_Q
    elif name == "KEY_R":
        return KEY_R
    elif name == "KEY_S":
        return KEY_S
    elif name == "KEY_T":
        return KEY_T
    elif name == "KEY_U":
        return KEY_U
    elif name == "KEY_V":
        return KEY_V
    elif name == "KEY_W":
        return KEY_W
    elif name == "KEY_X":
        return KEY_X
    elif name == "KEY_Y":
        return KEY_Y
    elif name == "KEY_Z":
        return KEY_Z
    elif name == "KEY_LEFT_BRACKET":
        return KEY_LEFT_BRACKET
    elif name == "KEY_BACKSLASH":
        return KEY_BACKSLASH
    elif name == "KEY_RIGHT_BRACKET":
        return KEY_RIGHT_BRACKET
    elif name == "KEY_GRAVE":
        return KEY_GRAVE
    elif name == "KEY_SPACE":
        return KEY_SPACE
    elif name == "KEY_ESCAPE":
        return KEY_ESCAPE
    elif name == "KEY_ENTER":
        return KEY_ENTER
    elif name == "KEY_TAB":
        return KEY_TAB
    elif name == "KEY_BACKSPACE":
        return KEY_BACKSPACE
    elif name == "KEY_INSERT":
        return KEY_INSERT
    elif name == "KEY_DELETE":
        return KEY_DELETE
    elif name == "KEY_RIGHT":
        return KEY_RIGHT
    elif name == "KEY_LEFT":
        return KEY_LEFT
    elif name == "KEY_DOWN":
        return KEY_DOWN
    elif name == "KEY_UP":
        return KEY_UP
    elif name == "KEY_PAGE_UP":
        return KEY_PAGE_UP
    elif name == "KEY_PAGE_DOWN":
        return KEY_PAGE_DOWN
    elif name == "KEY_HOME":
        return KEY_HOME
    elif name == "KEY_END":
        return KEY_END
    elif name == "KEY_CAPS_LOCK":
        return KEY_CAPS_LOCK
    elif name == "KEY_SCROLL_LOCK":
        return KEY_SCROLL_LOCK
    elif name == "KEY_NUM_LOCK":
        return KEY_NUM_LOCK
    elif name == "KEY_PRINT_SCREEN":
        return KEY_PRINT_SCREEN
    elif name == "KEY_PAUSE":
        return KEY_PAUSE
    elif name == "KEY_F1":
        return KEY_F1
    elif name == "KEY_F2":
        return KEY_F2
    elif name == "KEY_F3":
        return KEY_F3
    elif name == "KEY_F4":
        return KEY_F4
    elif name == "KEY_F5":
        return KEY_F5
    elif name == "KEY_F6":
        return KEY_F6
    elif name == "KEY_F7":
        return KEY_F7
    elif name == "KEY_F8":
        return KEY_F8
    elif name == "KEY_F9":
        return KEY_F9
    elif name == "KEY_F10":
        return KEY_F10
    elif name == "KEY_F11":
        return KEY_F11
    elif name == "KEY_F12":
        return KEY_F12
    elif name == "KEY_LEFT_SHIFT":
        return KEY_LEFT_SHIFT
    elif name == "KEY_LEFT_CONTROL":
        return KEY_LEFT_CONTROL
    elif name == "KEY_LEFT_ALT":
        return KEY_LEFT_ALT
    elif name == "KEY_LEFT_SUPER":
        return KEY_LEFT_SUPER
    elif name == "KEY_RIGHT_SHIFT":
        return KEY_RIGHT_SHIFT
    elif name == "KEY_RIGHT_CONTROL":
        return KEY_RIGHT_CONTROL
    elif name == "KEY_RIGHT_ALT":
        return KEY_RIGHT_ALT
    elif name == "KEY_RIGHT_SUPER":
        return KEY_RIGHT_SUPER
    elif name == "KEY_KB_MENU":
        return KEY_KB_MENU
    elif name == "KEY_KP_0":
        return KEY_KP_0
    elif name == "KEY_KP_1":
        return KEY_KP_1
    elif name == "KEY_KP_2":
        return KEY_KP_2
    elif name == "KEY_KP_3":
        return KEY_KP_3
    elif name == "KEY_KP_4":
        return KEY_KP_4
    elif name == "KEY_KP_5":
        return KEY_KP_5
    elif name == "KEY_KP_6":
        return KEY_KP_6
    elif name == "KEY_KP_7":
        return KEY_KP_7
    elif name == "KEY_KP_8":
        return KEY_KP_8
    elif name == "KEY_KP_9":
        return KEY_KP_9
    elif name == "KEY_KP_DECIMAL":
        return KEY_KP_DECIMAL
    elif name == "KEY_KP_DIVIDE":
        return KEY_KP_DIVIDE
    elif name == "KEY_KP_MULTIPLY":
        return KEY_KP_MULTIPLY
    elif name == "KEY_KP_SUBTRACT":
        return KEY_KP_SUBTRACT
    elif name == "KEY_KP_ADD":
        return KEY_KP_ADD
    elif name == "KEY_KP_ENTER":
        return KEY_KP_ENTER
    elif name == "KEY_KP_EQUAL":
        return KEY_KP_EQUAL
    elif name == "KEY_BACK":
        return KEY_BACK
    elif name == "KEY_MENU":
        return KEY_MENU
    elif name == "KEY_VOLUME_UP":
        return KEY_VOLUME_UP
    elif name == "KEY_VOLUME_DOWN":
        return KEY_VOLUME_DOWN
    # --- Gamepad buttons: resolved to GAMEPAD_SENTINEL + button code ---
    elif name == "GAMEPAD_BUTTON_UNKNOWN":
        return GAMEPAD_SENTINEL + GAMEPAD_BUTTON_UNKNOWN
    elif name == "GAMEPAD_BUTTON_LEFT_FACE_UP":
        return GAMEPAD_SENTINEL + GAMEPAD_BUTTON_LEFT_FACE_UP
    elif name == "GAMEPAD_BUTTON_LEFT_FACE_RIGHT":
        return GAMEPAD_SENTINEL + GAMEPAD_BUTTON_LEFT_FACE_RIGHT
    elif name == "GAMEPAD_BUTTON_LEFT_FACE_DOWN":
        return GAMEPAD_SENTINEL + GAMEPAD_BUTTON_LEFT_FACE_DOWN
    elif name == "GAMEPAD_BUTTON_LEFT_FACE_LEFT":
        return GAMEPAD_SENTINEL + GAMEPAD_BUTTON_LEFT_FACE_LEFT
    elif name == "GAMEPAD_BUTTON_RIGHT_FACE_UP":
        return GAMEPAD_SENTINEL + GAMEPAD_BUTTON_RIGHT_FACE_UP
    elif name == "GAMEPAD_BUTTON_RIGHT_FACE_RIGHT":
        return GAMEPAD_SENTINEL + GAMEPAD_BUTTON_RIGHT_FACE_RIGHT
    elif name == "GAMEPAD_BUTTON_RIGHT_FACE_DOWN":
        return GAMEPAD_SENTINEL + GAMEPAD_BUTTON_RIGHT_FACE_DOWN
    elif name == "GAMEPAD_BUTTON_RIGHT_FACE_LEFT":
        return GAMEPAD_SENTINEL + GAMEPAD_BUTTON_RIGHT_FACE_LEFT
    elif name == "GAMEPAD_BUTTON_LEFT_TRIGGER_1":
        return GAMEPAD_SENTINEL + GAMEPAD_BUTTON_LEFT_TRIGGER_1
    elif name == "GAMEPAD_BUTTON_LEFT_TRIGGER_2":
        return GAMEPAD_SENTINEL + GAMEPAD_BUTTON_LEFT_TRIGGER_2
    elif name == "GAMEPAD_BUTTON_RIGHT_TRIGGER_1":
        return GAMEPAD_SENTINEL + GAMEPAD_BUTTON_RIGHT_TRIGGER_1
    elif name == "GAMEPAD_BUTTON_RIGHT_TRIGGER_2":
        return GAMEPAD_SENTINEL + GAMEPAD_BUTTON_RIGHT_TRIGGER_2
    elif name == "GAMEPAD_BUTTON_MIDDLE_LEFT":
        return GAMEPAD_SENTINEL + GAMEPAD_BUTTON_MIDDLE_LEFT
    elif name == "GAMEPAD_BUTTON_MIDDLE":
        return GAMEPAD_SENTINEL + GAMEPAD_BUTTON_MIDDLE
    elif name == "GAMEPAD_BUTTON_MIDDLE_RIGHT":
        return GAMEPAD_SENTINEL + GAMEPAD_BUTTON_MIDDLE_RIGHT
    elif name == "GAMEPAD_BUTTON_LEFT_THUMB":
        return GAMEPAD_SENTINEL + GAMEPAD_BUTTON_LEFT_THUMB
    elif name == "GAMEPAD_BUTTON_RIGHT_THUMB":
        return GAMEPAD_SENTINEL + GAMEPAD_BUTTON_RIGHT_THUMB
    else:
        return KEY_NULL


def key_combo(spec: String) -> List[Int]:
    """Resolve a combo key spec (e.g. "KEY_LEFT_SHIFT+KEY_LEFT") to keycodes.

    Splits on '+'. Each part is resolved via key_code(). If any part is
    unknown (resolves to 0), the entire combo is rejected and an empty
    list is returned. A single-key spec like "KEY_SPACE" returns [32].

    The last keycode in the list is the "trigger" (checked via
    is_key_pressed); all preceding keys are "modifiers" (checked via
    is_key_down).
    """
    var parts = spec.split("+")
    var codes = List[Int]()
    for part in parts:
        var code = key_code(String(part))
        if code == 0:
            return List[Int]()  # Unknown key — reject entire combo
        codes.append(code)
    return codes^
