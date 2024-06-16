#!/usr/bin/env bash

# turn on verbose debugging output for parabuild logs.
exec 4>&1; export BASH_XTRACEFD=4; set -x
# make errors fatal
set -e
# complain about unset env variables
set -u

APR_INCLUDE_DIR="apr/include"

if [ -z "$AUTOBUILD" ] ; then
    exit 1
fi

if [ "$OSTYPE" = "cygwin" ] ; then
    autobuild="$(cygpath -u $AUTOBUILD)"
else
    autobuild="$AUTOBUILD"
fi

STAGING_DIR="$(pwd)"
TOP_DIR="$(dirname "$0")"

# load autobuild provided shell functions and variables
source_environment_tempfile="$STAGING_DIR/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

# extract APR version into VERSION.txt
APR_INCLUDE_DIR="../apr/include"
# will match -- #<whitespace>define<whitespace>APR_MAJOR_VERSION<whitespace>number  future proofed :)
major_version="$(sed -n -E 's/#[[:space:]]*define[[:space:]]+APR_MAJOR_VERSION[[:space:]]+([0-9]+)/\1/p' "${APR_INCLUDE_DIR}/apr_version.h")"
minor_version="$(sed -n -E 's/#[[:space:]]*define[[:space:]]+APR_MINOR_VERSION[[:space:]]+([0-9]+)/\1/p' "${APR_INCLUDE_DIR}/apr_version.h")"
patch_version="$(sed -n -E 's/#[[:space:]]*define[[:space:]]+APR_PATCH_VERSION[[:space:]]+([0-9]+)/\1/p' "${APR_INCLUDE_DIR}/apr_version.h")"
version="${major_version}.${minor_version}.${patch_version}"
echo "${version}" > "${STAGING_DIR}/VERSION.txt"

case "$AUTOBUILD_PLATFORM" in
  windows*)
    pushd "$TOP_DIR"
    DEBUG_OUT_DIR="$STAGING_DIR/lib/debug"
    RELEASE_OUT_DIR="$STAGING_DIR/lib/release"

    load_vsvars

    # We've observed some weird failures in which the PATH is too big to be
    # passed to a child process! When that gets munged, we start seeing errors
    # like failing to understand the 'nmake' command. Thing is, by this point
    # in the script we've acquired a shocking number of duplicate entries.
    # Dedup the PATH using Python's OrderedDict, which preserves the order in
    # which you insert keys.
    # We find that some of the Visual Studio PATH entries appear both with and
    # without a trailing slash, which is pointless. Strip those off and dedup
    # what's left.
    # Pass the existing PATH as an explicit argument rather than reading it
    # from the environment to bypass the fact that cygwin implicitly converts
    # PATH to Windows form when running a native executable. Since we're
    # setting bash's PATH, leave everything in cygwin form. That means
    # splitting and rejoining on ':' rather than on os.pathsep, which on
    # Windows is ';'.
    # Use python -u, else the resulting PATH will end with a spurious '\r'.
    export PATH="$(python -u -c "import sys
from collections import OrderedDict
print(':'.join(OrderedDict((dir.rstrip('/'), 1) for dir in sys.argv[1].split(':'))))" "$PATH")"

    export PATH="$(python -u -c "import sys
print(':'.join(d for d in sys.argv[1].split(':')
if not any(frag in d for frag in ('CommonExtensions', 'VSPerfCollectionTools', 'Team Tools'))))" "$PATH")"

    python -c "print(' PATH '.center(72, '='))"
    cygpath -p -m "$PATH" | tr ';' '\n'
    python -c "print(' ${#PATH} chars in PATH '.center(72, '='))"

    if [ "$AUTOBUILD_ADDRSIZE" = 32 ]
      then 
        bitdir="/Win32"
      else
        bitdir="/x64"
    fi

    which nmake

    for proj in apr aprutil apriconv
      do msbuild.exe $(cygpath -w 'apr-util/aprutil.sln') /t:"$proj" /p:Configuration=Debug /p:Platform=$AUTOBUILD_WIN_VSPLATFORM
    done

    mkdir -p "$DEBUG_OUT_DIR" || echo "$DEBUG_OUT_DIR exists"

    cp "apr$bitdir/Debug/apr-1.lib" "$DEBUG_OUT_DIR"
    cp "apr-iconv$bitdir/Debug/apriconv-1.lib" "$DEBUG_OUT_DIR"
    cp "apr-util$bitdir/Debug/aprutil-1.lib" "$DEBUG_OUT_DIR"

    for proj in apr aprutil apriconv
      do msbuild.exe $(cygpath -w 'apr-util/aprutil.sln') /t:"$proj" /p:Configuration=Release /p:Platform=$AUTOBUILD_WIN_VSPLATFORM
    done

    mkdir -p "$RELEASE_OUT_DIR" || echo "$RELEASE_OUT_DIR exists"

    cp "apr$bitdir/Release/apr-1.lib" "$RELEASE_OUT_DIR"
    cp "apr-iconv$bitdir/Release/apriconv-1.lib" "$RELEASE_OUT_DIR"
    cp "apr-util$bitdir/Release/aprutil-1.lib" "$RELEASE_OUT_DIR"

    INCLUDE_DIR="$STAGING_DIR/include/apr-1"
    mkdir -p "$INCLUDE_DIR"      || echo "$INCLUDE_DIR exists"
    cp apr/include/*.h "$INCLUDE_DIR"
    cp apr-iconv/include/*.h "$INCLUDE_DIR"
    cp apr-util/include/*.h "$INCLUDE_DIR"
    mkdir "$INCLUDE_DIR/arch"    || echo "$INCLUDE_DIR/arch exists"
    cp apr/include/arch/apr_private_common.h "$INCLUDE_DIR/arch"
    cp -R "apr/include/arch/win32" "$INCLUDE_DIR/arch"
    mkdir "$INCLUDE_DIR/private" || echo "$INCLUDE_DIR/private exists"
    cp -R apr-util/include/private "$INCLUDE_DIR"
    popd
  ;;

  darwin*)
    # Setup build flags
    C_OPTS_X86="-arch x86_64 $LL_BUILD_RELEASE_CFLAGS"
    C_OPTS_ARM64="-arch arm64 $LL_BUILD_RELEASE_CFLAGS"
    CXX_OPTS_X86="-arch x86_64 $LL_BUILD_RELEASE_CXXFLAGS"
    CXX_OPTS_ARM64="-arch arm64 $LL_BUILD_RELEASE_CXXFLAGS"
    LINK_OPTS_X86="-arch x86_64 $LL_BUILD_RELEASE_LINKER"
    LINK_OPTS_ARM64="-arch arm64 $LL_BUILD_RELEASE_LINKER"

    # deploy target
    export MACOSX_DEPLOYMENT_TARGET=${LL_BUILD_DARWIN_BASE_DEPLOY_TARGET}

    PREFIX="$STAGING_DIR"
    PREFIX_RELEASE_X86="$PREFIX/temp_release_x86"
    PREFIX_RELEASE_ARM64="$PREFIX/temp_release_arm64"

    mkdir -p $PREFIX_RELEASE_X86
    mkdir -p $PREFIX_RELEASE_ARM64

    pushd "$TOP_DIR/apr"
        autoreconf -fvi

        mkdir -p "build_release_x86"
        pushd "build_release_x86"
            CFLAGS="$C_OPTS_X86" CXXFLAGS="$CXX_OPTS_X86" LDFLAGS="$LINK_OPTS_X86" \
                ../configure --disable-shared --enable-static --prefix="$PREFIX_RELEASE_X86" --host=x86_64-apple-darwin
            make -j$AUTOBUILD_CPU_COUNT
            make install

            # conditionally run unit tests
            # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #     make check
            # fi
        popd



        mkdir -p "build_release_arm64"
        pushd "build_release_arm64"
            CFLAGS="$C_OPTS_ARM64" CXXFLAGS="$CXX_OPTS_ARM64" LDFLAGS="$LINK_OPTS_ARM64" \
                ../configure --disable-shared --enable-static --prefix="$PREFIX_RELEASE_ARM64" --host=aarch64-apple-darwin
            make -j$AUTOBUILD_CPU_COUNT
            make install

            # conditionally run unit tests
            # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #     make check
            # fi
        popd        
    popd

    # pushd "$PREFIX_RELEASE/lib"
    #     fix_dylib_id "libapr-1.dylib"
    #     dsymutil libapr-*.*.dylib
    #     strip -x -S libapr-*.*.dylib
    # popd

    pushd "$TOP_DIR/apr-util"
        autoreconf -fvi

        mkdir -p "build_release_x86"
        pushd "build_release_x86"
            cp -a $STAGING_DIR/packages/lib/release/*.a $STAGING_DIR/packages/lib

            CFLAGS="$C_OPTS_X86" CXXFLAGS="$CXX_OPTS_X86" LDFLAGS="$LINK_OPTS_X86" \
                ../configure --prefix="$PREFIX_RELEASE_X86" --with-apr="$PREFIX_RELEASE_X86" \
                --with-expat="$PREFIX/packages" --disable-shared --enable-static --host=x86_64-apple-darwin
            make -j$AUTOBUILD_CPU_COUNT
            make install

            # conditionally run unit tests
            # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #     export DYLD_LIBRARY_PATH="$STAGING_DIR/packages/lib"
            #     make check
            # fi

            rm $STAGING_DIR/packages/lib/*.a
        popd

        mkdir -p "build_release_arm64"
        pushd "build_release_arm64"
            cp -a $STAGING_DIR/packages/lib/release/*.a $STAGING_DIR/packages/lib

            CFLAGS="$C_OPTS_ARM64" CXXFLAGS="$CXX_OPTS_ARM64" LDFLAGS="$LINK_OPTS_ARM64" \
                ../configure --prefix="$PREFIX_RELEASE_ARM64" --with-apr="$PREFIX_RELEASE_ARM64" \
                --with-expat="$PREFIX/packages" --disable-shared --enable-static --host=aarch64-apple-darwin
            make -j$AUTOBUILD_CPU_COUNT
            make install

            # conditionally run unit tests
            # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #     export DYLD_LIBRARY_PATH="$STAGING_DIR/packages/lib"
            #     make check
            # fi

            rm $STAGING_DIR/packages/lib/*.a
        popd
    popd

    mkdir -p "$PREFIX/include"
    mkdir -p "$PREFIX/lib/release"

    # create fat libraries
    lipo -create ${STAGING_DIR}/temp_release_x86/lib/libapr-1.a ${STAGING_DIR}/temp_release_arm64/lib/libapr-1.a -output ${STAGING_DIR}/lib/release/libapr-1.a
    lipo -create ${STAGING_DIR}/temp_release_x86/lib/libaprutil-1.a ${STAGING_DIR}/temp_release_arm64/lib/libaprutil-1.a -output ${STAGING_DIR}/lib/release/libaprutil-1.a

    # copy headers
    mv $STAGING_DIR/temp_release_x86/include/* $STAGING_DIR/include/
  ;;

  linux*)
    # Linux build environment at Linden comes pre-polluted with stuff that can
    # seriously damage 3rd-party builds.  Environmental garbage you can expect
    # includes:
    #
    #    DISTCC_POTENTIAL_HOSTS     arch           root        CXXFLAGS
    #    DISTCC_LOCATION            top            branch      CC
    #    DISTCC_HOSTS               build_name     suffix      CXX
    #    LSDISTCC_ARGS              repo           prefix      CFLAGS
    #    cxx_version                AUTOBUILD      SIGN        CPPFLAGS
    #
    # So, clear out bits that shouldn't affect our configure-directed build
    # but which do nonetheless.
    #
    unset DISTCC_HOSTS CFLAGS CPPFLAGS CXXFLAGS

    # Default target per --address-size
    opts_c="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE_CFLAGS}"
    opts_cxx="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE_CXXFLAGS}"

    # Handle any deliberate platform targeting
    if [ -z "${TARGET_CPPFLAGS:-}" ]; then
        # Remove sysroot contamination from build environment
        unset CPPFLAGS
    else
        # Incorporate special pre-processing flags
        export CPPFLAGS="$TARGET_CPPFLAGS"
    fi

    PREFIX="$STAGING_DIR"
    PREFIX_RELEASE="$PREFIX/temp_release"

    mkdir -p $PREFIX_RELEASE

    pushd "$TOP_DIR/apr"
        autoreconf -fvi

        mkdir -p "build_release"
        pushd "build_release"
            CFLAGS="$opts_c" CXXFLAGS="$opts_cxx" \
                ../configure --disable-shared --enable-static --prefix="$PREFIX_RELEASE"
            make -j$AUTOBUILD_CPU_COUNT
            make install

            # conditionally run unit tests
            # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #     make check
            # fi
        popd
    popd

    pushd "$TOP_DIR/apr-util"
        autoreconf -fvi

        cp -a $STAGING_DIR/packages/include/expat/*.h $STAGING_DIR/packages/include/

        mkdir -p "build_release"
        pushd "build_release"
            cp -a $STAGING_DIR/packages/lib/release/*.a $STAGING_DIR/packages/lib

            CFLAGS="$opts_c -L$STAGING_DIR/packages/include" \
            CXXFLAGS="$opts_cxx -L$STAGING_DIR/packages/include" \
                ../configure --prefix="$PREFIX_RELEASE" --with-apr="$PREFIX_RELEASE" \
                --with-expat="$PREFIX/packages" --without-crypto --disable-shared --enable-static
            make -j$AUTOBUILD_CPU_COUNT
            make install

            # conditionally run unit tests
            # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            #     export LD_LIBRARY_PATH="$STAGING_DIR/packages/lib"
            #     make check
            # fi

            rm $STAGING_DIR/packages/lib/*.a
        popd
    popd

    mkdir -p "$PREFIX/include"
    mkdir -p "$PREFIX/lib/release"

    cp -a $PREFIX_RELEASE/lib/*.a $PREFIX/lib/release
    cp -a $PREFIX_RELEASE/include/* $PREFIX/include/
  ;;
esac

mkdir -p "$STAGING_DIR/LICENSES"
cat "$TOP_DIR/apr/LICENSE" > "$STAGING_DIR/LICENSES/apr_suite.txt"
