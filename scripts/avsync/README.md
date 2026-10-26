# A/V sync measurement for --selftest-sync-markers runs

The self-test with `--selftest-sync-markers` flashes a 160 pt square in the
top-left corner and plays a tick (afplay, a separate process so ScreenCaptureKit
captures it) every 3 s. These scripts find both events and report
tick − flash in ms.

    python3 avsync.py <file> x,y,w,h      # flash: crop luma (ffmpeg); tick: audio peaks (ffmpeg)
    swiftc -O -o /tmp/readticks readticks.swift && /tmp/readticks <file>   # tick times via AVFoundation

Crops used on the MacBook (1512x982 capture): screen.mov `10,10,120,120`;
export (1920x1080 canvas, polished layout) `290,110,80,80`.

ffmpeg ignores the AAC priming trim AVAssetWriter writes into the exported
.mp4 and reads its audio 44 ms late; use readticks (Apple decoding) for export
audio. Both agree on screen.mov.
