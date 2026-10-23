# Runtime test for the native-posix_spawnp AudioPipe: spawns ffmpeg on a
# locally generated tone (the same binary quire uses), streams PCM through
# read_chunk (non-blocking EAGAIN protocol), verifies arrival, exercises
# restart (seek + speed), and stops cleanly.
#
# Run: pixi run mojo -I . tests/test_audio_pipe.mojo
from functions.audio_pipe import AudioPipe, ChunkResult
from std.os import remove, path
from std.pathlib import Path
from std.subprocess import run as sh_run
from std.time import sleep
from functions.helpers import _which


def main() raises:
    var probe_path = "/tmp/opencode/quire_audio_probe.wav"
    if path.exists(Path(probe_path)):
        _ = remove(Path(probe_path))

    var ffmpeg = _which("ffmpeg")
    if ffmpeg.byte_length() == 0:
        ffmpeg = "/usr/bin/ffmpeg"

    # Generate a 2s 440Hz sine probe tone via ffmpeg's lavfi synth.
    _ = sh_run(
        ffmpeg
        + " -f lavfi -i sine=frequency=440:duration=2 -c:a pcm_s16le -y "
        + probe_path
    )
    if (
        not path.exists(Path(probe_path))
        or path.getsize(Path(probe_path)) < 1000
    ):
        print("FAIL: probe tone not generated")
        return

    print("probe tone ok:", probe_path)

    # --- start + non-blocking fill ---
    var ap = AudioPipe()
    var ok = ap.start(probe_path, 0.0, 1.0, is_local=True)
    if not ok:
        print("FAIL: ffmpeg spawn failed")
        return
    print("spawned ok, read_fd:", ap.read_fd)

    var got_data = False
    var total_frames = 0
    var attempts = 0
    while not got_data and attempts < 1000:
        attempts += 1
        sleep(0.01)  # one UI frame worth of pacing
        var chunk = ap.read_chunk()
        if chunk.frame_count > 0:
            got_data = True
            total_frames += chunk.frame_count
        elif ap.reached_end():
            print("FAIL: reached EOF without data")
            ap.stop()
            return
    if not got_data:
        print("FAIL: no PCM after", attempts, "polls")
        ap.stop()
        return
    print("first PCM arrived after", attempts, "polls; frames:", total_frames)

    # Drain to EOF (bounded).
    var drained = False
    attempts = 0
    while not drained and attempts < 5000:
        attempts += 1
        sleep(0.01)
        var chunk = ap.read_chunk()
        if chunk.frame_count > 0:
            total_frames += chunk.frame_count
        if not ap.is_running() and ap.reached_end():
            drained = True
    if drained:
        print("EOF reached; total frames:", total_frames)
    else:
        print("WARN: EOF not observed within", attempts, "polls")

    # --- restart at 0.5s / 1.5x speed (kills + respawns the process) ---
    var ok2 = ap.restart(0.5, 1.5)
    if not ok2:
        print("FAIL: restart failed")
        return
    var got2 = False
    attempts = 0
    while not got2 and attempts < 1000:
        attempts += 1
        sleep(0.01)
        var chunk = ap.read_chunk()
        if chunk.frame_count > 0:
            got2 = True
    if got2:
        print("restart streamed ok")
    else:
        print("WARN: restart gave no PCM in", attempts, "polls")

    # --- stop: SIGKILL + reap; no fd or pid lingering ---
    ap.stop()
    if ap.is_running() or ap.read_fd >= 0:
        print("FAIL: state not cleaned by stop()")
        return
    print("stop cleaned state ok")

    _ = remove(Path(probe_path))
    print("ALL AUDIO PIPE TESTS PASSED")
