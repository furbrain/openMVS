#!/bin/bash
# Build an OpenMVS release in a clean debian:bookworm arm64 container:
#   docker run --rm -v $PWD:/src:ro -v /some/dir:/out -e VERSION=v1 -e COMMIT=$(git rev-parse HEAD) \
#     debian:bookworm bash /src/.github/release/build.sh
# The tarball holds one folder, OpenMVS-<version>, with the binaries in it, for /opt/OpenMVS/current to link to.
# Dependencies are linked statically by vcpkg, so the devices need nothing else installed.
set -euo pipefail
umask 022

: "${VERSION:?}" "${COMMIT:?}"
VERSION=$(printf %s "$VERSION" | tr -c 'A-Za-z0-9._+-' '-') # tags can have slashes etc in them
JOBS=${JOBS:-$(nproc)}
export DEBIAN_FRONTEND=noninteractive

# gives OpenCV 4.14.0, CGAL 6.2.1 etc. vcpkg.json has no baseline, so this is what fixes the versions
VCPKG_COMMIT=44ccfd88b3eca6929d6d16398c7b19945c29a5f6
TRIPLET=arm64-linux-release

apt-get update -qq
apt-get install -qq --no-install-recommends \
  ca-certificates curl git build-essential cmake ninja-build pkg-config zip unzip tar xz-utils file qemu-user \
  python3 python3-venv python3-setuptools python3-jinja2 autoconf autoconf-archive automake libtool libltdl-dev \
  bison flex gperf gettext nasm linux-libc-dev libdbus-1-dev xorg-dev libxmu-dev libxtst-dev libxi-dev \
  libxinerama-dev libxcursor-dev libx11-xcb-dev libxkbcommon-dev libxkbcommon-x11-dev libwayland-dev \
  libgl-dev libegl-dev libglu1-mesa-dev >/dev/null

work=/work
mkdir -p $work
cp -a /src $work/src

export VCPKG_ROOT=$work/vcpkg
git init -q $VCPKG_ROOT
git -C $VCPKG_ROOT fetch -q --depth 1 https://github.com/microsoft/vcpkg.git $VCPKG_COMMIT
git -C $VCPKG_ROOT checkout -q FETCH_HEAD
$VCPKG_ROOT/bootstrap-vcpkg.sh -disableMetrics
export VCPKG_BINARY_SOURCES=clear
export VCPKG_MAX_CONCURRENCY=$JOBS

cmake -S $work/src -B $work/make -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DVCPKG_TARGET_TRIPLET=$TRIPLET \
  -DVCPKG_HOST_TRIPLET=$TRIPLET \
  -DVCPKG_INSTALL_OPTIONS=--clean-after-build \
  -DOpenMVS_USE_CUDA=OFF \
  -DOpenMVS_USE_PYTHON=OFF \
  -DOpenMVS_BUILD_VIEWER=OFF \
  -DCMAKE_INSTALL_PREFIX=$work/install ||
  { # vcpkg puts the actual reason in log files
    find $VCPKG_ROOT/buildtrees -maxdepth 2 -name '*.log' -mmin -5 -exec tail -n 25 {} + >&2
    exit 1
  }
cmake --build $work/make --parallel "$JOBS"
cmake --install $work/make

name=OpenMVS-$VERSION
dest=$work/dist/$name
mkdir -p "$dest"
find $work/install/bin/OpenMVS -maxdepth 1 -type f ! -name Tests -exec cp {} "$dest/" \;
strip --strip-debug "$dest"/*

# nothing but the basic C/C++ runtime may be needed
for f in "$dest"/*; do
  extra=$(readelf -d "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' |
    grep -vE '^(libc|libm|libgcc_s|libstdc\+\+|libgomp|ld-linux-aarch64)\.so' || true)
  if [ -n "$extra" ]; then
    echo "$f needs libraries the devices may not have: $extra" >&2
    exit 1
  fi
done
for tool in InterfaceCOLMAP DensifyPointCloud ReconstructMesh TextureMesh; do
  test -x "$dest/$tool" # the ones TacticalFrog's Makefile uses
done

# run the unit and pipeline tests as a cortex-a76 (the CM5's CPU), as the runners have newer instruction sets
tests=$(find $work/install/bin/OpenMVS -name Tests)
mkdir $work/test
cd $work/test
for n in 0 1; do
  qemu-aarch64 -cpu cortex-a76 "$tests" $n || { tail -n 40 ./*.log >&2; exit 1; }
done

echo "$VERSION $COMMIT" > "$dest/VERSION"
cd /out
tarball=$name-$(uname -m).tar.gz
tar -C $work/dist --owner=0 --group=0 -czf "$tarball" "$name"
sha256sum "$tarball" > "$tarball.sha256"
