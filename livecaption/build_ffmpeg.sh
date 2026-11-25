#!/usr/bin/env bash
# Run from MSYS2 UCRT64 with gcc and GNU make available.
set -euo pipefail

ffmpeg_version=9.1
ffmpeg_sha256=1a4d394ae63d190a526cd052eb4415c156b5c5e2df37efab41a7de0b8fde2433
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
build_root="${1:-$script_dir/../.local/windows-build}"
build_root="$(cd -- "$build_root" && pwd)"
archive="$build_root/sources/ffmpeg-$ffmpeg_version.tar.xz"
source_dir="$build_root/ffmpeg-$ffmpeg_version"
output="$build_root/ffmpeg"
work="$build_root/ffmpeg-work"

test "$(gcc -dumpmachine)" = x86_64-w64-mingw32
printf '%s  %s\n' "$ffmpeg_sha256" "$archive" | sha256sum --check -
mkdir -p "$work" "$output"
tar -xJf "$archive" -C "$build_root"
export TMPDIR="$work"
cd -- "$work"
"$source_dir/configure" \
    --target-os=mingw32 --arch=x86_64 --disable-autodetect \
    --disable-gpl --disable-version3 --disable-nonfree --disable-network \
    --disable-shared --enable-static --disable-x86asm --disable-debug --disable-doc \
    --disable-ffplay --disable-avdevice --disable-swscale --disable-everything \
    --enable-protocol=file,pipe \
    --enable-demuxer=mov,matroska,avi,asf,wav,mp3,flac,ogg,aac \
    --enable-decoder=aac,alac,opus,vorbis,flac,mp3,mp3float,ac3,eac3,wmav1,wmav2,wmapro,pcm_u8,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f64le \
    --enable-parser=aac,flac,mpegaudio,opus,vorbis,ac3 \
    --enable-filter=aresample,aformat,anull,atrim \
    --enable-encoder=pcm_s16le --enable-muxer=pcm_s16le \
    --extra-ldflags=-static
make -j "${ECHOPANE_FFMPEG_JOBS:-4}" ffmpeg.exe ffprobe.exe
strip -o "$output/ffmpeg.exe" ffmpeg.exe
strip -o "$output/ffprobe.exe" ffprobe.exe
cp -- "$source_dir/COPYING.LGPLv2.1" "$output/COPYING.LGPLv2.1"
toolchain_notices="$(dirname -- "$(command -v gcc)")/../share/licenses"
mkdir -p "$output/compiler-notices/gcc-libs" "$output/compiler-notices/crt"
cp -- "$toolchain_notices/gcc-libs/"* "$output/compiler-notices/gcc-libs/"
cp -- "$toolchain_notices/crt/"* "$output/compiler-notices/crt/"
"$output/ffmpeg.exe" -version
