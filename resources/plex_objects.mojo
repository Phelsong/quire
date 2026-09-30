# ---------------------------------------------------------------------------
# Plex track and chapter data — extracted from API response
# ---------------------------------------------------------------------------


struct PlexTrack(Copyable, ImplicitlyCopyable, Movable):
    """A track/part of an audiobook in Plex."""

    var rating_key: String
    var title: String
    var index: Int
    var duration_ms: Int
    var view_offset_ms: Int
    var file_key: String  # Part key for playback URL resolution

    def __init__(out self):
        self.rating_key = ""
        self.title = ""
        self.index = 0
        self.duration_ms = 0
        self.view_offset_ms = 0
        self.file_key = ""

    def __init__(out self, *, copy: PlexTrack):
        self.rating_key = copy.rating_key
        self.title = copy.title
        self.index = copy.index
        self.duration_ms = copy.duration_ms
        self.view_offset_ms = copy.view_offset_ms
        self.file_key = copy.file_key


struct PlexChapter(Copyable, ImplicitlyCopyable, Movable):
    """A chapter within a track in Plex."""

    var id: Int
    var index: Int
    var tag: String  # Chapter title
    var start_time_ms: Int  # Start offset in milliseconds
    var end_time_ms: Int  # End offset in milliseconds
    var is_current: Bool

    def __init__(out self):
        self.id = 0
        self.index = 0
        self.tag = ""
        self.start_time_ms = 0
        self.end_time_ms = 0
        self.is_current = False

    def __init__(out self, *, copy: PlexChapter):
        self.id = copy.id
        self.index = copy.index
        self.tag = copy.tag
        self.start_time_ms = copy.start_time_ms
        self.end_time_ms = copy.end_time_ms
        self.is_current = copy.is_current


struct ServerItem(Copyable, ImplicitlyCopyable, Movable):
    """A Plex server discovered via the plex.tv resources API."""

    var name: String
    var url: String  # Best connection URI
    var token: String  # Server-specific access token
    var machine_id: String  # Server's clientIdentifier
    var is_owned: Bool

    def __init__(out self):
        self.name = ""
        self.url = ""
        self.token = ""
        self.machine_id = ""
        self.is_owned = True

    def __init__(out self, *, copy: ServerItem):
        self.name = copy.name
        self.url = copy.url
        self.token = copy.token
        self.machine_id = copy.machine_id
        self.is_owned = copy.is_owned


struct LibraryItem(Copyable, ImplicitlyCopyable, Movable):
    """A library section on a Plex server."""

    var key: String  # Library ID (e.g., "1")
    var title: String  # Library display name
    var lib_type: String  # "artist", "movie", etc.

    def __init__(out self):
        self.key = ""
        self.title = ""
        self.lib_type = ""

    def __init__(out self, *, copy: LibraryItem):
        self.key = copy.key
        self.title = copy.title
        self.lib_type = copy.lib_type


struct PlexBookCard(Copyable, ImplicitlyCopyable, Movable):
    """Minimal book data for Plex library display."""

    var rating_key: String  # Plex ratingKey (primary ID)
    var title: String
    var author: String  # parentTitle in Plex
    var thumb: String  # Relative cover art path
    var duration_ms: Int  # Duration in milliseconds
    var view_offset_ms: Int  # Current progress in ms
    var leaf_count: Int  # Total tracks
    var viewed_leaf_count: Int  # Completed tracks
    var year: Int

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

    def __init__(out self, *, copy: PlexBookCard):
        self.rating_key = copy.rating_key
        self.title = copy.title
        self.author = copy.author
        self.thumb = copy.thumb
        self.duration_ms = copy.duration_ms
        self.view_offset_ms = copy.view_offset_ms
        self.leaf_count = copy.leaf_count
        self.viewed_leaf_count = copy.viewed_leaf_count
        self.year = copy.year
