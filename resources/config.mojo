"""Quire — App configuration (the single source of truth for Config).

Replaces the former Config defined in functions/plex_bridge.mojo.
All modules import Config, load_config, save_config, and
get_or_create_client_id from here.

The file is hand-rolled TOML (~/.config/quire/config.toml, resources/
minitoml): the ten flat fields ride the root table, the keybind map is
the [keybinds] section. No JSON parser anywhere — save/load map fields
straight onto the struct, and a corrupt file degrades to defaults.
"""

from std.os import makedirs, path
from std.pathlib import Path
from std.logger import Logger, Level
from std.random import random_ui64, seed
from std.time import perf_counter_ns

from resources.minitoml import TomlDoc, TomlSection, parse_toml, utf8_string


comptime _CONFIG_FILE = "~/.config/quire/config.toml"

comptime LOG_LEVEL = Level(Int(30))


struct Config(Copyable, Defaultable, Deinitable, Movable, Writable):
    var client_identifier: String
    var account_token: String
    var server_token: String
    var client_id: String
    var server_url: String
    var server_name: String
    var machine_id: String
    var library_id: String
    var library_name: String
    var username: String
    var font_multiplier: Float64  # User-configurable font size scale (1.0 = default)
    var keybinds: Dict[String, List[String]]  # action name -> key-name strings

    def __init__(out self):
        self.client_identifier = ""
        self.account_token = ""
        self.server_token = ""
        self.client_id = ""
        self.server_url = ""
        self.server_name = ""
        self.machine_id = ""
        self.library_id = ""
        self.library_name = ""
        self.username = ""
        self.font_multiplier = 1.0
        self.keybinds = _default_keybinds()

    def __init__(out self, *, copy: Self):
        self.client_identifier = copy.client_identifier
        self.account_token = copy.account_token
        self.server_token = copy.server_token
        self.client_id = copy.client_id
        self.server_url = copy.server_url
        self.server_name = copy.server_name
        self.machine_id = copy.machine_id
        self.library_id = copy.library_id
        self.library_name = copy.library_name
        self.username = copy.username
        self.font_multiplier = copy.font_multiplier
        self.keybinds = copy.keybinds.copy()

    def write_to(self, mut writer: Some[Writer]):
        writer.write(
            "Config({}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {})".format(
                self.client_identifier,
                self.account_token,
                self.server_token,
                self.client_id,
                self.server_url,
                self.server_name,
                self.machine_id,
                self.library_id,
                self.library_name,
                self.username,
                self.font_multiplier,
                self.keybinds,
            )
        )

    def set_keybind(mut self, action: String, keys: List[String]):
        """Set the keybind list for an action."""
        self.keybinds[action] = keys.copy()

    def get_keybinds(self, action: String) -> List[String]:
        """Return the key-name list for an action, or an empty list if unset."""
        return self.keybinds.get(action, List[String]()).copy()


def _default_keybinds() -> Dict[String, List[String]]:
    """Sensible default keybinds for audiobook playback.

    Spatial-navigation actions (nav_*/select) drive the gamepad focus
    engine in render/imui — the dpad moves focus between UI elements and
    the A face button activates the focused one. LEFT_FACE_* are the
    dpad, RIGHT_FACE_* the ABXY cluster (A=DOWN, B=RIGHT, X=LEFT, Y=UP).
    """
    return {
        "play_pause": ["KEY_SPACE", "GAMEPAD_BUTTON_RIGHT_FACE_UP"],
        "skip_back": ["KEY_LEFT", "GAMEPAD_BUTTON_LEFT_FACE_RIGHT"],
        "skip_forward": ["KEY_RIGHT", "GAMEPAD_BUTTON_LEFT_FACE_LEFT"],
        "prev_chapter": ["KEY_LEFT_SHIFT+KEY_LEFT"],
        "next_chapter": ["KEY_LEFT_SHIFT+KEY_RIGHT"],
        "speed_down": ["KEY_MINUS"],
        "speed_up": ["KEY_EQUAL"],
        "back_button": ["KEY_ESCAPE", "GAMEPAD_BUTTON_RIGHT_FACE_RIGHT"],
        "home": ["KEY_HOME"],
        "nav_up": ["KEY_UP", "GAMEPAD_BUTTON_LEFT_FACE_UP"],
        "nav_down": ["KEY_DOWN", "GAMEPAD_BUTTON_LEFT_FACE_DOWN"],
        "nav_left": ["KEY_LEFT", "GAMEPAD_BUTTON_LEFT_FACE_LEFT"],
        "nav_right": ["KEY_RIGHT", "GAMEPAD_BUTTON_LEFT_FACE_RIGHT"],
        "select": ["KEY_ENTER", "GAMEPAD_BUTTON_RIGHT_FACE_DOWN"],
    }


def _ensure_config_dir() raises:
    """Create the config directory if it does not exist."""
    makedirs(
        Path(path.expanduser("~/.config/quire")),
        exist_ok=True,
    )


def _hex_digit(v: Int) -> String:
    """One lowercase hex digit (0..15)."""
    var digits = "0123456789abcdef"
    return String(digits[byte=v])


def uuid4() -> String:
    """Basic UUIDv4,
    The client identifier needs uniqueness, not crypto strength.
    Sets version 4 and the RFC-4122 variant, format 8-4-4-4-12.
    """
    seed(perf_counter_ns())
    var lo = random_ui64(0, UInt64.MAX)
    var hi = random_ui64(0, UInt64.MAX)
    # 16 bytes, big-endian: bytes[6] version nibble, bytes[8] variant bits.
    var bytes = List[UInt8]()
    bytes.reserve(16)
    var i = 15
    while i >= 8:
        bytes.append(UInt8((hi >> UInt64(8 * (i - 8))) & UInt64(0xFF)))
        i -= 1
    while i >= 0:
        bytes.append(UInt8((lo >> UInt64(8 * i)) & UInt64(0xFF)))
        i -= 1
    bytes[6] = (bytes[6] & 0x0F) | 0x40
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    var out = String()
    for i in range(16):
        if i == 4 or i == 6 or i == 8 or i == 10:
            out += "-"
        out += _hex_digit(Int(bytes[i]) >> 4)
        out += _hex_digit(Int(bytes[i]) & 0xF)
    return out


def get_or_create_client_id() raises -> String:
    """Return a persistent UUID for X-Plex-Client-Identifier.

    Stored in ~/.config/quire/config.toml. Generated once, reused forever.
    """
    var config = load_config()
    if config.client_identifier.byte_length() == 36:
        return config.client_identifier

    config.client_identifier = uuid4()
    save_config(config)
    return config.client_identifier


def _toml_serialize(config: Config) -> String:
    """The config file text: flat fields on the root, keybinds section."""
    var doc = TomlDoc()
    doc.add("client_identifier", config.client_identifier)
    doc.add("account_token", config.account_token)
    doc.add("server_token", config.server_token)
    doc.add("client_id", config.client_id)
    doc.add("server_url", config.server_url)
    doc.add("server_name", config.server_name)
    doc.add("machine_id", config.machine_id)
    doc.add("library_id", config.library_id)
    doc.add("library_name", config.library_name)
    doc.add("username", config.username)
    doc.add("font_multiplier", config.font_multiplier)
    doc.set_section("keybinds")
    for entry in config.keybinds.items():
        doc.add(entry.key, entry.value.copy())
    return doc.dump()


def _config_from_toml(text: String) raises -> Config:
    """Rebuild Config from TOML text.

    Unknown keys are ignored; missing keys keep their struct defaults
    (the keybind map starts from _default_keybinds, and a keybind present
    in the file per-action replaces the default list)."""
    var tables = parse_toml(text)
    var cfg = Config()
    var root = tables.get("", TomlSection())
    cfg.client_identifier = root.strings.get("client_identifier", "")
    cfg.account_token = root.strings.get("account_token", "")
    cfg.server_token = root.strings.get("server_token", "")
    cfg.client_id = root.strings.get("client_id", "")
    cfg.server_url = root.strings.get("server_url", "")
    cfg.server_name = root.strings.get("server_name", "")
    cfg.machine_id = root.strings.get("machine_id", "")
    cfg.library_id = root.strings.get("library_id", "")
    cfg.library_name = root.strings.get("library_name", "")
    cfg.username = root.strings.get("username", "")
    cfg.font_multiplier = root.floats.get("font_multiplier", 1.0)
    var kb = tables.get("keybinds", TomlSection())
    for entry in kb.str_arrays.items():
        cfg.keybinds[entry.key] = entry.value.copy()
    return cfg^


def save_config(config: Config) raises:
    """Save config struct to config file.

    Writes via native Path.write_bytes() — no Python file object (the
    config is a few hundred bytes; saves happen on every settings
    change). Keys are stable TOML, readable by hand.
    """
    _ensure_config_dir()
    var config_path = Path(path.expanduser(_CONFIG_FILE))
    var payload = _toml_serialize(config)
    config_path.write_bytes(Span[UInt8](payload.as_bytes()))


def load_config() raises -> Config:
    """Load config from file as a native Config struct.

    A missing, corrupt, or half-written file returns defaults — same
    contract as before: the app self-heals to a fresh install state
    rather than crashing on startup."""
    _ensure_config_dir()
    var config_path = Path(path.expanduser(_CONFIG_FILE))
    if path.exists(config_path):
        try:
            var raw = config_path.read_bytes()
            return _config_from_toml(utf8_string(raw))
        except:
            pass
    return Config()
