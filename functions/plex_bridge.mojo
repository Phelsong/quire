"""Quire — Plex API Bridge.

HTTP calls go through Python httpx (Mojo has no native HTTP client yet),
but the Python boundary is narrow: _http_get and _http_post_form are the
only functions that touch PythonObject, and they return a parsed
XmlElement — every endpoint downstream is pure Mojo working on checked
XML accessors. Plex is asked for XML on every transport (Accept:
application/xml, plex.tv v2 included) and the responses parse in pure
Mojo with resources.xmlparse — no JSON parser anywhere. Headers live in
the native PlexHeaders struct and only cross into Python at the httpx
call sites.
"""

from std.logger import Logger, Level
from std.python import Python, PythonObject
from std.python.conversions import ConvertibleToPython
from std.os import makedirs, path, remove, getenv
from std.pathlib import Path
from std.time import perf_counter

from functions.helpers import _mojo_rename
from resources.xmlparse import parse_xml, XmlElement
from resources.plex_api_types import (
    ServerTestResult,
    AccountInfo,
    AudiobookResult,
    BookDetail,
    PlayQueueResult,
    PlayQueueItem,
    PlaybackDecision,
    CollectionItem,
)
from resources.plex_objects import (
    PlexTrack,
    PlexChapter,
    ServerItem,
    LibraryItem,
    PlexBookCard,
)
from resources.config import (
    Config,
    load_config,
    save_config,
    get_or_create_client_id,
    LOG_LEVEL,
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

    # Known-offline state. Set by a failed boot probe or a failed primary
    # fetch (load_data, run_search, load_book detail/tracks); cleared by the
    # next successful server operation or a successful re-probe. While it
    # holds, the UI paths skip server round-trips entirely (sidecar store
    # + local audio only) instead of burning HTTP timeouts.
    var offline: Bool
    # perf_counter() seconds of the last failed probe/fetch — arms the
    # re-probe window consumed by LibraryScreen._offline_probe_ok.
    var last_offline_probe_s: Float64

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
        self.offline = False
        self.last_offline_probe_s = 0.0

    def mark_offline(mut self):
        """Record a failed probe/fetch: flag the session offline and arm
        the re-probe window (now, so the next allowed probe is 30s out)."""
        self.offline = True
        self.last_offline_probe_s = perf_counter()


def _hex_digit(n: Int) -> String:
    """Return the uppercase hex digit for a nibble 0-15."""
    if n < 10:
        return String(chr(n + ord("0")))
    return String(chr(n - 10 + ord("A")))


def _percent_encode(s: String) -> String:
    """Percent-encode a string for URL query parameters (RFC 3986).

    Encodes everything except unreserved characters (A-Z, a-z, 0-9, -._~).
    Spaces become %20 (not +). Multi-byte UTF-8 codepoints encode
    byte-by-byte per RFC 3986 (each UTF-8 byte is its own %XX escape).

    Walks codepoint slices, not byte indices: a byte cursor panics the
    moment a string carries one non-ASCII character ("String span index,
    N does not lie on a codepoint boundary" — an uncatchable abort that
    used to kill the app whenever a search query held an accented char,
    a curly quote, an ellipsis, ...).
    """
    var result = String()
    for cp_slice in s.codepoint_slices():
        var cp = ord(String(cp_slice))
        var w = cp_slice.byte_length()
        if w == 1:
            if _is_unreserved(cp):
                result += String(cp_slice)
            else:
                result += "%" + _hex_digit(cp >> 4) + _hex_digit(cp & 0xF)
        else:
            # Standard UTF-8 lead + continuation bytes for this codepoint.
            var utf8 = List[UInt8]()
            if w == 2:
                utf8.append(UInt8(0xC0 | (cp >> 6)))
                utf8.append(UInt8(0x80 | (cp & 0x3F)))
            elif w == 3:
                utf8.append(UInt8(0xE0 | (cp >> 12)))
                utf8.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
                utf8.append(UInt8(0x80 | (cp & 0x3F)))
            else:
                utf8.append(UInt8(0xF0 | (cp >> 18)))
                utf8.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
                utf8.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
                utf8.append(UInt8(0x80 | (cp & 0x3F)))
            for i in range(len(utf8)):
                var b = Int(utf8[i])
                result += "%" + _hex_digit(b >> 4) + _hex_digit(b & 0xF)
    return result


def _is_unreserved(cp: Int) -> Bool:
    """RFC 3986 unreserved characters (their UTF-8 byte equals the cp)."""
    return (
        (cp >= ord("A") and cp <= ord("Z"))
        or (cp >= ord("a") and cp <= ord("z"))
        or (cp >= ord("0") and cp <= ord("9"))
        or cp == ord("-")
        or cp == ord(".")
        or cp == ord("_")
        or cp == ord("~")
    )


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


def gethostname() -> String:
    """The machine's hostname, read from /proc/sys/kernel/hostname.

    Memoized on Python `builtins` (the process-live cache pattern from
    _downloader_module — this toolchain has no module-scoped Mojo state).
    Every plex_headers() call embeds the name in X-Plex-Device-Name, so
    re-reading /proc per request was per-request kernel churn on the UI
    thread. HTTP runs in main's frame loop only (single thread), so the
    cached attribute has no race. An empty read is NOT memoized: the
    header is optional, so a failed read just retries on the next
    request.
    """
    try:
        var builtins = Python.import_module("builtins")
        try:
            var cached = builtins._QUIRE_HOSTNAME
            if Bool(cached) and String(cached).byte_length() > 0:
                return String(cached)
        except:
            pass
        var raw = Path("/proc/sys/kernel/hostname").read_bytes()
        var name = String()
        for i in range(len(raw)):
            if raw[i] == UInt8(10):  # '\n'
                break
            name += String(chr(Int(raw[i])))
        if name.byte_length() > 0:
            builtins._QUIRE_HOSTNAME = PythonObject(name)
        return name
    except:
        return ""


def plex_headers(
    token: String = "", client_id: String = ""
) raises -> PlexHeaders:
    """Build standard Plex API headers required for every request.

    Returns native PlexHeaders — headers are pure Mojo state until the
    httpx call converts them.
    """
    var cid = client_id
    if cid.byte_length() == 0:
        cid = get_or_create_client_id()

    var headers = PlexHeaders()
    headers["Accept"] = "application/xml"
    headers["X-Plex-Product"] = PRODUCT_NAME
    headers["X-Plex-Version"] = PRODUCT_VERSION
    headers["X-Plex-Client-Identifier"] = cid
    headers["X-Plex-Platform"] = "Linux"
    headers["X-Plex-Device"] = PRODUCT_NAME + " Linux"
    headers["X-Plex-Device-Name"] = gethostname()
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

    # var extra = "&X-Plex-Client-Profile-Extra=“add-transcode-target(type=musicProfile&context=streaming&protocol=http&audioCodec=aac,mp3)"
    if token.byte_length() > 0:
        headers["X-Plex-Token"] = token
    return headers^


# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------


def _httpx_module() raises -> PythonObject:
    """The httpx module, imported once per process and cached on
    `builtins` — the same process-live pattern as _downloader_module down
    below (this toolchain has no module-scoped Mojo state).

    Every request used to call Python.import_module("httpx") afresh;
    requests here fire from the render loop (progress pushes) and behind
    keystrokes (search), so the module is resolved once and the per-call
    cost drops to an attribute lookup. HTTP runs on the app's UI thread
    only (driven from main's frame loop), so the cache has no race.
    """
    var builtins = Python.import_module("builtins")
    try:
        var cached = builtins._QUIRE_HTTPX_MODULE
        if Bool(cached):
            return cached
    except:
        pass
    var mod = Python.import_module("httpx")
    builtins._QUIRE_HTTPX_MODULE = mod
    return mod


def _http_get(
    url: String, headers: PlexHeaders, timeout: Float64 = 30.0
) raises -> XmlElement:
    """GET via httpx, parse the body into an XmlElement.

    The Python boundary: httpx runs here, and the response text crosses
    back as a String exactly once. Callers get a parsed element tree —
    native Mojo from here down. Plex serves XML on every transport the
    bridge uses (Accept: application/xml); a non-XML body fails to parse
    and callers' existing catch-and-degrade paths handle it."""
    var httpx = _httpx_module()

    var logger = Logger[LOG_LEVEL]()
    var resp = httpx.get(
        url,
        headers=headers.copy().to_python_object(),
        timeout=PythonObject(timeout),
        verify=False,
    )

    var status_code = Int(py=resp.status_code)
    if status_code >= 400:
        logger.warning(
            "[plex_bridge] GET " + url + " -> " + String(status_code)
        )
        logger.warning("[plex_bridge] Response: " + String(resp.text[0:500]))

    resp.raise_for_status()

    var text = String(resp.text)
    return parse_xml(text)


def _http_post_form(
    url: String,
    headers: PlexHeaders,
    body: Dict[String, String],
    timeout: Float64 = 30.0,
) raises -> XmlElement:
    """POST with urlencoded form body, parse the response into an
    XmlElement.

    Companion to _http_get — same Python boundary, native Mojo inputs.
    """
    var httpx = _httpx_module()

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

    var text = String(resp.text)
    return parse_xml(text)


# ---------------------------------------------------------------------------
# XML accessors — Plex's attribute-typed surface. PMS protocol-1 XML and
# the plex.tv v2 serializer both ride attributes (element fields never
# have child text), so every field read is an attribute read, typed
# through these guards instead of trusting the wire.
# ---------------------------------------------------------------------------


def _tag_eq(tag: String, want: String) -> Bool:
    """Case-insensitive tag comparison. PMS protocol-1 XML is PascalCase
    (MediaContainer, Metadata); plex.tv v2 serializes the JSON keys as
    lowercase tags (pin, resource)."""
    if tag == want:
        return True
    return tag.lower() == want.lower()


def _has(v: XmlElement, key: String) -> Bool:
    """True when v carries key as an attribute."""
    return key in v.attrs


def _vstr(v: XmlElement, key: String, default: String = "") -> String:
    """Field as String — attributes arrive as text; no coercion needed."""
    if key in v.attrs:
        return String(v.attrs.get(key, default))
    return default


def _vint(v: XmlElement, key: String, default: Int = 0) -> Int:
    """Field as Int. Plex XML encodes every field as text; strict parse,
    garbage falls back to the default."""
    if key in v.attrs:
        var raw = String(v.attrs.get(key, ""))
        if raw.byte_length() == 0:
            return default
        try:
            return Int(raw)
        except:
            return default
    return default


def _vtruthy(v: XmlElement, key: String, default: Bool = False) -> Bool:
    """Field as Bool. XML booleans are textual: "1" (PMS protocol-1 and
    plex.tv v2 — pin XML shows trusted="0") or "true"; anything else is
    False."""
    if key in v.attrs:
        var raw = String(v.attrs.get(key, ""))
        return raw == "1" or raw == "true"
    return default


def _container_of(
    var data: XmlElement, key: String = "MediaContainer"
) raises -> XmlElement:
    """Unwrap the envelope element; pass the element through when absent.

    Covers both shapes the bridge sees: a root MediaContainer whose
    children are the payload (PMS listings), and a bare typed root
    (PlayQueue, pin, user /resource entries)."""
    for i in range(len(data.children)):
        if _tag_eq(data.children[i].tag, key):
            return data.children[i].copy()
    return data^


def _vitems(
    v: XmlElement, tag: String, alt: String = ""
) raises -> List[XmlElement]:
    """Direct children tagged `tag`, as a fresh list.

    Exact-tag pass, then case-insensitive (protocol-1 PascalCase vs v2
    lowercase), then the `alt` spelling when both miss — one call covers
    Directory/Metadata-era shapes across servers."""
    var out = List[XmlElement]()
    for i in range(len(v.children)):
        if v.children[i].tag == tag:
            out.append(v.children[i].copy())
    if len(out) > 0:
        return out^
    for i in range(len(v.children)):
        if _tag_eq(v.children[i].tag, tag):
            out.append(v.children[i].copy())
    if len(out) == 0 and alt != "":
        for i in range(len(v.children)):
            if _tag_eq(v.children[i].tag, alt):
                out.append(v.children[i].copy())
    return out^


# ---------------------------------------------------------------------------
# Streaming download helper (implemented in Python via evaluate, compiled once)
# ---------------------------------------------------------------------------


comptime _DOWNLOADER_MOD_KEY = "_QUIRE_DOWNLOADER_MODULE"


def _downloader_module() raises -> PythonObject:
    """Compile the streaming file-download helper once, lazily.

    The compiled module is stashed on `builtins` (process-live cache).
    The download runs entirely in Python (httpx client.stream →
    iter_bytes → file.write), so a multi-hundred-MB audiobook never
    enters Mojo memory — Mojo only sees the returned content-type string.
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

    GET https://plex.tv/api/v2/user — the v1 /users/account.json route is
    JSON-only, and this bridge is XML-only; the v2 route with Accept:
    application/xml serves the same fields as attributes (root <user>,
    same keys python-plexapi's MyPlexAccount reads).
    Returns AccountInfo struct; an unreachable shape degrades to blanks
    (same contract as before).
    """
    var headers = plex_headers(token=account_token, client_id=client_id)
    try:
        var data = _http_get("https://plex.tv/api/v2/user", headers)
        var user = _container_of(data^, key="user")
        var result = AccountInfo()
        result.username = _vstr(user, "username")
        result.email = _vstr(user, "email")
        result.title = _vstr(user, "title", _vstr(user, "friendlyName"))
        result.id = _vstr(user, "id")
        return result^
    except:
        return AccountInfo()


# ---------------------------------------------------------------------------
# Server discovery
# ---------------------------------------------------------------------------


def _card_from_metadata(v: XmlElement) raises -> PlexBookCard:
    """One PlexBookCard from a listing (album) element. Shared by every
    listing path (library browse, search, collection members). Album
    listings arrive as <Directory> elements in PMS protocol-1 XML."""
    var card = PlexBookCard()
    card.rating_key = _vstr(v, "ratingKey")
    card.title = _vstr(v, "title")
    card.author = _vstr(v, "parentTitle")
    card.thumb = _vstr(v, "thumb")
    card.duration_ms = _vint(v, "duration")
    card.view_offset_ms = _vint(v, "viewOffset")
    card.leaf_count = _vint(v, "leafCount")
    card.viewed_leaf_count = _vint(v, "viewedLeafCount")
    var year = _vint(v, "year")
    if year != 0:
        card.year = year
    return card^


def get_servers(
    account_token: String, client_id: String = ""
) raises -> List[ServerItem]:
    """Discover user's Plex servers via plex.tv.

    GET https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1
    XML: items are <resource ...> elements (plexapi MyPlexResource.TAG
    is 'resource' — the v2 serializer lowercases the JSON keys), each
    carrying its <Connection> children directly or under a <connections>
    wrapper. Returns list of ServerItem structs.
    """
    var headers = plex_headers(token=account_token, client_id=client_id)
    var data = _http_get(
        "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1",
        headers,
    )
    var servers = List[ServerItem]()

    var container = _container_of(data^)
    var server_elems = _vitems(container, "resource", alt="Server")
    if len(server_elems) == 0:
        # No resource elements at all: auth error or empty account.
        return servers^

    var count = len(server_elems)
    for i in range(count):
        ref s = server_elems[i]
        var item = ServerItem()
        item.name = _vstr(s, "name")
        item.token = _vstr(s, "accessToken")
        item.machine_id = _vstr(s, "clientIdentifier")
        item.is_owned = _vtruthy(s, "owned")

        # <Connection> children ride the resource element either directly
        # or under a <connections> wrapper element.
        var connections = _vitems(s, "Connection")
        if len(connections) == 0:
            var wrappers = _vitems(s, "connections")
            for w in range(len(wrappers)):
                var conn_children = _vitems(wrappers[w], "Connection")
                for c in range(len(conn_children)):
                    connections.append(conn_children[c].copy())

        # Extract best connection URL
        var conn_count = len(connections)
        var best_url = String()
        for j in range(conn_count):
            var conn_url = _vstr(connections[j], "uri")
            # Prefer HTTPS connections
            if conn_url.startswith("https"):
                best_url = conn_url
                break
            if best_url.byte_length() == 0:
                best_url = conn_url

        if best_url.byte_length() == 0:
            # Fallback: test each connection
            for j in range(conn_count):
                var candidate_url = _vstr(connections[j], "uri")
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
        var container = _container_of(data^)
        var result = ServerTestResult()
        result.ok = True
        result.name = _vstr(container, "friendlyName", _vstr(container, "name"))
        result.machine_id = _vstr(container, "machineIdentifier")
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


def probe_server(
    server_url: String,
    token: String,
    client_id: String = "",
    timeout_s: Float64 = 2.5,
) -> ServerTestResult:
    """Identity check with a short scalar timeout — the offline fast path.

    Same /identity endpoint and result shape as test_server, but the httpx
    timeout defaults to 2.5s instead of 30 so a boot restore can decide
    reachable-vs-offline in a few seconds instead of blocking the first
    frame for 30. Catches its own exceptions and returns ok=False (never
    raises) — callers branch on the flag, not on exceptions."""
    var result = ServerTestResult()
    try:
        var headers = plex_headers(token=token, client_id=client_id)
        var data = _http_get(
            server_url + "/identity", headers, timeout=timeout_s
        )
        var container = _container_of(data^)
        result.ok = True
        result.name = _vstr(container, "friendlyName", _vstr(container, "name"))
        result.machine_id = _vstr(container, "machineIdentifier")
    except e:
        var error_msg = String(e)
        print(
            "[plex_bridge] probe_server failed for "
            + server_url
            + ": "
            + error_msg
        )
        result.ok = False
        result.error = error_msg
    return result


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
    var container = _container_of(data^)
    var dirs = _vitems(container, "Directory")

    var libraries = List[LibraryItem]()
    var count = len(dirs)
    for i in range(count):
        ref d = dirs[i]
        var item = LibraryItem()
        item.key = _vstr(d, "key")
        item.title = _vstr(d, "title")
        item.lib_type = _vstr(d, "type")
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
    var data: XmlElement

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
        var container = _container_of(data^)
        var total_size_val = _vint(
            container, "totalSize", _vint(container, "size")
        )
        var metadata = _vitems(container, "Directory", alt="Metadata")

        var items = List[PlexBookCard]()
        var count = len(metadata)
        for i in range(count):
            ref m = metadata[i]
            var card = _card_from_metadata(m)
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

    var data: XmlElement
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
        var container = _container_of(data^)
        var total_size_val = _vint(
            container, "totalSize", _vint(container, "size")
        )
        var metadata = _vitems(container, "Directory", alt="Metadata")

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
            items.append(_card_from_metadata(metadata[i]))

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

    var data: XmlElement
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
        var container = _container_of(data^)
        var metadata = _vitems(container, "Directory", alt="Metadata")

        # Lowercase the query once (Mojo String.lower, no Python needed).
        var query_lower = query.lower()

        var items = List[PlexBookCard]()
        var count = len(metadata)
        for i in range(count):
            ref m = metadata[i]
            var title = _vstr(m, "title")
            var author = _vstr(m, "parentTitle")
            var title_lower = title.lower()
            var author_lower = author.lower()
            if (
                title_lower.find(query_lower) < 0
                and author_lower.find(query_lower) < 0
            ):
                continue
            var card = _card_from_metadata(m)
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

    var container = _container_of(data^)
    var metadata_list = _vitems(container, "Directory", alt="Metadata")
    if len(metadata_list) == 0:
        return BookDetail()

    ref m = metadata_list[0]
    var result = BookDetail()
    result.rating_key = _vstr(m, "ratingKey")
    result.title = _vstr(m, "title")
    result.author = _vstr(m, "parentTitle", _vstr(m, "grandparentTitle"))
    result.thumb = _vstr(m, "thumb")
    result.duration_ms = _vint(m, "duration")
    result.view_offset_ms = _vint(m, "viewOffset")
    result.leaf_count = _vint(m, "leafCount")
    result.viewed_leaf_count = _vint(m, "viewedLeafCount")
    var year = _vint(m, "year")
    if year != 0:
        result.year = year
    result.summary = _vstr(m, "summary")

    # Genres
    var genre_list = _vitems(m, "Genre")
    var gcount = len(genre_list)
    for i in range(gcount):
        result.genres.append(_vstr(genre_list[i], "tag"))

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

    var container = _container_of(data^)
    # Tracks arrive as <Track> elements (protocol-1 <Directory> for
    # albums only; children endpoint serves Track).
    var metadata = _vitems(container, "Track", alt="Metadata")

    var tracks = List[PlexTrack]()
    var count = len(metadata)
    for i in range(count):
        ref m = metadata[i]
        var track = PlexTrack()
        track.rating_key = _vstr(m, "ratingKey")
        track.title = _vstr(m, "title")
        track.index = _vint(m, "index")
        track.duration_ms = _vint(m, "duration")
        track.view_offset_ms = _vint(m, "viewOffset")

        # Extract file_key from Media > Part
        var file_key = ""
        var media_list = _vitems(m, "Media")
        if len(media_list) > 0:
            var parts = _vitems(media_list[0], "Part")
            if len(parts) > 0:
                file_key = _vstr(parts[0], "key")
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

    var container = _container_of(data^)
    var metadata_list = _vitems(container, "Track", alt="Metadata")
    if len(metadata_list) == 0:
        return List[PlexChapter]()

    ref m = metadata_list[0]
    # Chapters ride directly on the element (protocol-1 XML); a JSON-era
    # <Chapters> wrapper, when a server sends one, unwraps a level.
    var chapters_raw = _vitems(m, "Chapter")
    var wrappers = _vitems(m, "Chapters")
    for w in range(len(wrappers)):
        var wrapped = _vitems(wrappers[w], "Chapter")
        for c in range(len(wrapped)):
            chapters_raw.append(wrapped[c].copy())

    var chapters = List[PlexChapter]()
    var count = len(chapters_raw)
    for i in range(count):
        ref c = chapters_raw[i]
        var chapter = PlexChapter()
        chapter.id = _vint(c, "id")
        chapter.index = _vint(c, "index")
        chapter.tag = _vstr(c, "tag")
        chapter.start_time_ms = _vint(c, "startTimeOffset")
        chapter.end_time_ms = _vint(c, "endTimeOffset")
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

    var container = _container_of(data^)
    var directories = _vitems(container, "Directory", alt="Metadata")

    var collections = List[CollectionItem]()
    var count = len(directories)
    for i in range(count):
        ref d = directories[i]
        var item = CollectionItem()
        item.rating_key = _vstr(d, "ratingKey")
        item.title = _vstr(d, "title")
        item.child_count = _vint(d, "childCount")
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

    var container = _container_of(data^)
    var metadata = _vitems(container, "Directory", alt="Metadata")

    var items = List[PlexBookCard]()
    var count = len(metadata)
    for i in range(count):
        items.append(_card_from_metadata(metadata[i]))
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

    # The universal decision endpoint only resolves when the request maps to
    # a built-in server client profile (Chrome, Windows, Firefox, Safari...).
    # Custom platform names (e.g. "Linux", "Quire") match no profile and PMS
    # answers 400 "unable to find a matching profile". Override the platform
    # for this request only — verified against PMS 1.43.3.
    headers["X-Plex-Platform"] = "Chrome"

    # Native Mojo query params → URL query string (percent-encoded).
    var params = Dict[String, String]()
    params["path"] = track_path
    params["protocol"] = "http"
    params["session"] = session_id
    params["hasMDE"] = "1"
    params["directPlay"] = "1"
    params["download"] = "0"
    params["directStreamAudio"] = "1"
    params["musicBitrate"] = "256"
    params["peakBitrate"] = "256"
    # mediaIndex/partIndex are required for the decision to resolve at all;
    # without them PMS 400s regardless of headers.
    params["mediaIndex"] = "0"
    params["partIndex"] = "0"
    var query = String()
    var first = True
    for entry in params.items():
        if not first:
            query += "&"
        first = False
        query += entry.key + "=" + _percent_encode(entry.value)

    var url = server_url + "/audio/:/transcode/universal/decision?" + query

    var data: XmlElement
    try:
        data = _http_get(url, headers)
    except:
        return PlaybackDecision()

    var container = _container_of(data^)
    var general_code = _vint(container, "generalDecisionCode")
    var direct_play_code = _vint(container, "directPlayDecisionCode")
    var transcode_code = _vint(container, "transcodeDecisionCode")

    var stream_url = ""
    var is_direct = direct_play_code == 1000

    var metadata_list = _vitems(container, "Metadata", alt="Track")

    if len(metadata_list) > 0:
        var media_list = _vitems(metadata_list[0], "Media")
        if len(media_list) > 0:
            # First media flagged selected, else the first media.
            var selected_media = media_list[0].copy()
            for i in range(len(media_list)):
                if _vtruthy(media_list[i], "selected") or _has(
                    media_list[i], "decision"
                ):
                    selected_media = media_list[i].copy()
                    break

            var parts = _vitems(selected_media, "Part")
            if len(parts) > 0:
                # First part flagged selected (or carrying the decision
                # attribute), else the first part.
                var selected_part = parts[0].copy()
                for i in range(len(parts)):
                    if _vtruthy(parts[i], "selected") or _has(
                        parts[i], "decision"
                    ):
                        selected_part = parts[i].copy()
                        break

                stream_url = _vstr(selected_part, "key")
                if stream_url.byte_length() > 0 and not stream_url.startswith(
                    "http"
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
    var data: XmlElement
    try:
        data = _http_post_form(
            url, headers, Dict[String, String](), timeout=30.0
        )
    except:
        return PlayQueueResult()

    # The response root is a typed <PlayQueue> element carrying the queue
    # ids as attributes; unwrap a MediaContainer should one wrap it.
    var pq = _container_of(data^, key="PlayQueue")
    var pq_id = _vint(pq, "playQueueID")
    var selected_item_id = _vint(pq, "playQueueSelectedItemID")

    # Queue items are the media elements themselves (Track for audio),
    # with playQueueItemID riding as an attribute — same shape
    # python-plexapi parses.
    var metadata = _vitems(pq, "Track", alt="Metadata")
    if len(metadata) == 0:
        metadata = _vitems(pq, "PlayQueueItem")

    var items = List[PlayQueueItem]()
    var count = len(metadata)
    for i in range(count):
        ref m = metadata[i]
        var item = PlayQueueItem()
        item.rating_key = _vstr(m, "ratingKey")
        item.play_queue_item_id = _vint(m, "playQueueItemID")
        item.title = _vstr(m, "title")
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

    Reads via native Path.read_bytes() — no Python file IO on the draw
    path (the file may be tens of KB; the Python `open` round-trip cost a
    full interpreter bootstrapping per call). read_bytes() already yields
    the owned List[UInt8] the caller expects — returned as-is, with none
    of the per-byte re-copy the old hand loop did.
    """
    var path_str = _cover_cache_path(rating_key, width, height)
    var p = Path(path_str)
    if not path.exists(p):
        return List[UInt8]()
    try:
        return p.read_bytes()
    except e:
        print("[Quire] load_cached_cover error: " + String(e))
        return List[UInt8]()


def save_cached_cover(
    rating_key: String, width: Int, height: Int, data: List[UInt8]
) -> None:
    """Persist raw cover bytes to the cache. Best-effort: failures print
    but never raise — a failed cache write just means a re-fetch later.

    Writes via native Path.write_bytes() (one syscall-shaped call, no
    Python file object)."""
    if data.byte_length() == 0:
        return
    try:
        makedirs(Path(get_cover_cache_dir()), exist_ok=True)
        var out_path = Path(_cover_cache_path(rating_key, width, height))
        out_path.write_bytes(Span[UInt8](data))
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

    Returns the raw response payload (JPEG or PNG — the caller decodes with
    resources.imdecode), or an empty list on error.

    Byte transfer uses the bulk hex path: resp.content.hex() crosses the
    Python boundary ONCE as a String, then Mojo parses 2 hex chars per byte
    — ~10x faster than per-byte UInt8(py=resp.content[i]) round-trips, and
    deterministic (the ctypes from_buffer route races the GC).
    """
    try:
        var httpx = _httpx_module()

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
        var hex_str = String(resp.content.hex())
        var bytes_data = List[UInt8]()
        bytes_data.reserve(data_len)
        for i in range(data_len):
            var hi_code = ord(hex_str[byte=i * 2])
            var lo_code = ord(hex_str[byte=i * 2 + 1])
            var hi = hi_code - 48 if hi_code <= 57 else hi_code - 87
            var lo = lo_code - 48 if lo_code <= 57 else lo_code - 87
            bytes_data.append(UInt8(hi * 16 + lo))
        return bytes_data^
    except e:
        # DIAGNOSTIC: surface why thumbnail fetches fail.
        print("fetch_thumbnail error:", e)
        return List[UInt8]()
