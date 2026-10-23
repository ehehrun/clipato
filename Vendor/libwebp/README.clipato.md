# libwebp 1.6.0

Source: https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz

Release: https://chromium.googlesource.com/webm/libwebp/+/refs/tags/v1.6.0

Archive SHA-256: `e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564`

The upstream C and header files are unchanged. This directory retains the
encoder, its shared DSP and utilities, and SharpYUV. Decoder codec, mux, demux,
command-line programs, examples, and unsupported MIPS implementations are omitted.
The shared DSP includes reconstruction routines used during encoding; ImageIO
continues to handle application decoding.

SwiftPM compiles this as the static `CWebP` target for the application's macOS
deployment target, with native ARM NEON / x86 SSE2 support and thread-safe DSP
initialization. The module exposes the upstream `src/webp/encode.h` API directly.
No runtime library lookup or external executable is required.

COPYING, PATENTS, and AUTHORS are retained here and copied into the app bundle
under `Contents/Resources/ThirdParty/libwebp/`.
