# resources/color.mojo — app-local Color struct (R8G8B8A8,
# TrivialRegisterPassable). Palette and all screens import from here.


struct Color(TrivialRegisterPassable):
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8

    def __init__(out self, r: UInt8, g: UInt8, b: UInt8, a: UInt8):
        self.r = r
        self.g = g
        self.b = b
        self.a = a
