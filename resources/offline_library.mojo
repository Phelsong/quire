"""Offline library — per-book metadata sidecars on disk.

Each SAVE (download) writes one TOML sidecar next to the config so the
library screen can render downloaded books with NO server connection.
Sidecars live in ~/.config/quire/saved/<rating_key>.toml and mirror the
PlexBookCard listing fields plus a saved_at stamp (ordering).

Serialization is hand-rolled TOML (resources.minitoml) — the JSON
dependency (emberjson/emberserde) is gone; pre-TOML .json sidecars are
skipped by the reader (they self-clean on delete).

conversion to/from PlexBookCard
lives here so callers never touch raw fields.
"""

from resources.minitoml import TomlDoc, TomlSection, parse_toml, utf8_string
from std.collections import List
from std.os import makedirs, path, listdir, remove
from std.pathlib import Path

from resources.plex_objects import PlexBookCard


comptime SAVED_DIR = "~/.config/quire/saved"


def _saved_dir() -> String:
    """Expanded sidecar directory (`~` never auto-expands in Path)."""
    var expanded = String(SAVED_DIR)
    try:
        expanded = String(path.expanduser(SAVED_DIR))
    except:
        pass
    return expanded^


@fieldwise_init
struct SavedBookMetadata(Defaultable, Movable):
    """One downloaded book's listing metadata (offline PlexBookCard)."""

    var rating_key: String
    var title: String
    var author: String
    var thumb: String
    var duration_ms: Int
    var view_offset_ms: Int  # last-known progress (ms), updated on unload
    var leaf_count: Int
    var viewed_leaf_count: Int
    var year: Int
    var saved_at: Int  # epoch ms when the download completed

    def __init__(out self):
        self.rating_key = ""
        self.title = ""
        self.author = ""
        self.thumb = ""
        self.duration_ms = 0
        self.view_offset_ms = 0
        self.leaf_count = 0
        self.viewed_leaf_count = 0
        self.year = 0
        self.saved_at = 0

    def to_card(self) -> PlexBookCard:
        """Convert to the library-screen card type."""
        var card = PlexBookCard()
        card.rating_key = self.rating_key
        card.title = self.title
        card.author = self.author
        card.thumb = self.thumb
        card.duration_ms = self.duration_ms
        card.view_offset_ms = self.view_offset_ms
        card.leaf_count = self.leaf_count
        card.viewed_leaf_count = self.viewed_leaf_count
        card.year = self.year
        return card^


def from_card(book: PlexBookCard, saved_at_ms: Int) -> SavedBookMetadata:
    """Build a sidecar record from a library card (the SAVE-time source)."""
    var meta = SavedBookMetadata()
    meta.rating_key = book.rating_key
    meta.title = book.title
    meta.author = book.author
    meta.thumb = book.thumb
    meta.duration_ms = book.duration_ms
    meta.view_offset_ms = book.view_offset_ms
    meta.leaf_count = book.leaf_count
    meta.viewed_leaf_count = book.viewed_leaf_count
    meta.year = book.year
    meta.saved_at = saved_at_ms
    return meta^


def get_saved_library_dir() -> String:
    """Directory holding the per-book metadata sidecars (expanded)."""
    return String(_saved_dir())


def _sidecar_toml(meta: SavedBookMetadata) -> String:
    """One sidecar record's TOML text (flat root-table fields)."""
    var doc = TomlDoc()
    doc.add("rating_key", meta.rating_key)
    doc.add("title", meta.title)
    doc.add("author", meta.author)
    doc.add("thumb", meta.thumb)
    doc.add("duration_ms", meta.duration_ms)
    doc.add("view_offset_ms", meta.view_offset_ms)
    doc.add("leaf_count", meta.leaf_count)
    doc.add("viewed_leaf_count", meta.viewed_leaf_count)
    doc.add("year", meta.year)
    doc.add("saved_at", meta.saved_at)
    return doc.dump()


def _read_sidecar(file_path: Path) -> Optional[SavedBookMetadata]:
    """Parse one sidecar file. Corrupt/unknown content returns None."""
    try:
        var raw = file_path.read_bytes()
        var tables = parse_toml(utf8_string(raw))
        var root = tables.get("", TomlSection())
        var meta = SavedBookMetadata()
        meta.rating_key = root.strings.get("rating_key", "")
        meta.title = root.strings.get("title", "")
        meta.author = root.strings.get("author", "")
        meta.thumb = root.strings.get("thumb", "")
        meta.duration_ms = root.ints.get("duration_ms", 0)
        meta.view_offset_ms = root.ints.get("view_offset_ms", 0)
        meta.leaf_count = root.ints.get("leaf_count", 0)
        meta.viewed_leaf_count = root.ints.get("viewed_leaf_count", 0)
        meta.year = root.ints.get("year", 0)
        meta.saved_at = root.ints.get("saved_at", 0)
        if meta.rating_key.byte_length() == 0:
            return None
        return meta^
    except:
        return None


def save_book_metadata(mut meta: SavedBookMetadata) raises:
    """Write one book's sidecar TOML (called after a successful download).

    Sidecars are tiny (<1 KB)"""
    var dir_path = Path(_saved_dir())
    makedirs(dir_path, exist_ok=True)

    # A fresh download starts unlistened; progress accrues via
    # update_saved_progress as the user listens.
    meta.view_offset_ms = 0
    var payload = _sidecar_toml(meta)
    var out_path = dir_path / (meta.rating_key + ".toml")
    out_path.write_bytes(Span[UInt8](payload.as_bytes()))


def load_saved_books() -> List[SavedBookMetadata]:
    """Load every sidecar in the saved dir, newest download first.

    The offline rows must mirror "most recently saved first" so a library
    opened with no server still leads with what you grabbed last. Corrupt
    sidecars are skipped silently — one bad file must never take down the
    offline library. Directory absence (nothing ever saved) is normal and
    returns an empty list, not an error. Legacy .json sidecars (pre-TOML
    store) are skipped."""
    var out = List[SavedBookMetadata]()
    var dir_path = Path(_saved_dir())
    if not path.exists(dir_path):
        return out^

    var names: List[String]
    try:
        names = listdir(dir_path)
    except:
        return out^

    for i in range(len(names)):
        var name = String(names[i])
        if not name.endswith(".toml"):
            continue
        var parsed = _read_sidecar(dir_path / names[i])
        if parsed:
            var meta = parsed.take()
            if meta.rating_key.byte_length() > 0:
                out.append(meta^)

    var sorted = List[SavedBookMetadata]()
    var remaining = len(out)
    for _pass in range(remaining):
        var best_idx = 0
        var best_saved = -1
        for j in range(len(out)):
            var candidate_used = False
            for k in range(len(sorted)):
                if sorted[k].rating_key == out[j].rating_key:
                    candidate_used = True
                    break
            ref candidate = out[j]
            if not candidate_used and candidate.saved_at > best_saved:
                best_saved = candidate.saved_at
                best_idx = j

        ref chosen = out[best_idx]
        var copy = SavedBookMetadata()
        copy.rating_key = chosen.rating_key
        copy.title = chosen.title
        copy.author = chosen.author
        copy.thumb = chosen.thumb
        copy.duration_ms = chosen.duration_ms
        copy.view_offset_ms = chosen.view_offset_ms
        copy.leaf_count = chosen.leaf_count
        copy.viewed_leaf_count = chosen.viewed_leaf_count
        copy.year = chosen.year
        copy.saved_at = chosen.saved_at
        sorted.append(copy^)
    return sorted^


def has_sidecar(rating_key: String) -> Bool:
    """True if a metadata sidecar exists for this book."""
    var file_path = Path(_saved_dir()) / (rating_key + ".toml")
    return path.exists(file_path)


def downloaded_rating_keys(audio_dir: String) -> List[String]:
    """Rating keys (file stems) with a cached audio file in `audio_dir`.

    The directory listing is the ground truth for "what can play offline"
    — it covers downloads made before the sidecar store existed (which
    have audio but no metadata yet) without asking the server."""
    var out = List[String]()
    var dir_path = Path(audio_dir)
    if not path.exists(dir_path):
        return out^

    var names: List[String]
    try:
        names = listdir(dir_path)
    except:
        return out^

    var extensions = List[String]()
    extensions.append(".mp3")
    extensions.append(".ogg")
    extensions.append(".wav")
    extensions.append(".m4b")
    extensions.append(".m4a")
    extensions.append(".aac")
    extensions.append(".flac")

    for i in range(len(names)):
        var name = String(names[i])
        var dot = name.rfind(".")
        if dot <= 0:
            continue  # no extension (or dotfile) — not a cache file
        # ends_with costs O(affix) in 1.2; the arm buys a cheap membership
        # test, and the stem is a prefix slice (rating keys are numeric, so
        # byte index == codepoint index here).
        for e in range(len(extensions)):
            if name.endswith(extensions[e]):
                # Prefix slice up to the dot; rating keys are numeric, so
                # byte index == codepoint index here.
                var stem = String(name[byte=0:dot])
                if stem.byte_length() > 0:
                    out.append(stem^)
                break
    return out^


def delete_saved_book(rating_key: String, audio_dir: String) -> Bool:
    """Delete one saved book: its metadata sidecar + cached audio files.

    Removes <saved>/<rating_key>.toml and every audio file in `audio_dir` whose stem is the rating
    key.

    Returns True when at least one file was removed; False means the book
    was already gone (nothing saved, or a previous delete raced this one).
    Per-file failures are swallowed: one unremovable file must never
    block deleting the rest."""
    var anything_removed = False

    var sidecar_path = Path(_saved_dir()) / (rating_key + ".toml")
    if path.exists(sidecar_path):
        try:
            remove(sidecar_path)
            anything_removed = True
        except e:
            print("[Quire] delete sidecar failed: " + String(e))

    var extensions = List[String]()
    extensions.append(".mp3")
    extensions.append(".ogg")
    extensions.append(".wav")
    extensions.append(".m4b")
    extensions.append(".m4a")
    extensions.append(".aac")
    extensions.append(".flac")

    var audio_path = Path(audio_dir)
    for i in range(len(extensions)):
        var candidate = audio_path / (rating_key + String(extensions[i]))
        if path.exists(candidate):
            try:
                remove(candidate)
                anything_removed = True
            except e:
                print("[Quire] delete audio failed: " + String(e))

    return anything_removed


def update_saved_progress(rating_key: String, position_ms: Int) raises:
    """Refresh one sidecar's view_offset (called when playback stops).

    Keeps the offline library's resume point current without a server.
    Skips silently when the sidecar doesn't exist (book not downloaded)."""
    var file_path = Path(_saved_dir()) / (rating_key + ".toml")
    if not path.exists(file_path):
        return

    var parsed = _read_sidecar(file_path)
    if not parsed:
        return
    var meta = parsed.take()
    meta.view_offset_ms = position_ms
    # viewedLeafCount can't be derived from a byte offset offline; leave it.

    var payload = _sidecar_toml(meta)
    file_path.write_bytes(Span[UInt8](payload.as_bytes()))


def matches_saved_query(meta: SavedBookMetadata, query: String) -> Bool:
    """Case-insensitive title/author substring match for offline search.

    The pure half of the offline search (testable without sidecar files).
    Lowers the query itself — callers cannot misfeed an unlowered needle.
    An empty query never matches: "" means "clear search", not "match all"."""
    var query_lower = query.lower()
    if query_lower.byte_length() == 0:
        return False
    if meta.title.lower().find(query_lower) >= 0:
        return True
    return meta.author.lower().find(query_lower) >= 0


def search_saved_books(query: String) -> List[PlexBookCard]:
    """Offline search: filter the sidecar store by title/author substring.

    Used by the library screen when the server is unreachable (known-
    offline session or a failed server search). Order is preserved from
    load_saved_books (newest download first), mirroring the offline
    library view. An empty query returns no matches ("clear" semantics)."""
    var out = List[PlexBookCard]()
    if query.byte_length() == 0:
        return out^

    var saved = load_saved_books()
    for i in range(len(saved)):
        ref meta = saved[i]
        if matches_saved_query(meta, query):
            out.append(meta.to_card())
    return out^
