"""Image encoding utilities — pure Mojo implementation.

Encodes raw pixel data into in-memory image buffers (BMP, PPM, PGM, PNG).
Also provides data URI generation via `std.base64`.

PNG uses DEFLATE stored blocks (no compression) — produces valid files
that all decoders read. Actual DEFLATE compression can be added later.

No Python interop required. All operations are pure Mojo.
"""

from std.collections import List
from std.base64 import b64encode


# =====================================================
# Byte writing helpers (mutate buffer in-place)
# =====================================================


def write_le16(mut buf: List[UInt8], value: UInt16):
    """Append a 16-bit little-endian value to the buffer."""
    buf.append(UInt8(value & 0xFF))
    buf.append(UInt8((value >> 8) & 0xFF))


def write_le32(mut buf: List[UInt8], value: UInt32):
    """Append a 32-bit little-endian value to the buffer."""
    buf.append(UInt8(value & 0xFF))
    buf.append(UInt8((value >> 8) & 0xFF))
    buf.append(UInt8((value >> 16) & 0xFF))
    buf.append(UInt8((value >> 24) & 0xFF))


def write_be32(mut buf: List[UInt8], value: UInt32):
    """Append a 32-bit big-endian value to the buffer."""
    buf.append(UInt8((value >> 24) & 0xFF))
    buf.append(UInt8((value >> 16) & 0xFF))
    buf.append(UInt8((value >> 8) & 0xFF))
    buf.append(UInt8(value & 0xFF))


def write_ascii(mut buf: List[UInt8], text: String):
    """Append ASCII string bytes to the buffer."""
    for i in range(text.byte_length()):
        buf.append(UInt8(ord(text[byte=i])))


def append_bytes(mut buf: List[UInt8], data: List[UInt8]):
    """Append all bytes from data to the buffer."""
    for i in range(len(data)):
        buf.append(data[i])


# =====================================================
# imencode — format dispatcher
# =====================================================


def imencode(
    ext: String,
    pixels: List[UInt8],
    width: Int,
    height: Int,
    channels: Int = 3,
) raises -> List[UInt8]:
    """Encode raw pixel data into an image buffer.

    Supports `.bmp`, `.ppm`, `.pgm`, `.png` formats natively.

    Args:
        ext: File extension defining the output format
            (`.bmp`, `.ppm`, `.pgm`, `.png`).
        pixels: Row-major pixel data (RGB for color, gray for single channel).
        width: Image width in pixels.
        height: Image height in pixels.
        channels: Number of channels per pixel (default 3 for RGB).

    Returns:
        List of UInt8 containing the encoded image bytes.
    """
    if width <= 0 or height <= 0:
        raise "imencode: width and height must be positive"

    if ext == ".bmp":
        return imencode_bmp(pixels, width, height, channels)
    elif ext == ".ppm":
        return imencode_ppm(pixels, width, height, channels)
    elif ext == ".pgm":
        return imencode_pgm(pixels, width, height)
    elif ext == ".png":
        return imencode_png(pixels, width, height, channels)
    else:
        raise (
            "imencode: unsupported format '"
            + ext
            + "'. Supported: .bmp, .ppm, .pgm, .png"
        )


# =====================================================
# BMP encoder
# =====================================================


def imencode_bmp(
    pixels: List[UInt8], width: Int, height: Int, channels: Int
) raises -> List[UInt8]:
    """Encode raw RGB pixel data as a BMP image (uncompressed, BI_RGB).

    BMP stores pixels bottom-to-top in BGR order. Rows are padded
    to 4-byte boundaries.

    Args:
        pixels: Row-major pixel data (RGB for 3-channel).
        width: Image width in pixels.
        height: Image height in pixels.
        channels: Channels per pixel (1=gray, 3=RGB, 4=RGBA).

    Returns:
        List of UInt8 containing the complete BMP file bytes.
    """
    if channels < 1 or channels > 4:
        raise "imencode_bmp: channels must be 1 through 4"

    var bpp = channels * 8
    var row_stride = (width * channels + 3) & ~3
    var image_size = row_stride * height
    var pixel_offset = 54
    var file_size = pixel_offset + image_size

    var buf = List[UInt8]()

    # File Header (14 bytes)
    write_ascii(buf, "BM")
    write_le32(buf, UInt32(file_size))
    write_le16(buf, UInt16(0))
    write_le16(buf, UInt16(0))
    write_le32(buf, UInt32(pixel_offset))

    # DIB Header — BITMAPINFOHEADER (40 bytes)
    write_le32(buf, UInt32(40))
    write_le32(buf, UInt32(Int32(width)))
    write_le32(buf, UInt32(Int32(height)))
    write_le16(buf, UInt16(1))
    write_le16(buf, UInt16(bpp))
    write_le32(buf, UInt32(0))
    write_le32(buf, UInt32(image_size))
    write_le32(buf, UInt32(2835))
    write_le32(buf, UInt32(2835))
    write_le32(buf, UInt32(0))
    write_le32(buf, UInt32(0))

    # Pixel Data — bottom-to-top, BGR, padded to 4-byte rows
    for row in range(height):
        var src_row = (height - 1 - row) * width * channels
        for col in range(width):
            var base = src_row + col * channels
            if channels >= 3:
                buf.append(pixels[base + 2])  # B
                buf.append(pixels[base + 1])  # G
                buf.append(pixels[base + 0])  # R
                if channels == 4:
                    buf.append(pixels[base + 3])  # A
            else:
                for c in range(channels):
                    buf.append(pixels[base + c])
        var padding = row_stride - width * channels
        for _ in range(padding):
            buf.append(0)

    return buf^


# =====================================================
# PPM encoder (P6 binary)
# =====================================================


def imencode_ppm(
    pixels: List[UInt8], width: Int, height: Int, channels: Int
) raises -> List[UInt8]:
    """Encode raw RGB pixel data as a PPM (P6 binary) image.

    Args:
        pixels: Row-major RGB pixel data.
        width: Image width in pixels.
        height: Image height in pixels.
        channels: Must be 3 for PPM.

    Returns:
        List of UInt8 containing the complete PPM file bytes.
    """
    if channels != 3:
        raise "imencode_ppm: channels must be 3 for PPM format"

    var header = "P6\n" + String(width) + " " + String(height) + "\n255\n"
    var buf = List[UInt8]()
    write_ascii(buf, header)

    for i in range(len(pixels)):
        buf.append(pixels[i])

    return buf^


# =====================================================
# PGM encoder (P5 binary)
# =====================================================


def imencode_pgm(
    pixels: List[UInt8], width: Int, height: Int
) raises -> List[UInt8]:
    """Encode raw grayscale pixel data as a PGM (P5 binary) image.

    Args:
        pixels: Row-major grayscale pixel data.
        width: Image width in pixels.
        height: Image height in pixels.

    Returns:
        List of UInt8 containing the complete PGM file bytes.
    """
    var header = "P5\n" + String(width) + " " + String(height) + "\n255\n"
    var buf = List[UInt8]()
    write_ascii(buf, header)

    for i in range(len(pixels)):
        buf.append(pixels[i])

    return buf^


# =====================================================
# CRC-32 (for PNG chunk checksums)
# =====================================================


def _build_crc32_table() -> List[UInt32]:
    """Build the CRC-32 lookup table (polynomial 0xEDB88320)."""
    var table = List[UInt32]()
    table.reserve(256)
    for i in range(256):
        var c = UInt32(i)
        for _ in range(8):
            if (c & 1) != 0:
                c = 0xEDB88320 ^ (c >> 1)
            else:
                c = c >> 1
        table.append(c)
    return table^


def crc32_bytes(table: List[UInt32], data: List[UInt8]) -> UInt32:
    """Compute CRC-32 over a byte list using a prebuilt table."""
    var crc: UInt32 = 0xFFFFFFFF
    for i in range(len(data)):
        var idx = (crc ^ UInt32(data[i])) & 0xFF
        crc = table[idx] ^ (crc >> 8)
    return crc ^ 0xFFFFFFFF


# =====================================================
# Adler-32 (for zlib checksum in PNG IDAT)
# =====================================================


def adler32(data: List[UInt8]) -> UInt32:
    """Compute Adler-32 checksum (RFC 1950)."""
    var a: UInt32 = 1
    var b: UInt32 = 0
    var mod: UInt32 = 65521
    for i in range(len(data)):
        a = (a + UInt32(data[i])) % mod
        b = (b + a) % mod
    return (b << 16) | a


# =====================================================
# zlib stored-block framing (for PNG IDAT)
# =====================================================


def zlib_stored(data: List[UInt8]) -> List[UInt8]:
    """Wrap raw data in a zlib stream using DEFLATE stored blocks.

    No actual compression — each block is copied verbatim with a
    3-byte header (BFINAL + BTYPE=00) and LEN/NLEN framing.

    The zlib wrapper adds 2-byte header + 4-byte Adler-32 trailer.
    """
    var out = List[UInt8]()
    # zlib header: CMF=0x78 (deflate, window 32768), FLG=0x01
    out.append(0x78)
    out.append(0x01)

    # Write stored DEFLATE blocks (max 65535 bytes per block)
    var pos = 0
    var remaining = len(data)
    while remaining > 0:
        var block_size = min(remaining, 65535)
        var is_final = pos + block_size >= len(data)

        # BFINAL(1 bit) + BTYPE=00(2 bits), byte-aligned
        out.append(UInt8(1) if is_final else UInt8(0))
        # LEN (2 bytes LE)
        out.append(UInt8(block_size & 0xFF))
        out.append(UInt8((block_size >> 8) & 0xFF))
        # NLEN — one's complement of LEN (2 bytes LE)
        var nlen = UInt16(block_size) ^ 0xFFFF
        out.append(UInt8(nlen & 0xFF))
        out.append(UInt8((nlen >> 8) & 0xFF))
        # Raw data bytes
        for i in range(block_size):
            out.append(data[pos + i])

        pos += block_size
        remaining -= block_size

    # Adler-32 checksum (4 bytes big-endian)
    var checksum = adler32(data)
    write_be32(out, checksum)

    return out^


# =====================================================
# PNG chunk writer
# =====================================================


def write_png_chunk(
    mut buf: List[UInt8],
    table: List[UInt32],
    chunk_type: String,
    chunk_data: List[UInt8],
):
    """Append a PNG chunk to the buffer.

    Chunk layout: length(4 BE) + type(4) + data + CRC32(4 BE).
    CRC covers type + data per PNG spec.
    """
    # CRC is computed over chunk type + chunk data
    var crc_input = List[UInt8]()
    write_ascii(crc_input, chunk_type)
    append_bytes(crc_input, chunk_data)
    var crc = crc32_bytes(table, crc_input)

    write_be32(buf, UInt32(len(chunk_data)))
    write_ascii(buf, chunk_type)
    append_bytes(buf, chunk_data)
    write_be32(buf, crc)


# =====================================================
# PNG encoder
# =====================================================


def imencode_png(
    pixels: List[UInt8], width: Int, height: Int, channels: Int
) raises -> List[UInt8]:
    """Encode raw pixel data as a PNG image (stored blocks, no compression).

    Uses DEFLATE stored blocks — the pixel data is not compressed but
    the output is a fully valid PNG that every decoder can read.

    Args:
        pixels: Row-major pixel data.
        width: Image width in pixels.
        height: Image height in pixels.
        channels: Channels per pixel (1=grayscale, 3=RGB, 4=RGBA).

    Returns:
        List of UInt8 containing the complete PNG file bytes.
    """
    if channels < 1 or channels > 4:
        raise "imencode_png: channels must be 1 through 4"

    var color_type: UInt8
    if channels == 1:
        color_type = UInt8(0)  # Grayscale
    elif channels == 3:
        color_type = UInt8(2)  # RGB
    elif channels == 4:
        color_type = UInt8(6)  # RGBA
    else:
        raise "imencode_png: unsupported channel count"

    var crc_table = _build_crc32_table()
    var buf = List[UInt8]()

    # PNG signature (8 bytes)
    buf.append(0x89)
    write_ascii(buf, "PNG")
    buf.append(0x0D)
    buf.append(0x0A)
    buf.append(0x1A)
    buf.append(0x0A)

    # IHDR chunk data (13 bytes)
    var ihdr = List[UInt8]()
    write_be32(ihdr, UInt32(width))
    write_be32(ihdr, UInt32(height))
    ihdr.append(UInt8(8))  # bit depth: 8 bits per channel
    ihdr.append(color_type)
    ihdr.append(UInt8(0))  # compression: deflate
    ihdr.append(UInt8(0))  # filter: adaptive
    ihdr.append(UInt8(0))  # interlace: none
    write_png_chunk(buf, crc_table, "IHDR", ihdr)

    # Build raw scanlines: each row gets filter byte 0 (None)
    var raw_data = List[UInt8]()
    for row in range(height):
        raw_data.append(UInt8(0))  # filter type: None
        var row_start = row * width * channels
        for col in range(width * channels):
            var idx = row_start + col
            if idx < len(pixels):
                raw_data.append(pixels[idx])
            else:
                raw_data.append(UInt8(0))

    # Wrap scanlines in zlib stored-block stream
    var compressed = zlib_stored(raw_data)
    write_png_chunk(buf, crc_table, "IDAT", compressed)

    # IEND chunk (empty data)
    var iend_data = List[UInt8]()
    write_png_chunk(buf, crc_table, "IEND", iend_data)

    return buf^


# =====================================================
# Data URI generator
# =====================================================


def to_data_uri(
    data: List[UInt8], mime_type: String = "image/png"
) raises -> String:
    """Encode bytes as a data URI string.

    Args:
        data: List of UInt8 containing encoded image data.
        mime_type: MIME type for the data URI prefix.

    Returns:
        Data URI string (e.g. `data:image/png;base64,...`).
    """
    var b64 = b64encode(data)
    return "data:" + mime_type + ";base64," + b64
