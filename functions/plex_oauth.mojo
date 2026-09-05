"""Quire — Plex OAuth PIN Flow (Mojo wrapper).

Thin Mojo module for the Plex OAuth PIN flow. HTTP goes through
plex_bridge's helpers (httpx at the Python boundary, native Mojo
Dict[String, String] headers); browser launch and timing use Mojo stdlib.
"""

from std.python import Python, PythonObject
from std.sys._libc import popen, pclose
from std.time import perf_counter, sleep
from functions.plex_bridge import (
    plex_headers,
    _http_get,
    _http_post_form,
    get_or_create_client_id,
)
from platform.ffi import cstr
from ui.plex_api_types import (
    OAuthPin,
    AuthResult,
    ManagedUser,
    SwitchUserResult,
)


# ---------------------------------------------------------------------------
# OAuth PIN flow
# ---------------------------------------------------------------------------


def start_oauth(client_id: String = "") raises -> OAuthPin:
    """Start the Plex OAuth PIN flow.

    POST https://plex.tv/api/v2/pins.json?strong=true

    Returns OAuthPin struct with id, code, client_identifier, error.
    """
    var cid = client_id
    if cid.byte_length() == 0:
        cid = get_or_create_client_id()

    var headers = plex_headers(client_id=cid)
    headers["Content-Type"] = "application/x-www-form-urlencoded"

    var url = "https://plex.tv/api/v2/pins.json?strong=true"

    try:
        var data = _http_post_form(url, headers, Dict[String, String](), 30.0)

        var result = OAuthPin()
        result.id = Int(py=data.get("id", 0))
        result.code = String(data.get("code", ""))
        result.client_identifier = cid
        return result^
    except e:
        var err_result = OAuthPin()
        err_result.id = 0
        err_result.code = ""
        err_result.client_identifier = cid
        err_result.error = String(e)
        return err_result^


def get_auth_url(pin_code: String, client_id: String = "") raises -> String:
    """Construct the browser authentication URL.

    The user opens this URL in their browser to approve the app.
    """
    var cid = client_id
    if cid.byte_length() == 0:
        cid = get_or_create_client_id()

    return (
        "https://app.plex.tv/auth#?code={}&clientID={}"
        "&context[device][product]=Quire"
        "&context[device][environment]=bundled"
        "&context[device][layout]=desktop"
        "&context[device][platform]=Linux"
        "&context[device][device]=Quire".format(pin_code, cid)
    )


def open_browser(pin_code: String, client_id: String = "") raises -> Bool:
    """Open the Plex auth page in the user's default browser.

    Launches `xdg-open` via popen (native libc) instead of Python's
    `webbrowser` module. Returns True if the subprocess started.
    """
    var url = get_auth_url(pin_code, client_id)
    var cmd = "xdg-open '" + url + "'"
    var mode = String("r")
    var fp = popen(cstr(cmd), cstr(mode))
    _ = pclose(fp)
    return True


def poll_pin(pin_id: Int, client_id: String = "") raises -> AuthResult:
    """Poll for the OAuth token after the user authorizes in the browser.

    GET https://plex.tv/api/v2/pins/{id}.json

    Returns AuthResult struct with auth_token, expired, error.
    """
    var cid = client_id
    if cid.byte_length() == 0:
        cid = get_or_create_client_id()

    var headers = plex_headers(client_id=cid)
    var url = "https://plex.tv/api/v2/pins/{}.json".format(String(pin_id))

    try:
        var data = _http_get(url, headers, 15.0)

        var result = AuthResult()
        result.auth_token = String(data.get("authToken", ""))
        result.expired = False
        return result^
    except e:
        # _http_get raises on 404 (PIN expired or unknown).
        var err_result = AuthResult()
        err_result.auth_token = ""
        var err_msg = String(e)
        if err_msg.find("404") >= 0:
            err_result.expired = True
            err_result.error = "PIN expired"
        else:
            err_result.expired = False
            err_result.error = err_msg
        return err_result^


def wait_for_auth(
    pin_id: Int,
    client_id: String = "",
    poll_interval: Float64 = 2.0,
    max_wait: Float64 = 180.0,
) raises -> AuthResult:
    """Poll for auth token until authorized or expired.

    Blocks for up to max_wait seconds, polling every poll_interval.
    Called from a background thread in the Mojo app.

    Returns AuthResult struct with auth_token, expired, error.
    """
    var start_time = perf_counter()

    while perf_counter() - start_time < max_wait:
        var result = poll_pin(pin_id, client_id)
        if result.auth_token.byte_length() > 0:
            return result^

        if result.expired:
            return result^

        if (
            result.error.byte_length() > 0
            and result.error.find("PIN expired") >= 0
        ):
            return result^

        sleep(poll_interval)

    var timeout_result = AuthResult()
    timeout_result.auth_token = ""
    timeout_result.expired = True
    timeout_result.error = "Timed out waiting for authorization"
    return timeout_result^


# ---------------------------------------------------------------------------
# User management
# ---------------------------------------------------------------------------


def get_managed_users(
    account_token: String, client_id: String = ""
) raises -> List[ManagedUser]:
    """Get managed users for the account.

    GET https://plex.tv/api/v2/home/users

    Returns list of ManagedUser structs.
    """
    var headers = plex_headers(token=account_token, client_id=client_id)
    var url = "https://plex.tv/api/v2/home/users"

    try:
        var data = _http_get(url, headers, 15.0)

        var users = data.get("users", "")
        var user_list: PythonObject
        if Bool(py=users == PythonObject("")):
            user_list = data.get("User", Python.list())
        else:
            user_list = users

        if String(user_list.__class__.__name__) == "dict":
            user_list = Python.list(user_list)

        var result = List[ManagedUser]()
        for u in user_list:
            var user = ManagedUser()
            user.id = Int(py=u.get("id", 0))
            user.uuid = String(u.get("uuid", ""))
            user.title = String(u.get("title", ""))
            user.username = String(u.get("username", ""))

            var admin_val = u.get("admin", False)
            var is_admin = Bool(py=admin_val)
            if String(admin_val.__class__.__name__) == "str":
                is_admin = String(admin_val) == "1"
            user.is_admin = is_admin

            user.thumb = String(u.get("thumb", ""))
            user.auth_token = String(u.get("authToken", ""))
            result.append(user)
        return result^
    except e:
        # Return empty list on error — caller can check for errors
        return List[ManagedUser]()


def switch_user(
    account_token: String,
    user_uuid: String,
    pin: String = "",
    client_id: String = "",
) raises -> SwitchUserResult:
    """Switch to a managed user.

    POST https://plex.tv/api/v2/home/users/{uuid}/switch

    Returns SwitchUserResult struct with auth_token, username, title, error.
    """
    var headers = plex_headers(token=account_token, client_id=client_id)
    headers["Content-Type"] = "application/x-www-form-urlencoded"

    var url = "https://plex.tv/api/v2/home/users/{}/switch".format(user_uuid)
    var body = Dict[String, String]()
    if pin.byte_length() > 0:
        body["pin"] = pin

    try:
        var data = _http_post_form(url, headers, body, 15.0)

        var result = SwitchUserResult()
        result.auth_token = String(data.get("authToken", ""))
        result.username = String(data.get("username", ""))
        result.title = String(data.get("title", ""))
        return result^
    except e:
        var err_result = SwitchUserResult()
        err_result.auth_token = ""
        err_result.error = String(e)
        return err_result^
