# ---------------------------------------------------------------------------
# Native Mojo return types for Plex API functions
# ---------------------------------------------------------------------------
# These structs replace PythonObject dict returns, providing type safety
# and eliminating the String(PythonObject) garbling bug at the boundary.
# ---------------------------------------------------------------------------

from ui.plex_objects import PlexBookCard, PlexChapter


struct CollectionItem(Copyable, ImplicitlyCopyable, Movable):
    """A collection in a Plex library."""

    var rating_key: String
    var title: String
    var child_count: Int

    def __init__(out self):
        self.rating_key = ""
        self.title = ""
        self.child_count = 0

    def __init__(out self, *, copy: CollectionItem):
        self.rating_key = copy.rating_key
        self.title = copy.title
        self.child_count = copy.child_count


struct ServerTestResult(Copyable, ImplicitlyCopyable, Movable):
    """Result of testing a Plex server connection."""

    var ok: Bool
    var name: String
    var machine_id: String
    var error: String

    def __init__(out self):
        self.ok = False
        self.name = ""
        self.machine_id = ""
        self.error = ""

    def __init__(out self, *, copy: ServerTestResult):
        self.ok = copy.ok
        self.name = copy.name
        self.machine_id = copy.machine_id
        self.error = copy.error


struct AccountInfo(Copyable, ImplicitlyCopyable, Movable):
    """Plex account information."""

    var username: String
    var email: String
    var title: String
    var id: String

    def __init__(out self):
        self.username = ""
        self.email = ""
        self.title = ""
        self.id = ""

    def __init__(out self, *, copy: AccountInfo):
        self.username = copy.username
        self.email = copy.email
        self.title = copy.title
        self.id = copy.id


struct AudiobookResult(Copyable, ImplicitlyCopyable, Movable):
    """Result of fetching audiobooks from a library."""

    var total_size: Int
    var items: List[PlexBookCard]
    var error_code: Int

    def __init__(out self):
        self.total_size = 0
        self.items = List[PlexBookCard]()
        self.error_code = 0

    def __init__(out self, *, copy: AudiobookResult):
        self.total_size = copy.total_size
        self.items = copy.items.copy()
        self.error_code = copy.error_code


struct BookDetail(Copyable, ImplicitlyCopyable, Movable):
    """Full metadata for a book (album) from Plex."""

    var rating_key: String
    var title: String
    var author: String  # parentTitle
    var thumb: String
    var duration_ms: Int
    var view_offset_ms: Int
    var leaf_count: Int
    var viewed_leaf_count: Int
    var year: Int
    var summary: String
    var genres: List[String]
    var chapters: List[PlexChapter]

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
        self.summary = ""
        self.genres = List[String]()
        self.chapters = List[PlexChapter]()

    def __init__(out self, *, copy: BookDetail):
        self.rating_key = copy.rating_key
        self.title = copy.title
        self.author = copy.author
        self.thumb = copy.thumb
        self.duration_ms = copy.duration_ms
        self.view_offset_ms = copy.view_offset_ms
        self.leaf_count = copy.leaf_count
        self.viewed_leaf_count = copy.viewed_leaf_count
        self.year = copy.year
        self.summary = copy.summary
        self.genres = copy.genres.copy()
        self.chapters = copy.chapters.copy()


struct PlayQueueResult(Copyable, ImplicitlyCopyable, Movable):
    """Result of starting a play queue."""

    var play_queue_id: Int
    var selected_item_id: Int
    var items: List[PlayQueueItem]

    def __init__(out self):
        self.play_queue_id = 0
        self.selected_item_id = 0
        self.items = List[PlayQueueItem]()

    def __init__(out self, *, copy: PlayQueueResult):
        self.play_queue_id = copy.play_queue_id
        self.selected_item_id = copy.selected_item_id
        self.items = copy.items.copy()


struct PlayQueueItem(Copyable, ImplicitlyCopyable, Movable):
    """An item in a play queue."""

    var rating_key: String
    var play_queue_item_id: Int
    var title: String

    def __init__(out self):
        self.rating_key = ""
        self.play_queue_item_id = 0
        self.title = ""

    def __init__(out self, *, copy: PlayQueueItem):
        self.rating_key = copy.rating_key
        self.play_queue_item_id = copy.play_queue_item_id
        self.title = copy.title


struct PlaybackDecision(Copyable, ImplicitlyCopyable, Movable):
    """Result of playback decision negotiation."""

    var decision_code: Int
    var stream_url: String
    var is_direct_play: Bool

    def __init__(out self):
        self.decision_code = 3000
        self.stream_url = ""
        self.is_direct_play = False

    def __init__(out self, *, copy: PlaybackDecision):
        self.decision_code = copy.decision_code
        self.stream_url = copy.stream_url
        self.is_direct_play = copy.is_direct_play


struct OAuthPin(Copyable, ImplicitlyCopyable, Movable):
    """Result of starting the OAuth PIN flow."""

    var id: Int
    var code: String
    var client_identifier: String
    var error: String

    def __init__(out self):
        self.id = 0
        self.code = ""
        self.client_identifier = ""
        self.error = ""

    def __init__(out self, *, copy: OAuthPin):
        self.id = copy.id
        self.code = copy.code
        self.client_identifier = copy.client_identifier
        self.error = copy.error


struct AuthResult(Copyable, ImplicitlyCopyable, Movable):
    """Result of polling for auth token."""

    var auth_token: String
    var expired: Bool
    var error: String

    def __init__(out self):
        self.auth_token = ""
        self.expired = False
        self.error = ""

    def __init__(out self, *, copy: AuthResult):
        self.auth_token = copy.auth_token
        self.expired = copy.expired
        self.error = copy.error


struct ManagedUser(Copyable, ImplicitlyCopyable, Movable):
    """A managed Plex user."""

    var id: Int
    var uuid: String
    var title: String
    var username: String
    var is_admin: Bool
    var thumb: String
    var auth_token: String

    def __init__(out self):
        self.id = 0
        self.uuid = ""
        self.title = ""
        self.username = ""
        self.is_admin = False
        self.thumb = ""
        self.auth_token = ""

    def __init__(out self, *, copy: ManagedUser):
        self.id = copy.id
        self.uuid = copy.uuid
        self.title = copy.title
        self.username = copy.username
        self.is_admin = copy.is_admin
        self.thumb = copy.thumb
        self.auth_token = copy.auth_token


struct SwitchUserResult(Copyable, ImplicitlyCopyable, Movable):
    """Result of switching to a managed user."""

    var auth_token: String
    var username: String
    var title: String
    var error: String

    def __init__(out self):
        self.auth_token = ""
        self.username = ""
        self.title = ""
        self.error = ""

    def __init__(out self, *, copy: SwitchUserResult):
        self.auth_token = copy.auth_token
        self.username = copy.username
        self.title = copy.title
        self.error = copy.error
