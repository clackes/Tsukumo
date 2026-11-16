# Third-party components

Tsukumo is licensed under the GNU General Public License v3.0 only ([LICENSE](LICENSE)). It includes a few third-party components that remain under their own licenses. Nothing in Tsukumo's license limits the rights those licenses give you over those components.

## ffmpeg (LGPL-2.1-or-later)

The Converti module uses a separate **ffmpeg** executable, shipped inside the app's `Converter.xpc` helper (`Tsukumo.app/Contents/XPCServices/Converter.xpc/Contents/Resources/`), only for WebP, MP3, FLAC, Opus, WebM, MKV and animated GIF. It is an **LGPL** build: never `--enable-gpl` or `--enable-nonfree`. The same folder in the app contains `BUILDCONF.txt`, `SOURCES.txt` and the licenses. The build script is [Tools/ffmpeg/build.sh](Tools/ffmpeg/build.sh).

You can replace that executable with your own compatible ffmpeg build.

**Exact sources** used for the build (all static, arm64):

| Component | Source | SHA-256 |
|---|---|---|
| ffmpeg | <https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz> | `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e` |
| libwebp | <https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz> | `e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564` |
| lame | <https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz> | `3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb` |
| opus | <https://ftp.osuosl.org/pub/xiph/releases/opus/opus-1.6.1.tar.gz> | `6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1` |
| libvpx | <https://github.com/webmproject/libvpx/archive/refs/tags/v1.17.0.tar.gz> | `1020f184046187baa2985dbde38e0691f49c44088bca7a1842b0236c6081dc0a` |
| svtav1 | <https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v4.3.0/SVT-AV1-v4.3.0.tar.bz2> | `9223ce06e6172ad41357ed23b3b00f036e03794b86b0e20ea9ccb3f648b8955d` |
| dav1d | <https://code.videolan.org/videolan/dav1d/-/archive/1.5.4/dav1d-1.5.4.tar.bz2> | `2abfb0c89212e6e4733a54e0ae509ec00a5b845a6360946f918806e14aedb011` |

**Configuration:**

```
configuration:
    --prefix=<prefix>
    --arch=arm64
    --cc=clang
    --extra-cflags='-arch arm64 -mmacosx-version-min=26.0 -O2 -I<prefix>/include'
    --extra-ldflags='-arch arm64 -mmacosx-version-min=26.0 -L<prefix>/lib'
    --pkg-config-flags=--static
    --disable-shared
    --enable-static
    --disable-autodetect
    --disable-network
    --disable-indevs
    --disable-outdevs
    --disable-ffplay
    --disable-ffprobe
    --disable-doc
    --disable-debug
    --enable-zlib
    --enable-bzlib
    --enable-videotoolbox
    --enable-audiotoolbox
    --enable-libwebp
    --enable-libmp3lame
    --enable-libopus
    --enable-libvpx
    --enable-libsvtav1
    --enable-libdav1d
```

Licenses: ffmpeg LGPL-2.1, LAME LGPL; libwebp, Opus, libvpx, SVT-AV1 and dav1d BSD. The texts are in [ThirdParty/licenses/](ThirdParty/licenses).

If a link stops working, open an [issue](https://github.com/clackes/Tsukumo/issues) and we will send you the source archive, for at least three years after the last release that uses it.

## Duo module (MIT)

### fx-xf/duo (MIT)

<https://github.com/fx-xf/duo>, Copyright (c) 2026 fx-xf. The Duo module adapts its code to Tsukumo's energy rules (event-driven sensor instead of an always-on timer, capture started only while the hinge is moving) and to Swift 6.

### elijah-semyonov/DuoLikeAnimation (MIT)

<https://github.com/elijah-semyonov/DuoLikeAnimation>, Copyright (c) 2026 Elijah Semyonov. The shader's frosted-glass model (fixed eye, per-pixel ray, blur and darkening that grow with distance) follows this project, through fx-xf/duo.

### MIT license text

```
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## mediaremote-adapter (BSD-3-Clause)

<https://github.com/ejbills/mediaremote-adapter> (fork of <https://github.com/ungive/mediaremote-adapter>), Copyright (c) 2025 Jonas van den Berg and contributors, (c) 2025-2026 ejbills. Used by the Island to read the track that is playing. Vendored in [Packages/Vendor/mediaremote-adapter](Packages/Vendor/mediaremote-adapter); license text in [ThirdParty/licenses/mediaremote-adapter-BSD-3-Clause.txt](ThirdParty/licenses/mediaremote-adapter-BSD-3-Clause.txt).
