# CVMFS client package — built from source with patches for NixOS.
#
# Nix concept: this file is a *function* that takes its dependencies as
# arguments. When the flake calls `pkgs.callPackage ./pkgs/cvmfs.nix {}`,
# Nix automatically fills in arguments that match attribute names in nixpkgs
# (e.g., `cmake`, `openssl`). This is "callPackage" dependency injection.
#
# The function returns a *derivation* — a build recipe that produces
# output in /nix/store/<hash>-cvmfs-<version>/.

{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  pkg-config,
  # Build dependencies — libraries CVMFS links against
  openssl,
  zlib,
  curl,
  sqlite,
  libuuid,
  libarchive,
  fuse,
  fuse3,
  leveldb,
  protobuf,
  libcap,
  attr,
  c-ares,
  sparsehash,
  # For the mount helper and cvmfs_config
  python3,
  perl,
  gdb,
}:

stdenv.mkDerivation rec {
  pname = "cvmfs";
  version = "2.13.3";

  # Fetch the source tarball from GitHub at the release tag.
  # The `hash` field ensures reproducibility — Nix verifies the download
  # matches this hash exactly. On first build, leave it as empty string "",
  # build will fail and print the correct hash.
  src = fetchFromGitHub {
    owner = "cvmfs";
    repo = "cvmfs";
    rev = "cvmfs-${version}";
    hash = "sha256-lMqEDOJnn8OuwxLFFzWSaAfsFJKZoMitS9ziyPO0ca0=";
  };

  # nativeBuildInputs: tools needed at *build time* only (compilers, generators).
  # These run on the build machine, not the target.
  nativeBuildInputs = [
    cmake
    pkg-config
    python3
    perl
    gdb
  ];

  # buildInputs: libraries needed at *build and run time*.
  # These get linked into the final binary.
  buildInputs = [
    openssl
    zlib
    curl
    sqlite
    libuuid
    libarchive
    fuse # FUSE 2
    fuse3 # FUSE 3 — CVMFS builds against both
    leveldb
    protobuf
    libcap
    attr
    c-ares
    sparsehash
  ];

  # Patch hardcoded paths that assume FHS layout (/usr/bin, /usr/libexec).
  # NixOS doesn't have /usr — everything lives in /nix/store.
  #
  # `placeholder "out"` evaluates to the Nix store path of this package's
  # output, so the patched binary knows where to find its own files.
  postPatch = ''
    # 1. mount.cvmfs helper looks for cvmfs2 in /usr/bin
    #    GetCvmfsBinary() adds "/usr/bin" to its search paths vector
    substituteInPlace mount/mount.cvmfs.cc \
      --replace-fail '"/usr/bin"' '"${placeholder "out"}/bin"'

    # 2. cvmfs2 dlopen()s libcvmfs_fuse*.so from hardcoded /usr/lib paths.
    #    There are TWO code paths: fuse_main.cc (initial load) and loader.cc
    #    (reload). Both need patching.
    substituteInPlace cvmfs/fuse_main.cc \
      --replace-fail \
        'library_paths.push_back("/usr/lib/" + libname_fuse3);' \
        'library_paths.push_back("${placeholder "out"}/lib/" + libname_fuse3);
    library_paths.push_back("/usr/lib/" + libname_fuse3);'

    substituteInPlace cvmfs/fuse_main.cc \
      --replace-fail \
        'library_paths.push_back("/usr/lib/" + libname_fuse2);' \
        'library_paths.push_back("${placeholder "out"}/lib/" + libname_fuse2);
    library_paths.push_back("/usr/lib/" + libname_fuse2);'

    substituteInPlace cvmfs/loader.cc \
      --replace-fail \
        'library_paths.push_back("/usr/lib/" + library_name);' \
        'library_paths.push_back("${placeholder "out"}/lib/" + library_name);
    library_paths.push_back("/usr/lib/" + library_name);'

    # 3. Default authz helper search path is /usr/libexec/cvmfs/authz
    #    (renumbered from here — was #2 before library path fix above)
    substituteInPlace cvmfs/mountpoint.cc \
      --replace-fail '"/usr/libexec/cvmfs/authz"' \
                     '"${placeholder "out"}/libexec/cvmfs/authz"'

    # 3. Remove LibreSSL-only guard in openssl_version.h.
    #    CVMFS normally vendors LibreSSL for libcvmfs_crypto, but we use
    #    system OpenSSL which is API-compatible. The guard fires when
    #    CVMFS_LIBRARY is defined (debug/library builds).
    substituteInPlace cvmfs/crypto/openssl_version.h \
      --replace-fail '#error "picking up OpenSSL includes instead of LibreSSL"' \
                     '/* NixOS: using system OpenSSL instead of LibreSSL */'

    # 4. Remove the install(CODE ...) block that creates /etc/auto.cvmfs symlink.
    #    This would fail in the Nix sandbox (can't write to /etc at build time).
    #    We don't need autofs anyway — we use systemd automount.
    #    The block ends with '  ")' — match that specifically.
    sed -i '/install(CODE/,/^[[:space:]]*")/d' mount/CMakeLists.txt

    # 5. Fix hardcoded /usr/lib/systemd/system path for the reload service unit.
    #    Redirect to $out/lib/systemd/system so it installs inside the Nix store.
    substituteInPlace cvmfs/CMakeLists.txt \
      --replace-fail 'DESTINATION /usr/lib/systemd/system' \
                     'DESTINATION ''${CMAKE_INSTALL_PREFIX}/lib/systemd/system'

    # 6. Fix mount helper install path. CVMFS hardcodes /sbin for mount.cvmfs
    #    on Linux. NixOS needs it in $out/bin for system.fsPackages to find it.
    substituteInPlace CMakeLists.txt \
      --replace-fail 'set (CMAKE_MOUNT_INSTALL_BINDIR "/sbin")' \
                     'set (CMAKE_MOUNT_INSTALL_BINDIR "''${CMAKE_INSTALL_PREFIX}/bin")' \
      --replace-fail 'set (CMAKE_MOUNT_INSTALL_BINDIR "/usr/bin")' \
                     'set (CMAKE_MOUNT_INSTALL_BINDIR "''${CMAKE_INSTALL_PREFIX}/bin")'
  '';

  # CMake flags — build only the FUSE client, not the server or other tools.
  # Each -D flag sets a CMake variable that controls what gets built.
  cmakeFlags = [
    # What to build
    "-DBUILD_CVMFS=ON" # The FUSE client (cvmfs2 binary)
    "-DBUILD_LIBCVMFS=OFF" # C library interface — not needed for mount usage
    "-DBUILD_LIBCVMFS_CACHE=OFF" # Cache plugin library
    "-DBUILD_SERVER=OFF" # Server (cvmfs_server) — we're a client
    "-DBUILD_SERVER_DEBUG=OFF"
    "-DBUILD_RECEIVER=OFF" # Publication receiver
    "-DBUILD_GEOAPI=OFF" # Geo API service
    "-DBUILD_GATEWAY=OFF" # Repository gateway
    "-DBUILD_DUCC=OFF" # Container unpacking
    "-DBUILD_SNAPSHOTTER=OFF" # containerd snapshotter
    "-DBUILD_UNITTESTS=OFF" # Tests
    "-DBUILD_UNITTESTS_CVMFS=OFF"
    "-DBUILD_PRELOADER=OFF" # Preloader tool
    "-DBUILD_SHRINKWRAP=OFF" # Shrinkwrap tool

    # What to install
    "-DINSTALL_MOUNT_SCRIPTS=ON" # mount.cvmfs helper — needed for systemd
    "-DINSTALL_PUBLIC_KEYS=ON" # CERN/EGI/OSG public keys
    "-DINSTALL_BASH_COMPLETION=OFF"

    # Use system libraries from Nix instead of vendored/downloaded copies.
    # This is important for Nix: the build sandbox has no network access,
    # so CVMFS can't download its vendored externals during build.
    "-DBUILTIN_EXTERNALS=OFF"

    # CVMFS's FindLibcrypto.cmake only looks in EXTERNALS_INSTALL_LOCATION
    # (for vendored LibreSSL). With BUILTIN_EXTERNALS=OFF, we bypass it by
    # setting the CMake variables directly to point at Nix's OpenSSL.
    # The crypto code uses <openssl/...> headers, so OpenSSL works fine.
    "-DLibcrypto_INCLUDE_DIRS=${openssl.dev}/include"
    "-DLibcrypto_LIBRARIES=${openssl.out}/lib/libcrypto.so"

  ];

  # CVMFS vendors two tiny libraries (vjson and sha3) not available in nixpkgs.
  # We build them from the bundled sources before CMake runs, then point CMake
  # at them via cmakeFlagsArray (which supports shell variables, unlike cmakeFlags).
  preConfigure = ''
    export CVMFS_EXTERNALS=$TMPDIR/cvmfs-externals
    mkdir -p $CVMFS_EXTERNALS/{lib,include}

    # Build vjson (tiny JSON parser — 2 source files)
    pushd externals/vjson/src
    make clean 2>/dev/null || true
    make CVMFS_BASE_CXX_FLAGS="$NIX_CFLAGS_COMPILE" -j$NIX_BUILD_CORES
    cp json.h block_allocator.h $CVMFS_EXTERNALS/include/
    cp libvjson.a $CVMFS_EXTERNALS/lib/
    popd

    # Build sha3 (Keccak SHA-3 implementation)
    pushd externals/sha3/src
    echo 64opt > arch
    rm -f SnP-interface.h
    ln -s 64opt/SnP-interface.h SnP-interface.h
    make clean 2>/dev/null || true
    make CVMFS_BASE_C_FLAGS="$NIX_CFLAGS_COMPILE" ARCH=64opt -j$NIX_BUILD_CORES
    cp *.h $CVMFS_EXTERNALS/include/
    cp libsha3.a $CVMFS_EXTERNALS/lib/
    popd

    # Build pacparser (proxy auto-config parser, bundles SpiderMonkey).
    # The nixpkgs pacparser is broken on multiple channels (ancient SpiderMonkey
    # + modern GCC = crashes). CVMFS ships a patched version that works.
    # Key: build only library targets (-j1), NOT the default target which runs tests.
    pushd externals/pacparser
    tar xzf pacparser-1.4.3.tar.gz
    cd pacparser-1.4.3
    for p in ../src/fix_cflags.patch ../src/fix_c99.patch \
             ../src/fix_git_dependency.patch ../src/fix_python_setuptools.patch \
             ../src/fix_gcc14.patch; do
      patch -p0 < "$p"
    done
    # Fix hardcoded /bin paths (don't exist in Nix sandbox)
    patchShebangs .
    find . -name "Makefile" -exec sed -i -e 's|/bin/bash|bash|g' -e 's|/bin/true|true|g' {} +
    # Disable Nix hardening for this sub-build — SpiderMonkey's -Wno-format
    # conflicts with Nix's injected -Werror=format-security
    NIX_HARDENING_ENABLE="" \
    make PYTHON=python3 -C src clean -j$NIX_BUILD_CORES || true
    NIX_HARDENING_ENABLE="" \
    make PYTHON=python3 CVMFS_BASE_C_FLAGS="-Wno-error -Wno-cpp" \
         -j1 -C src pacparser.o spidermonkey/libjs.a
    # Create a single static library from pacparser + SpiderMonkey objects
    mkdir -p src/static
    cp src/pacparser.o src/spidermonkey/libjs.a src/static/
    pushd src/static
    ar x libjs.a
    rm -f libjs.a
    ar rcs libpacparser.a *.o
    rm -f *.o
    popd
    cp src/pacparser.h $CVMFS_EXTERNALS/include/
    cp src/static/libpacparser.a $CVMFS_EXTERNALS/lib/
    popd

    # Tell CMake where to find the locally-built libraries.
    # cmakeFlagsArray is a bash array that Nix's cmake setup hook appends
    # to the cmake command line. Unlike cmakeFlags (a Nix list evaluated
    # at derivation time), it can reference shell variables like $TMPDIR.
    cmakeFlagsArray+=(
      "-DVJSON_INCLUDE_DIRS=$CVMFS_EXTERNALS/include"
      "-DVJSON_LIBRARIES=$CVMFS_EXTERNALS/lib/libvjson.a"
      "-DSHA3_INCLUDE_DIRS=$CVMFS_EXTERNALS/include"
      "-DSHA3_LIBRARIES=$CVMFS_EXTERNALS/lib/libsha3.a"
      "-DPACPARSER_INCLUDE_DIR=$CVMFS_EXTERNALS/include"
      "-DPACPARSER_LIBRARIES=$CVMFS_EXTERNALS/lib/libpacparser.a"
    )
  '';

  # If mount.cvmfs ends up in sbin/ instead of bin/, move it so
  # system.fsPackages can find it on PATH.
  postInstall = ''
    if [ -f "$out/sbin/mount.cvmfs" ] && [ ! -f "$out/bin/mount.cvmfs" ]; then
      mv "$out/sbin/mount.cvmfs" "$out/bin/mount.cvmfs"
    fi
    # Also ensure mount.fuse.cvmfs2 alias exists (systemd looks for this)
    if [ -f "$out/bin/mount.cvmfs" ] && [ ! -f "$out/bin/mount.fuse.cvmfs2" ]; then
      ln -s mount.cvmfs "$out/bin/mount.fuse.cvmfs2"
    fi
  '';

  # cvmfs2 dlopen()s libcvmfs_fuse3.so at runtime, which in turn needs
  # libcvmfs_crypto.so and libcvmfs_util.so from the same directory.
  # Since dlopen doesn't use the executable's RPATH, the libraries need
  # their own RPATH pointing to their own directory ($ORIGIN).
  postFixup = ''
    for lib in $out/lib/libcvmfs_fuse3.so.* $out/lib/libcvmfs_fuse3_debug.so.*; do
      [ -L "$lib" ] && continue  # skip symlinks
      patchelf --add-rpath '$ORIGIN' "$lib"
    done
  '';

  meta = with lib; {
    description = "CernVM File System — FUSE client for software distribution";
    homepage = "https://cernvm.cern.ch/fs/";
    license = licenses.bsd3;
    platforms = [ "x86_64-linux" ];
    mainProgram = "cvmfs2";
  };
}
