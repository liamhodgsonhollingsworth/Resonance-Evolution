#!/usr/bin/env python3
"""Generate a short, LICENSE-CLEAN synthetic demo mp3 for the visi-sonor item-10 demo.

Synthetic = no copyright: a ~12s tone-sweep-with-beat. A 4-on-the-floor kick drum
(low sine burst with fast decay) at 120 BPM + a slow sine sweep rising through the
mid/treble range, so the analyzer produces clearly-changing low/mid/high bands.

Encodes to real MPEG-1 Layer III via `lameenc` (pip-installable, ships wheels).
Best-effort: if lameenc is unavailable the demo still runs off prim_demo_audio_loop.

Usage: py -3 scripts/gen_demo_mp3.py <out_path.mp3>
"""
import math
import struct
import sys


def synth_pcm(sample_rate: int, seconds: float) -> bytes:
    """Return interleaved stereo 16-bit PCM bytes for the synthetic clip."""
    bpm = 120.0
    beat = 60.0 / bpm
    n = int(sample_rate * seconds)
    frames = bytearray()
    for i in range(n):
        t = i / sample_rate
        # KICK: exponential-decay low sine burst on each beat -> strong LOW band.
        phase_in_beat = t % beat
        kick_env = math.exp(-phase_in_beat / 0.09)
        kick = 0.7 * kick_env * math.sin(2.0 * math.pi * 60.0 * t)
        # SWEEP: a sine whose frequency rises 300 Hz -> 5 kHz over an 8 s cycle -> MID/HIGH move.
        sweep_pos = 0.5 + 0.5 * math.sin(2.0 * math.pi * t / 8.0)
        sweep_hz = 300.0 + sweep_pos * 4700.0
        sweep = 0.35 * math.sin(2.0 * math.pi * sweep_hz * t)
        # A steady hi-hat-ish shimmer so treble is never fully dead.
        hat = 0.08 * math.sin(2.0 * math.pi * 9000.0 * t) * (0.5 + 0.5 * math.sin(2.0 * math.pi * 8.0 * t))
        s = kick + sweep + hat
        s = max(-1.0, min(1.0, s))
        v = int(s * 30000)
        frames += struct.pack("<hh", v, v)  # stereo (same in both channels)
    return bytes(frames)


def main() -> int:
    out = sys.argv[1] if len(sys.argv) > 1 else "assets/audio/demo_tone_sweep_beat.mp3"
    sample_rate = 44100
    seconds = 12.0
    try:
        import lameenc  # type: ignore
    except Exception as e:  # pragma: no cover - best-effort path
        print("LAMEENC_MISSING: %s" % e)
        return 2
    pcm = synth_pcm(sample_rate, seconds)
    enc = lameenc.Encoder()
    enc.set_bit_rate(128)
    enc.set_in_sample_rate(sample_rate)
    enc.set_channels(2)
    enc.set_quality(2)
    mp3 = enc.encode(pcm)
    mp3 += enc.flush()
    import os
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as f:
        f.write(mp3)
    print("WROTE %s (%d bytes)" % (out, len(mp3)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
