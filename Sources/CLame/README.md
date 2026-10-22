# CLame — the LAME MP3 encoder, vendored

Ata writes each meeting as one MP3 (`meeting.mp3`). macOS can decode MP3 but ships no
encoder, so the encoder part of [LAME](https://lame.sourceforge.io) is built in here.

- Version: **3.100**, from `lame-3.100.tar.gz`
  (<https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz>),
  SHA-256 `ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e`.
- Taken unchanged: `libmp3lame/*.c`, `libmp3lame/*.h`, `libmp3lame/vector/lame_intrin.h`
  (two files include it unconditionally; nothing from it is called) and `include/lame.h`.
- Left out: `mpglib_interface.c` and the `mpglib/` decoder (AVFoundation decodes), the x86
  SSE code in `vector/`, and the `lame` command-line frontend.
- Written for Ata: `config.h` (what `./configure` would generate for arm64 macOS, plus three
  `#pragma clang diagnostic ignored` lines for warnings upstream code trips on a modern clang)
  and `include/module.modulemap`.

LAME is licensed under the GNU LGPL, version 2 or later — see `COPYING`. Ata itself is MIT;
because Ata's full source is public, anyone can rebuild it against a modified LAME, which is
what the LGPL asks of a statically linked library.

To update: download the new tarball, check its hash, replace the files listed above, and keep
`config.h` and `include/module.modulemap`.
