"""Quire — App configuration (the single source of truth for Config).

Replaces the former Config defined in functions/plex_bridge.mojo.
All modules import Config, load_config, save_config, and
get_or_create_client_id from here.
"""

from std.os import makedirs, path
from std.pathlib import Path
from std.io.file import open
from std.logger import Logger, Level
from std.python import Python

from emberjson import try_deserialize, serialize


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


def get_or_create_client_id() raises -> String:
    """Return a persistent UUID for X-Plex-Client-Identifier.

    Stored in ~/.config/quire/config.json. Generated once, reused forever.
    """
    var config = load_config()
    if config.client_identifier.byte_length() == 36:
        return config.client_identifier

    # UUIDv4 via Python's uuid module ( Mojo uuid conda package ships a
    # stale 1.0.0b1 mojopkg — unusable under 1.0.0).
    var uuid_mod = Python.import_module("uuid")
    config.client_identifier = String(uuid_mod.uuid4().__str__())
    save_config(config)
    return config.client_identifier


def save_config(config: Config) raises:
    """Save config struct to config file."""
    _ensure_config_dir()
    var config_path = Path(path.expanduser(_CONFIG_FILE))
    with open(config_path, "w") as f:
        f.write(serialize[pretty=True](config))


def load_config() raises -> Config:
    """Load config from file as a native Config struct."""
    _ensure_config_dir()
    var config_path = Path(path.expanduser(_CONFIG_FILE))
    if path.exists(config_path):
        try:
            with open(config_path, "r") as f:
                var data = f.read()
                var cfg: Optional[Config] = try_deserialize[Config](data)
                if cfg:
                    return cfg.take()
        except:
            pass
    return Config()
