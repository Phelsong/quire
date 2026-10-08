"""Offline library sync — backfill metadata sidecars for audio on disk.

Downloads made before the sidecar store existed have an audio file in the
cache but no ~/.config/quire/saved/<id>.json, so the offline library can't
show their title/author/progress. This module (functions layer — it may
call both plex_bridge and offline_library) backfills those sidecars from
the server when a connection is available. Run rarely: flagged by a scan,
fired once per library load, entirely skipped when everything already has
a sidecar.
"""

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


def sync_saved_sidecars(mut session: PlexSession) raises -> Int:
    """Backfill sidecars for downloaded IDs that lack one; returns count.

    For each cached audio file stem (all offline-playable books, whatever
    wrote them) with no sidecar, fetch the book detail and write the
    sidecar with the server's viewOffset as the resume point. Books the
    server doesn't know (removed, foreign file) are skipped — their rows
    stay title-less rather than blocking the rest."""
    var token = session.server_token
    if token.byte_length() == 0:
        token = session.account_token
    if token.byte_length() == 0 or session.server_url.byte_length() == 0:
        return 0

    var ids = downloaded_rating_keys(get_audio_cache_dir())
    var backfilled = 0
    for i in range(len(ids)):
        var book_id = ids[i]
        if has_sidecar(book_id):
            continue
        try:
            var detail = get_book_detail(
                session.server_url,
                token,
                book_id,
                session.client_id,
            )
            if detail.rating_key.byte_length() == 0:
                continue  # server doesn't know this ID

            # Detail → card-shaped record for the sidecar.
            var card_shaped = SavedBookMetadata()
            card_shaped.rating_key = detail.rating_key
            card_shaped.title = detail.title
            card_shaped.author = detail.author
            card_shaped.thumb = detail.thumb
            card_shaped.duration_ms = detail.duration_ms
            card_shaped.view_offset_ms = detail.view_offset_ms
            card_shaped.leaf_count = detail.leaf_count
            card_shaped.viewed_leaf_count = detail.viewed_leaf_count
            card_shaped.year = detail.year
            card_shaped.saved_at = Int(perf_counter() * 1000.0)
            save_book_metadata(card_shaped)
            backfilled += 1
        except:
            continue  # one unknown ID never blocks the rest
    return backfilled
