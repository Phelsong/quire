"""Quire — Plex API Bridge.

HTTP calls go through Python httpx (Mojo has no native HTTP client yet), but
the Python boundary is narrow: every public function converts PythonObject
responses into native Mojo structs before returning, so the UI stays pure
Mojo. Headers live in the native PlexHeaders struct and only cross into
Python at the httpx call sites; only _http_get and _xml_to_dict otherwise
touch PythonObject.
"""

from std.logger import Logger, Level
from std.python import Python, PythonObject
from std.python.conversions import ConvertibleToPython
from std.os import makedirs, path, remove, getenv
from std.pathlib import Path

from ui.plex_objects import (
    PlexTrack,
    PlexChapter,
    ServerItem,
    LibraryItem,
    PlexBookCard,
)
from ui.plex_api_types import (
    ServerTestResult,
    AccountInfo,
    AudiobookResult,
    BookDetail,
    PlayQueueResult,
    PlayQueueItem,
    PlaybackDecision,
    CollectionItem,
)
from functions.helpers import _mojo_rename
from resources.config import (
    Config,
    load_config,
    save_config,
    get_or_create_client_id,
    LOG_LEVEL
)

# ---------------------------------------------------------------------------
# Plex session — authenticated session data
# ---------------------------------------------------------------------------


struct PlexSession(Movable):
    """Authenticated session."""

    var account_token: String  # OAuth token from plex.tv
    var server_token: String  # Server-specific token (from resources API, may be empty)
    var client_id: String  # Persistent UUID for X-Plex-Client-Identifier
    var server_url: String  # Selected server URL (e.g. https://192.168.1.100:32400)
    var server_name: String  # Server display name
    var machine_id: String  # Server's clientIdentifier (for play queue URIs)
    var library_id: String  # Selected audiobook library ID
    var library_name: String  # Selected library display name
    var username: String
    var logged_in: Bool

    def __init__(out self):
        self.account_token = ""
        self.server_token = ""
        self.client_id = ""
        self.server_url = ""
        self.server_name = ""
        self.machine_id = ""
        self.library_id = ""
        self.library_name = ""
        self.username = ""
        self.logged_in = False


def _hex_digit(n: Int) -> String:
    """Return the uppercase hex digit for a nibble 0-15."""
    if n < 10:
        return String(chr(n + ord("0")))
    return String(chr(n - 10 + ord("A")))


def _percent_encode(s: String) -> String:
    """Percent-encode a string for URL query parameters (RFC 3986).

    Encodes everything except unreserved characters (A-Z, a-z, 0-9, -._~).
    Spaces become %20 (not +). Replaces Python urllib.parse.quote.
    """
    var result = String()
    for i in range(s.byte_length()):
        var ch = s[byte=i]
        var code = ord(ch)
        var is_unreserved = (
            (code >= ord("A") and code <= ord("Z"))
            or (code >= ord("a") and code <= ord("z"))
            or (code >= ord("0") and code <= ord("9"))
            or ch == "-"
            or ch == "."
            or ch == "_"
            or ch == "~"
        )
        if is_unreserved:
            result += String(ch)
        else:
            result += "%" + _hex_digit(code >> 4) + _hex_digit(code & 0xF)
    return result


# ---------------------------------------------------------------------------
# Plex headers
# ---------------------------------------------------------------------------

comptime PRODUCT_NAME = "Quire"
comptime PRODUCT_VERSION = "0.1.0"


@fieldwise_init
struct PlexHeaders(ConvertibleToPython, Copyable, Movable):
    """Request headers as native Mojo state, converted to a Python dict
    only at the httpx boundary (via ConvertibleToPython)."""

    var _entries: Dict[String, String]

    def __init__(out self):
        self._entries = Dict[String, String]()

    def __setitem__(mut self, key: String, value: String):
        self._entries[key] = value

    def __getitem__(self, key: String) raises -> String:
        return self._entries[key]

    def to_python_object(var self) raises -> PythonObject:
        var py = Python.dict()
        for entry in self._entries.items():
            py[entry.key] = entry.value
        return py


def plex_headers(
    token: String = "", client_id: String = ""
) raises -> PlexHeaders:
    """Build standard Plex API headers required for every request.

    Returns native PlexHeaders — headers are pure Mojo state until the
    httpx call converts them.
    """
    var os = Python.import_module("os")
    var cid = client_id
    if cid.byte_length() == 0:
        cid = get_or_create_client_id()

    var headers = PlexHeaders()
    headers["Accept"] = "application/json"
    headers["X-Plex-Product"] = PRODUCT_NAME
    headers["X-Plex-Version"] = PRODUCT_VERSION
    headers["X-Plex-Client-Identifier"] = cid
    headers["X-Plex-Platform"] = "Linux"
    headers["X-Plex-Device"] = PRODUCT_NAME + " Linux"
    headers["X-Plex-Device-Name"] = String(os.uname().nodename)
    headers["X-Plex-Client-Name"] = PRODUCT_NAME
    headers["X-Plex-Provides"] = "player"
    headers["X-Plex-Client-Profile-Extra"] = (
        "add-direct-play-profile("
        "type=musicProfile"
        "&container=mp4,m4a,m4b,mp3,flac,ogg,opus"
        "&audioCodec=aac,mp3,flac,vorbis,opus"
        "&videoCodec=*"
        "&subtitleCodec=*)"
    )
    if token.byte_length() > 0:
        headers["X-Plex-Token"] = token
    return headers^


# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------


def _http_get(
    url: String, headers: PlexHeaders, timeout: Float64 = 30.0
) raises -> PythonObject:
    """GET request via httpx, parse JSON or XML response to dict.

    This is the Python boundary: callers get a PythonObject payload back,
    which they immediately convert into native Mojo structs.
    """
    var httpx = Python.import_module("httpx")
    
    var logger = Logger[LOG_LEVEL]()
    var resp = httpx.get(
        url,
        headers=headers.copy().to_python_object(),
        timeout=PythonObject(timeout),
        verify=False,
    )

    var status_code = Int(py=resp.status_code)
    if status_code >= 400:
        logger.warning("[plex_bridge] GET " + url + " -> " + String(status_code))
        logger.warning("[plex_bridge] Response: " + String(resp.text[0:500]))

    resp.raise_for_status()

    var content_type = String(resp.headers.get("content-type", ""))
    var text = String(resp.text)
    var stripped = text.strip()

    if content_type.find("json") >= 0 or stripped.startswith("{"):
        return resp.json()
    elif content_type.find("xml") >= 0 or stripped.startswith("<"):
        return _xml_to_dict(text)
    else:
        var result: PythonObject = {"raw": text}
        return result


def _http_post_form(
    url: String,
    headers: PlexHeaders,
    body: Dict[String, String],
    timeout: Float64 = 30.0,
) raises -> PythonObject:
    """POST request with urlencoded form body, parse JSON or XML response.

    Companion to _http_get — same Python boundary, native Mojo inputs.
    """
    var httpx = Python.import_module("httpx")

    # Build the urlencoded body natively (matches requests' data=dict form).
    var encoded = String()
    var first = True
    for entry in body.items():
        if not first:
            encoded += "&"
        first = False
        encoded += (
            _percent_encode(entry.key) + "=" + _percent_encode(entry.value)
        )

    var resp = httpx.post(
        url,
        headers=headers.copy().to_python_object(),
        content=PythonObject(encoded),
        timeout=PythonObject(timeout),
        verify=False,
    )

    var status_code = Int(py=resp.status_code)
    if status_code >= 400:
        print("[plex_bridge] POST " + url + " -> " + String(status_code))
        print("[plex_bridge] Response: " + String(resp.text[0:200]))

    resp.raise_for_status()

    var content_type = String(resp.headers.get("content-type", ""))
    var text = String(resp.text)
    var stripped = text.strip()

    if content_type.find("json") >= 0 or stripped.startswith("{"):
        return resp.json()
    elif content_type.find("xml") >= 0 or stripped.startswith("<"):
        return _xml_to_dict(text)
    else:
        var result: PythonObject = {"raw": text}
        return result


# ---------------------------------------------------------------------------
# XML parsing helper (implemented in Python via evaluate, compiled once)
# ---------------------------------------------------------------------------


comptime _XML_MOD_KEY = "_QUIRE_XML_PARSER_MODULE"


def _xml_module() raises -> PythonObject:
    """Compile the XML-to-dict Python helper once, lazily.

    Mojo 1.0.0 forbids module-level `var` state and a comptime struct
    singleton cannot be materialized mutably, so the compiled module is
    stashed as an attribute on the Python `builtins` module — a process-
    live cache visible across calls (probed: survives and round-trips).
    """
    var builtins = Python.import_module("builtins")
    try:
        var cached = builtins._QUIRE_XML_PARSER_MODULE
        if Bool(cached):
            return cached
    except:
        pass
    var mod = Python.evaluate(
        """
import defusedxml.ElementTree as ET

def xml_to_dict(xml_str):
    root = ET.fromstring(xml_str)

    def element_to_dict(element):
        result = dict(element.attrib)
        children = list(element)
        if children:
            for child in children:
                tag = child.tag
                child_dict = element_to_dict(child)
                if tag in result:
                    existing = result[tag]
                    if isinstance(existing, list):
                        existing.append(child_dict)
                    else:
                        result[tag] = [existing, child_dict]
                else:
                    result[tag] = child_dict
        return result

    result = element_to_dict(root)
    if isinstance(result, dict):
        return result
    return {"value": result}
""",
        file=True,
    )
    builtins._QUIRE_XML_PARSER_MODULE = mod
    return mod


def _xml_to_dict(xml_str: String) raises -> PythonObject:
    """Parse Plex XML response to a dict (simplified)."""
    var mod = _xml_module()
    return mod.xml_to_dict(xml_str)


# ---------------------------------------------------------------------------
# Streaming download helper (implemented in Python via evaluate, compiled once)
# ---------------------------------------------------------------------------


comptime _DOWNLOADER_MOD_KEY = "_QUIRE_DOWNLOADER_MODULE"


def _downloader_module() raises -> PythonObject:
    """Compile the streaming file-download helper once, lazily.

    Same process-live cache trick as _xml_module: the compiled module is
    stashed on `builtins`. The download runs entirely in Python (httpx
    client.stream → iter_bytes → file.write), so a multi-hundred-MB
    audiobook never enters Mojo memory — Mojo only sees the returned
    content-type string.
    """
    var builtins = Python.import_module("builtins")
    try:
        var cached = builtins._QUIRE_DOWNLOADER_MODULE
        if Bool(cached):
            return cached
    except:
        pass
    var mod = Python.evaluate(
        """
import httpx

def stream_download(url, headers, path, timeout=120.0):
    with httpx.Client(verify=False, timeout=timeout) as client:
        with client.stream("GET", url, headers=headers) as resp:
            resp.raise_for_status()
            content_type = resp.headers.get("content-type", "")
            with open(path, "wb") as out:
                for chunk in resp.iter_bytes(65536):
                    out.write(chunk)
    return content_type
""",
        file=True,
    )
    builtins._QUIRE_DOWNLOADER_MODULE = mod
    return mod


# ---------------------------------------------------------------------------
# Account info
# ---------------------------------------------------------------------------


def get_account_info(
    account_token: String, client_id: String = ""
) raises -> AccountInfo:
    """Fetch Plex account info (username, email, title).

    GET https://plex.tv/users/account.json
    Returns AccountInfo struct.
    """
    var headers = plex_headers(token=account_token, client_id=client_id)
    try:
        var data = _http_get("https://plex.tv/users/account.json", headers)
        var user = data.get("user", data)
        var result = AccountInfo()
        result.username = String(user["username"])
        result.email = String(user["email"])
        result.title = String(
            user.get(
                "title",
                user.get("friendlyName", ""),
            )
        )
        result.id = String(user["id"])
        return result^
    except:
        return AccountInfo()


# ---------------------------------------------------------------------------
# Server discovery
# ---------------------------------------------------------------------------


def _as_list(value: PythonObject) raises -> PythonObject:
    """Normalize a single dict to a one-item list; pass lists through."""
    var type_name = String(value.__class__.__name__)
    if type_name == "list":
        return value
    if type_name == "dict":
        var lst = Python.list()
        lst.append(value)
        return lst
    return Python.list()


def get_servers(
    account_token: String, client_id: String = ""
) raises -> List[ServerItem]:
    """Discover user's Plex servers via plex.tv.

    Returns list of ServerItem structs.
    """
    var headers = plex_headers(token=account_token, client_id=client_id)
    var data = _http_get(
        "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1",
        headers,
    )
    var servers = List[ServerItem]()

    # Normalize single server dict into a list
    var server_list: PythonObject
    if String(data.__class__.__name__) == "list":
        server_list = data
    elif String(data.__class__.__name__) == "dict" and Bool(py="name" in data):
        server_list = Python.list(data)
    else:
        return servers^

    var count = len(server_list)
    for i in range(count):
        var s = server_list[i]
        var item = ServerItem()
        item.name = String(s["name"])
        item.token = String(s["accessToken"])
        item.machine_id = String(s["clientIdentifier"])
        item.is_owned = Bool(py=s["owned"])

        # Extract best connection URL
        var connections = s["connections"]
        var conn_count = len(connections)
        var best_url = String()
        for j in range(conn_count):
            var conn = connections[j]
            var conn_url = String(conn["uri"])
            # Prefer HTTPS connections
            if conn_url.startswith("https"):
                best_url = conn_url
                break
            if best_url.byte_length() == 0:
                best_url = conn_url

        if best_url.byte_length() == 0:
            # Fallback: test each connection
            for j in range(conn_count):
                var conn = connections[j]
                var candidate_url = String(conn["uri"])
                var test_result = test_server(
                    candidate_url, item.token, client_id
                )
                if test_result.ok:
                    best_url = candidate_url
                    break

        if best_url.byte_length() > 0:
            item.url = best_url
            servers.append(item)

    return servers^


def test_server(
    server_url: String, token: String, client_id: String = ""
) raises -> ServerTestResult:
    """Test if a Plex server is reachable.

    Returns ServerTestResult struct with ok, name, machine_id, error.
    """
    var headers = plex_headers(token=token, client_id=client_id)
    try:
        var data = _http_get(server_url + "/identity", headers)
        if "MediaContainer" in data:
            data = data["MediaContainer"]
        var result = ServerTestResult()
        result.ok = True
        result.name = String(
            data.get(
                "friendlyName",
                data.get("name", ""),
            )
        )
        result.machine_id = String(data["machineIdentifier"])
        return result^
    except e:
        var error_msg = String(e)
        print(
            "[plex_bridge] test_server failed for "
            + server_url
            + ": "
            + error_msg
        )
        var result = ServerTestResult()
        result.ok = False
        result.error = error_msg
        return result^


def find_best_connection(
    server_url: String, token: String, client_id: String = ""
) raises -> String:
    """Test server connections and return the first working URL."""
    var headers = plex_headers(token=token, client_id=client_id)
    try:
        _ = _http_get(server_url + "/identity", headers)
        return server_url
    except:
        return ""


# ---------------------------------------------------------------------------
# Library browsing
# ---------------------------------------------------------------------------


def get_libraries(
    server_url: String, token: String, client_id: String = ""
) raises -> List[LibraryItem]:
    """List all libraries on the server.

    Returns list of LibraryItem structs.
    """
    var headers = plex_headers(token=token, client_id=client_id)
    var data = _http_get(server_url + "/library/sections", headers)
    var container = data.get("MediaContainer", data)
    var dirs = container.get("Directory", Python.list())
    dirs = _as_list(dirs)

    var libraries = List[LibraryItem]()
    var count = len(dirs)
    for i in range(count):
        var d = dirs[i]
        var item = LibraryItem()
        item.key = String(d["key"])
        item.title = String(d["title"])
        item.lib_type = String(d["type"])
        libraries.append(item)
    return libraries^


def get_audiobooks(
    server_url: String,
    token: String,
    library_id: String,
    start: Int = 0,
    size: Int = 100,
    client_id: String = "",
) raises -> AudiobookResult:
    """Get audiobooks (albums, type=9) from a library.

    Returns AudiobookResult struct with total_size, items, and error_code.
    """
    var headers = plex_headers(token=token, client_id=client_id)
    headers["X-Plex-Container-Start"] = String(start)
    headers["X-Plex-Container-Size"] = String(size)

    var url = "{}/library/sections/{}/all?type=9".format(server_url, library_id)
    var data: PythonObject

    try:
        data = _http_get(url, headers)
    except e:
        # Fallback: try without type filter (some servers reject type=9)
        print("[plex_bridge] get_audiobooks primary URL failed: " + String(e))
        url = "{}/library/sections/{}/all".format(server_url, library_id)
        try:
            data = _http_get(url, headers)
        except e2:
            print(
                "[plex_bridge] get_audiobooks fallback URL also failed: "
                + String(e2)
            )
            var err_result = AudiobookResult()
            err_result.error_code = 500
            return err_result^

    try:
        var container = data.get("MediaContainer", data)
        var total_size_val = Int(
            py=container.get(
                "totalSize",
                container.get("size", 0),
            )
        )
        var metadata = container.get("Metadata", Python.list())
        metadata = _as_list(metadata)

        var items = List[PlexBookCard]()
        var count = len(metadata)
        for i in range(count):
            var m = metadata[i]
            var card = PlexBookCard()
            card.rating_key = String(m["ratingKey"])
            card.title = String(m["title"])
            card.author = String(m["parentTitle"])
            card.thumb = String(m.get("thumb", ""))
            card.duration_ms = Int(py=m.get("duration", 0))
            card.view_offset_ms = Int(py=m.get("viewOffset", 0))
            card.leaf_count = Int(py=m.get("leafCount", 0))
            card.viewed_leaf_count = Int(py=m.get("viewedLeafCount", 0))
            var year_obj = m.get("year", 0)
            if Int(py=year_obj) != 0:
                card.year = Int(py=year_obj)
            items.append(card)

        var result = AudiobookResult()
        result.total_size = total_size_val
        result.items = items^
        return result^
    except e:
        print(
            "[plex_bridge] get_audiobooks data processing failed: " + String(e)
        )
        var err_result = AudiobookResult()
        err_result.error_code = 500
        return err_result^


def search_audiobooks(
    server_url: String,
    token: String,
    library_id: String,
    query: String,
    client_id: String = "",
) raises -> AudiobookResult:
    """Search audiobooks across the whole library by title (server-side).

    Uses Plex's `title=<query>` filter on the section's `all` endpoint. This
    searches the entire library regardless of pagination state, returning all
    matches (capped at 500). An empty query returns an empty result list.

    Falls back to client-side substring matching on title + author if the
    server rejects the title= filter (older servers).
    """
    var result = AudiobookResult()
    if query.byte_length() == 0:
        return result

    var headers = plex_headers(token=token, client_id=client_id)
    headers["X-Plex-Container-Start"] = "0"
    headers["X-Plex-Container-Size"] = "500"

    # URL-encode the query for the title= parameter (Mojo-native, no Python).
    var encoded_query = _percent_encode(query)
    var url = "{}/library/sections/{}/all?type=9&title={}".format(
        server_url, library_id, encoded_query
    )

    var data: PythonObject
    try:
        data = _http_get(url, headers)
    except e:
        # Fallback: try without type filter.
        url = "{}/library/sections/{}/all?title={}".format(
            server_url, library_id, encoded_query
        )
        try:
            data = _http_get(url, headers)
        except e2:
            print("[plex_bridge] search_audiobooks failed: " + String(e2))
            result.error_code = 500
            return result^

    try:
        var container = data.get("MediaContainer", data)
        var total_size_val = Int(
            py=container.get(
                "totalSize",
                container.get("size", 0),
            )
        )
        var metadata = container.get("Metadata", Python.list())
        metadata = _as_list(metadata)

        # Client-side author fallback: if title= returned nothing, try
        # fetching a larger batch and filtering on title+author locally.
        var count = len(metadata)
        if count == 0:
            var broad = _search_by_author(
                server_url, token, library_id, query, client_id
            )
            return broad^

        var items = List[PlexBookCard]()
        for i in range(count):
            var m = metadata[i]
            var card = PlexBookCard()
            card.rating_key = String(m["ratingKey"])
            card.title = String(m["title"])
            card.author = String(m["parentTitle"])
            card.thumb = String(m.get("thumb", ""))
            card.duration_ms = Int(py=m.get("duration", 0))
            card.view_offset_ms = Int(py=m.get("viewOffset", 0))
            card.leaf_count = Int(py=m.get("leafCount", 0))
            card.viewed_leaf_count = Int(py=m.get("viewedLeafCount", 0))
            var year_obj = m.get("year", 0)
            if Int(py=year_obj) != 0:
                card.year = Int(py=year_obj)
            items.append(card)

        result.total_size = total_size_val
        result.items = items^
        return result^
    except e:
        print(
            "[plex_bridge] search_audiobooks data processing failed: "
            + String(e)
        )
        result.error_code = 500
        return result^


def _search_by_author(
    server_url: String,
    token: String,
    library_id: String,
    query: String,
    client_id: String,
) raises -> AudiobookResult:
    """Fallback: fetch a large batch and filter client-side on title+author.

    Used when the server's title= filter returns no results (some Plex
    configurations don't support it). Lowercases both the query and the
    fields for case-insensitive substring matching.
    """
    var result = AudiobookResult()
    var headers = plex_headers(token=token, client_id=client_id)
    headers["X-Plex-Container-Start"] = "0"
    headers["X-Plex-Container-Size"] = "500"
    var url = "{}/library/sections/{}/all?type=9".format(server_url, library_id)

    var data: PythonObject
    try:
        data = _http_get(url, headers)
    except e:
        url = "{}/library/sections/{}/all".format(server_url, library_id)
        try:
            data = _http_get(url, headers)
        except e2:
            result.error_code = 500
            return result^

    try:
        var container = data.get("MediaContainer", data)
        var metadata = container.get(
            "Metadata",
            Python.list(),
        )
        metadata = _as_list(metadata)

        # Lowercase the query once (Mojo String.lower, no Python needed).
        var query_lower = query.lower()

        var items = List[PlexBookCard]()
        var count = len(metadata)
        for i in range(count):
            var m = metadata[i]
            var title = String(m["title"])
            var author = String(m["parentTitle"])
            var title_lower = title.lower()
            var author_lower = author.lower()
            if (
                title_lower.find(query_lower) < 0
                and author_lower.find(query_lower) < 0
            ):
                continue
            var card = PlexBookCard()
            card.rating_key = String(m["ratingKey"])
            card.title = title
            card.author = author
            card.thumb = String(m.get("thumb", ""))
            card.duration_ms = Int(py=m.get("duration", 0))
            card.view_offset_ms = Int(py=m.get("viewOffset", 0))
            card.leaf_count = Int(py=m.get("leafCount", 0))
            card.viewed_leaf_count = Int(py=m.get("viewedLeafCount", 0))
            var year_obj = m.get("year", 0)
            if Int(py=year_obj) != 0:
                card.year = Int(py=year_obj)
            items.append(card)

        result.total_size = len(items)
        result.items = items^
        # TODO: add content caching here
        return result^
    except e:
        result.error_code = 500
        return result^


def get_book_detail(
    server_url: String, token: String, book_id: String, client_id: String = ""
) raises -> BookDetail:
    """Get full book (album) metadata with chapters.

    Returns BookDetail struct.
    """
    var headers = plex_headers(token=token, client_id=client_id)
    var url = "{}/library/metadata/{}?includeChapters=1".format(
        server_url, book_id
    )
    var data = _http_get(url, headers)

    var container = data.get("MediaContainer", data)
    var metadata_list = container.get("Metadata", Python.list())
    metadata_list = _as_list(metadata_list)
    if len(metadata_list) == 0:
        return BookDetail()

    var m = metadata_list[0]
    var result = BookDetail()
    result.rating_key = String(m["ratingKey"])
    result.title = String(m["title"])
    result.author = String(
        m.get(
            "parentTitle",
            m.get("grandparentTitle", ""),
        )
    )
    result.thumb = String(m.get("thumb", ""))
    result.duration_ms = Int(py=m.get("duration", 0))
    result.view_offset_ms = Int(py=m.get("viewOffset", 0))
    result.leaf_count = Int(py=m.get("leafCount", 0))
    result.viewed_leaf_count = Int(py=m.get("viewedLeafCount", 0))
    var year_obj = m.get("year", 0)
    if Int(py=year_obj) != 0:
        result.year = Int(py=year_obj)
    result.summary = String(m.get("summary", ""))

    # Genres
    var genre_list = m.get("Genre", Python.list())
    genre_list = _as_list(genre_list)
    var gcount = len(genre_list)
    for i in range(gcount):
        var g = genre_list[i]
        result.genres.append(String(g.get("tag", "")))

    # Chapters (from detail level — may be empty, filled later by get_track_chapters)
    result.chapters = List[PlexChapter]()

    return result^


def get_book_tracks(
    server_url: String, token: String, book_id: String, client_id: String = ""
) raises -> List[PlexTrack]:
    """Get tracks (children) for a book.

    Returns list of PlexTrack structs.
    """
    var headers = plex_headers(token=token, client_id=client_id)
    var url = "{}/library/metadata/{}/children".format(server_url, book_id)
    var data = _http_get(url, headers)

    var container = data.get("MediaContainer", data)
    var metadata = container.get("Metadata", Python.list())
    metadata = _as_list(metadata)

    var tracks = List[PlexTrack]()
    var count = len(metadata)
    for i in range(count):
        var m = metadata[i]
        var track = PlexTrack()
        track.rating_key = String(m["ratingKey"])
        track.title = String(m["title"])
        track.index = Int(py=m.get("index", 0))
        track.duration_ms = Int(py=m.get("duration", 0))
        track.view_offset_ms = Int(py=m.get("viewOffset", 0))

        # Extract file_key from Media > Part
        var file_key = ""
        var media_list = m.get("Media", Python.list())
        media_list = _as_list(media_list)
        if len(media_list) > 0:
            var parts = media_list[0].get("Part", Python.list())
            parts = _as_list(parts)
            if len(parts) > 0:
                file_key = String(parts[0]["key"])
        track.file_key = file_key
        tracks.append(track)

    return tracks^


def get_track_chapters(
    server_url: String, token: String, track_id: String, client_id: String = ""
) raises -> List[PlexChapter]:
    """Get chapters for a specific track.

    Returns list of PlexChapter structs.
    """
    var headers = plex_headers(token=token, client_id=client_id)
    var url = "{}/library/metadata/{}?includeChapters=1".format(
        server_url, track_id
    )
    var data = _http_get(url, headers)

    var container = data.get("MediaContainer", data)
    var metadata_list = container.get("Metadata", Python.list())
    metadata_list = _as_list(metadata_list)
    if len(metadata_list) == 0:
        return List[PlexChapter]()

    var m = metadata_list[0]
    var chapters_raw = m.get(
        "Chapter",
        m.get("Chapters", Python.list()),
    )
    chapters_raw = _as_list(chapters_raw)

    var chapters = List[PlexChapter]()
    var count = len(chapters_raw)
    for i in range(count):
        var c = chapters_raw[i]
        var chapter = PlexChapter()
        chapter.id = Int(py=c.get("id", 0))
        chapter.index = Int(py=c.get("index", 0))
        chapter.tag = String(c.get("tag", ""))
        chapter.start_time_ms = Int(py=c.get("startTimeOffset", 0))
        chapter.end_time_ms = Int(py=c.get("endTimeOffset", 0))
        chapter.is_current = False
        chapters.append(chapter)
    return chapters^


# ---------------------------------------------------------------------------
# Collections
# ---------------------------------------------------------------------------


def get_collections(
    server_url: String,
    token: String,
    library_id: String,
    start: Int = 0,
    size: Int = 100,
    client_id: String = "",
) raises -> List[CollectionItem]:
    """Get collections in a library.

    Returns list of CollectionItem structs.
    """
    var headers = plex_headers(token=token, client_id=client_id)
    headers["X-Plex-Container-Start"] = String(start)
    headers["X-Plex-Container-Size"] = String(size)

    var url = "{}/library/sections/{}/collections?includeCollections=1".format(
        server_url, library_id
    )
    var data = _http_get(url, headers)

    var container = data.get("MediaContainer", data)
    var directories = container.get(
        "Directory",
        container.get("Metadata", Python.list()),
    )
    directories = _as_list(directories)

    var collections = List[CollectionItem]()
    var count = len(directories)
    for i in range(count):
        var d = directories[i]
        var item = CollectionItem()
        item.rating_key = String(d["ratingKey"])
        item.title = String(d["title"])
        item.child_count = Int(py=d.get("childCount", 0))
        collections.append(item)
    return collections^


def get_collection_books(
    server_url: String,
    token: String,
    collection_id: String,
    client_id: String = "",
) raises -> List[PlexBookCard]:
    """Get books in a collection.

    Returns list of PlexBookCard structs.
    """
    var headers = plex_headers(token=token, client_id=client_id)
    var url = "{}/library/collections/{}/children".format(
        server_url, collection_id
    )
    var data = _http_get(url, headers)

    var container = data.get("MediaContainer", data)
    var metadata = container.get("Metadata", Python.list())
    metadata = _as_list(metadata)

    var items = List[PlexBookCard]()
    var count = len(metadata)
    for i in range(count):
        var m = metadata[i]
        var card = PlexBookCard()
        card.rating_key = String(m["ratingKey"])
        card.title = String(m["title"])
        card.author = String(m["parentTitle"])
        card.thumb = String(m.get("thumb", ""))
        card.duration_ms = Int(py=m.get("duration", 0))
        card.view_offset_ms = Int(py=m.get("viewOffset", 0))
        card.leaf_count = Int(py=m.get("leafCount", 0))
        card.viewed_leaf_count = Int(py=m.get("viewedLeafCount", 0))
        var year_obj = m.get("year", 0)
        if Int(py=year_obj) != 0:
            card.year = Int(py=year_obj)
        items.append(card)
    return items^


# ---------------------------------------------------------------------------
# Playback URL resolution
# ---------------------------------------------------------------------------


def get_playback_decision(
    server_url: String,
    token: String,
    track_path: String,
    session_id: String,
    client_id: String = "",
) raises -> PlaybackDecision:
    """Negotiate playback method for a track.

    GET /music/:/transcode/universal/decision
    Returns PlaybackDecision struct.
    """
    var headers = plex_headers(token=token, client_id=client_id)

    # Native Mojo query params → URL query string (percent-encoded).
    var params = Dict[String, String]()
    params["path"] = track_path
    params["protocol"] = "http"
    params["session"] = session_id
    params["hasMDE"] = "1"
    params["directPlay"] = "1"
    params["directStream"] = "1"
    params["musicBitrate"] = "320"
    params["maxAudioBitrate"] = "320"
    var query = String()
    var first = True
    for entry in params.items():
        if not first:
            query += "&"
        first = False
        query += entry.key + "=" + _percent_encode(entry.value)

    var url = server_url + "/music/:/transcode/universal/decision?" + query

    var data: PythonObject
    try:
        data = _http_get(url, headers)
    except:
        return PlaybackDecision()

    var container = data.get("MediaContainer", data)
    var general_code = Int(py=container.get("generalDecisionCode", 0))
    var direct_play_code = Int(py=container.get("directPlayDecisionCode", 0))
    var transcode_code = Int(py=container.get("transcodeDecisionCode", 0))

    var stream_url = ""
    var is_direct = direct_play_code == 1000

    var metadata_list = container.get(
        "Metadata",
        container.get("Track", Python.list()),
    )
    metadata_list = _as_list(metadata_list)

    if len(metadata_list) > 0:
        var media_list = metadata_list[0].get("Media", Python.list())
        media_list = _as_list(media_list)
        if len(media_list) > 0:
            var selected_media = Python.none()
            var mcount = len(media_list)
            for i in range(mcount):
                var media = media_list[i]
                var sel = media.get("selected", 0)
                if String(sel) == "1" or Bool(py=sel):
                    selected_media = media
                    break
            if not (selected_media == Python.none()):
                selected_media = media_list[0]

            if not (selected_media == Python.none()):
                var parts = selected_media.get("Part", Python.list())
                parts = _as_list(parts)
                if len(parts) > 0:
                    var selected_part = Python.none()
                    var pcount = len(parts)
                    for i in range(pcount):
                        var part = parts[i]
                        var sel = part.get("selected", 0)
                        if String(sel) == "1" or Bool(py=sel):
                            selected_part = part
                            break
                    if selected_part == Python.none():
                        selected_part = parts[0]

                    stream_url = String(selected_part["key"])
                    if (
                        stream_url.byte_length() > 0
                        and not stream_url.startswith("http")
                    ):
                        stream_url = server_url + stream_url

    var decision_code = general_code
    if decision_code == 0:
        if is_direct:
            decision_code = direct_play_code
        else:
            decision_code = transcode_code

    var result = PlaybackDecision()
    result.decision_code = decision_code
    result.stream_url = stream_url
    result.is_direct_play = is_direct
    return result^


def clear_playback_cache():
    """Clear the playback URL cache (no-op; cache not implemented in Mojo wrapper).
    """
    pass


# ---------------------------------------------------------------------------
# Play queue & progress
# ---------------------------------------------------------------------------


def start_play_queue(
    server_url: String,
    token: String,
    machine_id: String,
    book_id: String,
    client_id: String = "",
) raises -> PlayQueueResult:
    """Start a play queue session for a book.

    POST /playQueues
    Returns PlayQueueResult struct.
    """
    var headers = plex_headers(token=token, client_id=client_id)

    var uri = (
        "server://{}/com.plexapp.plugins.library/library/metadata/{}".format(
            machine_id, book_id
        )
    )
    var params = Dict[String, String]()
    params["uri"] = uri
    params["type"] = "audio"
    params["repeat"] = "0"
    params["own"] = "1"
    params["includeChapters"] = "1"

    # Plex rejects form-encoded POST bodies on /playQueues with 400 —
    # parameters must travel in the query string (verified against a live
    # server: body POST -> 400, query-string POST -> 200 with play queue).
    var query = String()
    var first = True
    for entry in params.items():
        if not first:
            query += "&"
        first = False
        query += _percent_encode(entry.key) + "=" + _percent_encode(entry.value)

    var url = server_url + "/playQueues?" + query
    var data: PythonObject
    try:
        data = _http_post_form(
            url, headers, Dict[String, String](), timeout=30.0
        )
    except:
        return PlayQueueResult()

    var container = data.get("MediaContainer", data)
    var pq_id = Int(py=container.get("playQueueID", 0))
    var selected_item_id = Int(py=container.get("playQueueSelectedItemID", 0))

    var metadata = container.get(
        "Metadata",
        container.get("PlayQueueItem", Python.list()),
    )
    metadata = _as_list(metadata)

    var items = List[PlayQueueItem]()
    var count = len(metadata)
    for i in range(count):
        var m = metadata[i]
        var item = PlayQueueItem()
        item.rating_key = String(m["ratingKey"])
        item.play_queue_item_id = Int(py=m.get("playQueueItemID", 0))
        item.title = String(m["title"])
        items.append(item)

    var result = PlayQueueResult()
    result.play_queue_id = pq_id
    result.selected_item_id = selected_item_id
    result.items = items^
    return result^


def report_progress(
    server_url: String,
    token: String,
    rating_key: String,
    track_key: String,
    time_ms: Int,
    duration_ms: Int,
    state: String,
    play_queue_item_id: Int = 0,
    client_id: String = "",
) raises -> Bool:
    """Report playback progress to Plex. Returns True on success."""
    var headers = plex_headers(token=token, client_id=client_id)
    var query = (
        "ratingKey="
        + _percent_encode(rating_key)
        + "&key="
        + _percent_encode(track_key)
        + "&time="
        + String(time_ms)
        + "&duration="
        + String(duration_ms)
        + "&state="
        + _percent_encode(state)
        + "&hasMDE=1&identifier=com.plexapp.plugins.library&playbackTime="
        + String(time_ms)
    )
    if play_queue_item_id != 0:
        query += "&playQueueItemId=" + String(play_queue_item_id)

    var url = server_url + "/:/timeline?" + query
    try:
        _ = _http_get(url, headers, timeout=10.0)
        return True
    except:
        return False


def mark_watched(
    server_url: String, token: String, item_key: String, client_id: String = ""
) raises -> Bool:
    """Mark an item as watched."""
    var headers = plex_headers(token=token, client_id=client_id)
    var url = (
        server_url
        + "/:/scrobble?key="
        + _percent_encode(item_key)
        + "&identifier=com.plexapp.plugins.library"
    )
    try:
        _ = _http_get(url, headers, timeout=10.0)
        return True
    except:
        return False


def mark_unwatched(
    server_url: String, token: String, item_key: String, client_id: String = ""
) raises -> Bool:
    """Mark an item as unwatched."""
    var headers = plex_headers(token=token, client_id=client_id)
    var url = (
        server_url
        + "/:/unscrobble?key="
        + _percent_encode(item_key)
        + "&identifier=com.plexapp.plugins.library"
    )
    try:
        _ = _http_get(url, headers, timeout=10.0)
        return True
    except:
        return False


# ---------------------------------------------------------------------------
# Audio download
# ---------------------------------------------------------------------------

comptime _AUDIO_DIR = "/tmp/quire/audio"


def get_audio_cache_dir() -> String:
    """Local audio cache directory. Prefers ~/.config/quire/audio (persistent
    across reboots); falls back to /tmp/quire/audio when HOME is unset."""
    var home = getenv("HOME")
    if home.byte_length() > 0:
        return home + "/.config/quire/audio"
    return _AUDIO_DIR


def _cover_cache_path(rating_key: String, width: Int, height: Int) -> String:
    """File path for a cached cover image (keyed by book + requested size)."""
    return "{}/{}_{}x{}.jpg".format(
        get_cover_cache_dir(), rating_key, String(width), String(height)
    )


def get_cover_cache_dir() -> String:
    """Local cover-art cache directory. Prefers ~/.config/quire/covers
    (persistent across reboots); falls back to /tmp/quire/covers."""
    var home = getenv("HOME")
    if home.byte_length() > 0:
        return home + "/.config/quire/covers"
    return "/tmp/quire/covers"


def load_cached_cover(
    rating_key: String, width: Int, height: Int
) -> List[UInt8]:
    """Return cached cover bytes for a book, or empty on any miss/failure.

    Cache misses are normal (first view); errors are swallowed so a broken
    cache file can never block rendering — we just re-fetch.
    """
    var path_str = _cover_cache_path(rating_key, width, height)
    if not path.exists(Path(path_str)):
        return List[UInt8]()
    try:
        with open(path_str, "r") as f:
            return f.read_bytes()
    except e:
        print("[Quire] load_cached_cover error: " + String(e))
        return List[UInt8]()


def save_cached_cover(
    rating_key: String, width: Int, height: Int, data: List[UInt8]
) -> None:
    """Persist raw cover bytes to the cache. Best-effort: failures print
    but never raise — a failed cache write just means a re-fetch later."""
    if data.byte_length() == 0:
        return
    try:
        makedirs(Path(get_cover_cache_dir()), exist_ok=True)
        with open(_cover_cache_path(rating_key, width, height), "w") as out:
            out.write_bytes(Span[UInt8](data))
    except e:
        print("[Quire] save_cached_cover error: " + String(e))


def download_track(
    server_url: String,
    token: String,
    track_path: String,
    book_id: String,
    client_id: String = "",
) raises -> String:
    """Stream-download a track from Plex to the local audio cache.

    The transfer runs entirely in Python (httpx client.stream → file) in
    64 KiB chunks, so large files never enter Mojo memory. The file is
    saved with its source extension; playback accepts every format ffmpeg
    decodes, so no conversion step exists. Returns the local file path on
    success, or empty string on failure.
    """
    if track_path.byte_length() == 0:
        return ""

    var url = server_url + track_path
    var separator = "&"
    if url.find("?") < 0:
        separator = "?"
    url = "{}{}X-Plex-Token={}".format(url, separator, token)

    var headers = plex_headers(token=token, client_id=client_id)
    headers["Accept"] = "*/*"

    try:
        var audio_dir = get_audio_cache_dir()
        makedirs(Path(audio_dir), exist_ok=True)

        # Download to a temp name first so a crashed download can never
        # masquerade as a valid cached file, then rename into place.
        var tmp_path = audio_dir + "/.part-" + book_id
        var content_type = String(
            _downloader_module().stream_download(
                url,
                headers.copy().to_python_object(),
                tmp_path,
            )
        )
        var src_ext = _ext_from_content_type(content_type)
        var dst_path = audio_dir + "/" + book_id + src_ext
        _mojo_rename(tmp_path, dst_path)
        return dst_path

    except e:
        # Clean up the partial download so the next attempt starts fresh.
        var tmp_path = get_audio_cache_dir() + "/.part-" + book_id
        try:
            remove(Path(tmp_path))
        except:
            pass
        print("[Quire] download_track error: " + String(e))
        return ""


def _ext_from_content_type(content_type: String) raises -> String:
    """Map HTTP Content-Type to a file."""
    # Strip content-type parameters (e.g. "audio/mp4; charset=utf-8" -> "audio/mp4").
    # Mojo-native: String.split(";") returns List[StringSlice]; take [0].
    var parts = content_type.split(";")
    var ct = String(parts[0]).strip().lower()

    if ct == "audio/mp4":
        return ".m4b"
    if ct == "audio/mp4a-latm":
        return ".m4a"
    if ct == "audio/m4b":
        return ".m4b"
    if ct == "audio/m4a":
        return ".m4a"
    if ct == "audio/mpeg" or ct == "audio/mp3":
        return ".mp3"
    if ct == "audio/aac":
        return ".aac"
    if ct == "audio/ogg" or ct == "audio/x-ogg":
        return ".ogg"
    if ct == "audio/wav" or ct == "audio/x-wav":
        return ".wav"
    if ct == "audio/flac" or ct == "audio/x-flac":
        return ".flac"
    return ".mp3"


# ---------------------------------------------------------------------------
# Thumbnail URLs
# ---------------------------------------------------------------------------


def get_thumbnail_url(
    server_url: String,
    thumb_path: String,
    token: String,
    width: Int = 200,
    height: Int = 200,
) -> String:
    """Construct a Plex thumbnail URL."""
    if thumb_path.byte_length() == 0:
        return ""
    return (
        "{}/photo/:/transcode?width={}&height={}&url={}&X-Plex-Token={}".format(
            server_url, String(width), String(height), thumb_path, token
        )
    )


def fetch_thumbnail(url: String) raises -> List[UInt8]:
    """Fetch thumbnail image bytes from a URL.

    Returns the raw response payload as a Python bytes object (JPEG or PNG —
    the caller decodes with resources.imdecode), or None on error.
    """
    try:
        var httpx = Python.import_module("httpx")

        # (connect, read) tuple timeout
        var resp = httpx.get(
            url,
            timeout=Python.tuple(3.0, 5.0),
            verify=False,
        )
        resp.raise_for_status()

        # handle conversions here, so ui can stay pure mojo
        # should make this easier to swap to mojo http
        var data_len = Int(py=len(resp.content))
        if data_len == 0:
            return List[UInt8]()
        var bytes_data: List[UInt8] = []
        for i in range(data_len):
            bytes_data.append(UInt8(py=resp.content[i]))
        return bytes_data^
    except e:
        # DIAGNOSTIC: surface why thumbnail fetches fail.
        print("fetch_thumbnail error:", e)
        return List[UInt8]()
