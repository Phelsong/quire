# tests/test_offline_library.mojo — round-trip smoke test for the offline
# sidecar store. Run: pixi run mojo tests/test_offline_library.mojo -I .
#
# Writes a temp sidecar, re-reads it, verifies the round-trip, then removes
# its own file. Uses a rating key that can't collide with a real download.

from resources.offline_library import (
    SavedBookMetadata,
    from_card,
    save_book_metadata,
    load_saved_books,
    update_saved_progress,
)
from std.pathlib import Path
from std.os import remove

from resources.plex_objects import PlexBookCard


def main() raises:
    var card = PlexBookCard()
    card.rating_key = "99999990"
    card.title = "Offline Roundtrip Test"
    card.author = "Test Author"
    card.thumb = "/Library/thumb/99999990.jpg"
    card.duration_ms = 36_000_000
    card.leaf_count = 12

    var meta = from_card(card, 1_700_000_000_000)
    var mut_meta = meta^
    save_book_metadata(mut_meta)
    update_saved_progress(card.rating_key, 4_500_000)

    var books = load_saved_books()
    var found = False
    for i in range(len(books)):
        ref b = books[i]
        if b.rating_key == card.rating_key:
            found = True
            if b.title != "Offline Roundtrip Test":
                raise Error("title mismatch")
            if b.view_offset_ms != 4_500_000:
                raise Error("progress round-trip failed")
            var c = b.to_card()
            if c.duration_ms != 36_000_000 or c.leaf_count != 12:
                raise Error("card conversion lost fields")
    if not found:
        raise Error("saved sidecar not found by load_saved_books")

    # self-cleanup
    _ = remove(Path("/home/joshs/.config/quire/saved/99999990.toml"))

    print("All offline library tests passed.")
