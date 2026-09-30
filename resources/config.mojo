"""Quire — App configuration (the single source of truth for Config).

Replaces the former Config defined in functions/plex_bridge.mojo.
All modules import Config, load_config, save_config, and
get_or_create_client_id from here.
"""

from std.os import makedirs, path
from std.pathlib import Path
from std.logger import Logger, Level
from std.random import random_ui64, seed
from std.time import perf_counter_ns

from emberjson import try_from_json, to_json
from emberserde.serialize import serialize
from emberserde.deserialize import (
    deserialize,
    Deserializer,
    SelfDescribingDeserializer,
)


comptime _CONFIG_FILE = "~/.config/quire/config.json"

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
    """Sensible default keybinds for audiobook playback."""
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

    Stored in ~/.config/quire/config.json. Generated once, reused forever.
    """
    var config = load_config()
    if config.client_identifier.byte_length() == 36:
        return config.client_identifier

    config.client_identifier = uuid4()
    save_config(config)
    return config.client_identifier


def save_config(config: Config) raises:
    """Save config struct to config file.

    Writes via native Path.write_bytes() — no Python file object (the
    config is a few KB; the `with open` round-trip cost a file-object
    dance on every save, and saves happen on every settings change).
    """
    _ensure_config_dir()
    var config_path = Path(path.expanduser(_CONFIG_FILE))
    var payload = to_json[pretty=True](config)
    config_path.write_bytes(Span[UInt8](payload.as_bytes()))


def load_config() raises -> Config:
    """Load config from file as a native Config struct."""
    _ensure_config_dir()
    var config_path = Path(path.expanduser(_CONFIG_FILE))
    if path.exists(config_path):
        try:
            var raw = config_path.read_bytes()
            # bytes -> String for the JSON parser (config files are small)
            var data = String()
            for i in range(len(raw)):
                data += String(chr(Int(raw[i])))
            var cfg: Optional[Config] = try_from_json[Config](data)
            if cfg:
                return cfg.take()
        except:
            pass
    return Config()
