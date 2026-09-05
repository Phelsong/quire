struct Screen:
    var current: Int  # 0=login, 1=library, 2=player, 3=selection

    def __init__(out self):
        self.current = 0
