#!/bin/bash
# Builds the macOS toolchain into build/ and fetches the dustbuilder stage1 FEL package into $DATA.
# Every third-party input is pinned: sunxi-tools to a commit that must match Debian's orig tarball
# byte-for-byte, the stage1 package and Debian 13's android-platform-tools source (libsparse, the code fastboot
# uses to split big images) to a sha256. Needs: Xcode CLT, brew libusb + dtc. No sudo.
set -euo pipefail
cd "$(dirname "$0")/.."
DATA=${DATA:-$HOME/dreame-l40}
BUILD=build
SUNXI_COMMIT=4390ca668f3b2e62f885edb6952b189c4489d83d
DEBIAN_ORIG=https://deb.debian.org/debian/pool/main/s/sunxi-tools/sunxi-tools_1.4.2+git20240825.4390ca.orig.tar.gz
STAGE1_URL=https://builder.dontvacuum.me/nextgen/dust-fel-mr813.tar.gz
STAGE1_SHA256=d53292fa35a4241aa6ce3ed6f391f0ab53a248c10cd28fbb8e00e6c0e56f1934
# Debian 13 (trixie) android-platform-tools 34.0.5-12 = the fastboot the Valetudo guide tested; sha256 from its .dsc.
# Debian's only libsparse patch restores simg2simg.cpp; the library itself is unpatched upstream code.
APT_ORIG=https://deb.debian.org/debian/pool/main/a/android-platform-tools/android-platform-tools_34.0.5.orig.tar.xz
APT_SHA256=4893f6a85b205f1df2c35cde5d6ca3bedd5e9f19afdb3b5ac781e647aa2243f4
BREW=$(brew --prefix)

mkdir -p "$BUILD" "$DATA"

if [ ! -x "$BUILD/sunxi-tools/sunxi-fel" ]; then
  rm -rf "$BUILD/sunxi-tools" "$BUILD/debian-src"
  git clone -q https://github.com/linux-sunxi/sunxi-tools.git "$BUILD/sunxi-tools"
  git -C "$BUILD/sunxi-tools" -c advice.detachedHead=false checkout -q "$SUNXI_COMMIT"
  mkdir -p "$BUILD/debian-src"
  curl -4 -sSfL "$DEBIAN_ORIG" | tar -xz -C "$BUILD/debian-src" --strip-components=1
  diff -r -q -x .git -x .gitignore -x .github "$BUILD/sunxi-tools" "$BUILD/debian-src"
  echo "sunxi-tools $SUNXI_COMMIT matches Debian's orig tarball"
  make -s -C "$BUILD/sunxi-tools" sunxi-fel \
    LIBUSB_CFLAGS="-I$BREW/opt/libusb/include/libusb-1.0" LIBUSB_LIBS="-L$BREW/opt/libusb/lib -lusb-1.0" \
    ZLIB_CFLAGS="" ZLIB_LIBS="-lz" CFLAGS="-I$BREW/opt/dtc/include" LDFLAGS="-L$BREW/opt/dtc/lib"
fi

cc -O2 -Wall -Wextra -I"$BREW/opt/libusb/include/libusb-1.0" -L"$BREW/opt/libusb/lib" -lusb-1.0 \
  -o "$BUILD/fbtool" tools/fbtool.c

if [ ! -f "$BUILD/apt-src/system/core/libsparse/sparse.cpp" ]; then
  curl -4 -sSfL -o "$BUILD/apt-orig.tar.xz" "$APT_ORIG"
  echo "$APT_SHA256  $BUILD/apt-orig.tar.xz" | shasum -a 256 -c -
  mkdir -p "$BUILD/apt-src"
  tar -xJf "$BUILD/apt-orig.tar.xz" -C "$BUILD/apt-src" ./system/core/libsparse ./system/libbase
  rm "$BUILD/apt-orig.tar.xz"
fi
SP=$BUILD/apt-src/system/core/libsparse
LIBSPARSE=("$SP/backed_block.cpp" "$SP/output_file.cpp" "$SP/sparse.cpp" "$SP/sparse_crc32.cpp" "$SP/sparse_err.cpp"
  "$SP/sparse_read.cpp" "$BUILD/apt-src/system/libbase/mapped_file.cpp" "$BUILD/apt-src/system/libbase/stringprintf.cpp")
CXX_SPARSE=(c++ -std=c++17 -O2 -Wall -I"$SP/include" -I"$BUILD/apt-src/system/libbase/include")
"${CXX_SPARSE[@]}" "${LIBSPARSE[@]}" tools/fbsparse.cpp -lz -o "$BUILD/fbsparse"
"${CXX_SPARSE[@]}" "${LIBSPARSE[@]}" "$SP/simg2img.cpp" -lz -o "$BUILD/simg2img"

if [ ! -f "$DATA/stage1/payload.bin" ]; then
  curl -sSfL -o "$DATA/dust-fel-mr813.tar.gz" "$STAGE1_URL"
  echo "$STAGE1_SHA256  $DATA/dust-fel-mr813.tar.gz" | shasum -a 256 -c -
  mkdir -p "$DATA/stage1"
  tar -xzf "$DATA/dust-fel-mr813.tar.gz" -C "$DATA/stage1"
fi

echo "ready: $BUILD/sunxi-tools/sunxi-fel, $BUILD/fbtool, $BUILD/fbsparse, $BUILD/simg2img, $DATA/stage1"
