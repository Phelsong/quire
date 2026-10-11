# tests/test_offline_search.mojo — offline search over the sidecar store.
# Run: pixi run mojo -I . tests/test_offline_search.mojo  (wired into `pixi run test`)
#
# 1) matches_saved_query on in-memory SavedBookMetadata (no disk I/O):
#    case-insensitive title/author substrings; empty query matches nothing.
# 2) search_saved_books round-trip: writes temp sidecars with uncollidable
#    rating keys, searches, then removes its files (same self-cleanup
#    pattern as test_offline_library — the rest of the saved dir, if any,
#    is the user's real data and is left untouched).

from std.testing import assert_true, assert_false
from std.pathlib import Path
from std.os import remove, path

from resources.plex_objects import PlexBookCard
from resources.offline_library import (
    SavedBookMetadata,
    get_saved_library_dir,
    matches_saved_query,
    search_saved_books,
    save_book_metadata,
)


def _meta(
    rating_key: String, title: String, author: String
) -> SavedBookMetadata:
    var m = SavedBookMetadata()
    m.rating_key = rating_key
    m.title = title
    m.author = author
    m.saved_at = 1_700_000_000_000
    return m^


def _probe_path(rating_key: String) -> String:
    return get_saved_library_dir() + "/" + rating_key + ".json"


def _cleanup(rating_key: String) raises:
    var probe = Path(_probe_path(rating_key))
    if path.exists(probe):
        _ = remove(probe)


def test_predicate() raises:
    var m = _meta("99999801", "The Way of Kings", "Brandon Sanderson")
    assert_true(matches_saved_query(m, "kings"))
    assert_true(matches_saved_query(m, "the way"))
    assert_true(matches_saved_query(m, "sanderson"))
    assert_true(matches_saved_query(m, "BRANDON"))
    # Empty query matches nothing ("" means "clear search", not "match all").
    assert_false(matches_saved_query(m, ""))
    assert_false(matches_saved_query(m, "abercrombie"))

    # Author-less book: title matches, author never can.
    var silent = _meta("99999802", "Dune", "")
    assert_true(matches_saved_query(silent, "dune"))
    assert_false(matches_saved_query(silent, "herbert"))

    # Author-only book: author matches, title never can.
    var authorless = _meta("99999803", "", "Ursula K. Le Guin")
    assert_true(matches_saved_query(authorless, "le guin"))
    assert_false(matches_saved_query(authorless, "earthsea"))


def test_search_saved_books_empty_query() raises:
    var results = search_saved_books("")
    assert_true(len(results) == 0)
    # A real (non-matching) needle: no probe keys may appear in the
    # results — anything found is pre-existing user data.
    var blank = search_saved_books("zqxjkw-no-such-book")
    for i in range(len(blank)):
        assert_false(blank[i].rating_key.startswith("9999981"))


def test_search_roundtrip() raises:
    var alpha = _meta(
        "99999811", "Offline Search Probe Alpha", "Probe Author Zed"
    )
    var beta = _meta("99999812", "Unrelated Subject", "Probe Author Zed")
    save_book_metadata(alpha)
    save_book_metadata(beta)

    # Title match, case-insensitive, partial.
    var by_title = search_saved_books("probe ALPHA")
    assert_true(_results_contain(by_title, "99999811"))
    assert_false(_results_contain(by_title, "99999812"))

    # Author match returns both probe books.
    var by_author = search_saved_books("author zed")
    assert_true(_results_contain(by_author, "99999811"))
    assert_true(_results_contain(by_author, "99999812"))

    # Card conversion preserved the fields the UI reads.
    for i in range(len(by_author)):
        if by_author[i].rating_key == "99999811":
            if by_author[i].title != "Offline Search Probe Alpha":
                raise Error("card conversion lost title")

    _cleanup("99999811")
    _cleanup("99999812")


def _results_contain(results: List[PlexBookCard], rating_key: String) -> Bool:
    for i in range(len(results)):
        if results[i].rating_key == rating_key:
            return True
    return False


def main() raises:
    test_predicate()
    test_search_saved_books_empty_query()
    test_search_roundtrip()

    # self-cleanup (in case an earlier failed run left probe files)
    _cleanup("99999811")
    _cleanup("99999812")

    print("All offline search tests passed.")
