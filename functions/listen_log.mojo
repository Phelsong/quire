"""listen logger"""

from std.collections import List
from std.time import perf_counter
from std.os import path

from functions.plex_bridge import (
    PlexSession,
    get_book_detail,
    get_audio_cache_dir,
)

from resources.offline_library import (
    SavedBookMetadata,
    downloaded_rating_keys,
    has_sidecar,
    save_book_metadata,
)


# Per Book sidecar?
# Title, rating key, time, offset_ms?
def write_listen_log():
    pass
