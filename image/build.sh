#!/bin/bash
set -e

GCC_LIBSTDCXX_VERSION=8.3.0
ZLIB_VERSION=1.2.11
OPENSSL_VERSION=1.0.2q
CURL_VERSION=7.63.0
GIT_VERSION=2.25.1
SQLITE_VERSION=3260000
SQLITE_YEAR=2018
CENTOS_VERSION=$(tr -d 'a-zA-Z() \n' < /etc/centos-release)

source /hbb_build/functions.sh
source /hbb_build/activate_func.sh

SKIP_TOOLS=${SKIP_TOOLS:-false}
SKIP_LIBS=${SKIP_LIBS:-false}
SKIP_FINALIZE=${SKIP_FINALIZE:-false}
SKIP_USERS_GROUPS=${SKIP_USERS_GROUPS:-false}

SKIP_LIBSTDCXX=${SKIP_LIBSTDCXX:-$SKIP_LIBS}
SKIP_ZLIB=${SKIP_ZLIB:-$SKIP_LIBS}
SKIP_OPENSSL=${SKIP_OPENSSL:-$SKIP_LIBS}
SKIP_CURL=${SKIP_CURL:-$SKIP_LIBS}
SKIP_SQLITE=${SKIP_SQLITE:-$SKIP_LIBS}

MAKE_CONCURRENCY=2
VARIANTS='exe exe_gc_hardened shlib'
export PATH=/hbb/bin:$PATH

#########################

header "Initializing"
run mkdir -p /hbb /hbb/bin
run cp /hbb_build/libcheck /hbb/bin/
run cp /hbb_build/hardening-check /hbb/bin/
run cp /hbb_build/setuser /hbb/bin/
run cp /hbb_build/activate_func.sh /hbb/activate_func.sh
run cp /hbb_build/hbb-activate /hbb/activate
run cp /hbb_build/activate-exec /hbb/activate-exec

if ! eval_bool "$SKIP_USERS_GROUPS"; then
    run groupadd -g 9327 builder
    run adduser --uid 9327 --gid 9327 builder
fi

for VARIANT in $VARIANTS; do
	run mkdir -p /hbb_$VARIANT
	run cp /hbb_build/activate-exec /hbb_$VARIANT/
	run cp /hbb_build/variants/$VARIANT.sh /hbb_$VARIANT/activate
done

header "Updating system"
if [ $(date --date '2020-11-30T00:00:00' +'%s') -lt $(date +'%s') ]; then
run sed -i.bak -re 's/^(mirrorlist)/#\1/g' -e 's/^#(baseurl)/\1/g' -e 's/mirror(\.centos)/vault\1/g' -e 's|centos/\$releasever/([^/]+)/([^/]+)|'$CENTOS_VERSION'/\1/\2|g' /etc/yum.repos.d/CentOS-Base.repo
rm /etc/yum.repos.d/CentOS-Base.repo.bak
if [[ -f /etc/yum.repos.d/libselinux.repo ]]; then
	run sed -i.bak -re 's/^(mirrorlist)/#\1/g' -e 's/^#(baseurl)/\1/g' -e 's/mirror(\.centos)/vault\1/g' -e 's|centos/\$releasever/([^/]+)/([^/]+)|'$CENTOS_VERSION'/\1/\2|g' /etc/yum.repos.d/libselinux.repo
	rm /etc/yum.repos.d/libselinux.repo.bak
fi
fi
touch /var/lib/rpm/*
run yum update -y
run yum install -y curl epel-release tar

header "Installing compiler toolchain"
if [ `uname -m` != aarch64 -a `uname -m` != x86_64 ]; then
curl -s https://packagecloud.io/install/repositories/phusion/centos-6-scl-i386/script.rpm.sh | bash
sed -i 's|$arch|i686|; s|\$basearch|i386|g' $CHROOT/etc/yum.repos.d/phusion*.repo
DEVTOOLSET_VER=7
# a 32-bit version of devtoolset-8 would need to get compiled
GCC_LIBSTDCXX_VERSION=7.3.0
else
run yum install -y centos-release-scl
DEVTOOLSET_VER=8
fi
run yum install -y devtoolset-${DEVTOOLSET_VER} \
                   file \
                   patch \
                   bzip2 \
                   zlib-devel \
                   gettext \
                   m4 \
                   autoconf \
                   automake \
                   libtool \
                   pkgconfig \
                   ccache \
                   cmake \
                   git \
                   python \
                   curl \
                   openssl

## libstdc++

function install_libstdcxx()
{
	local VARIANT="$1"
	local PREFIX="/hbb_$VARIANT"

	header "Installing libstdc++ static libraries: $VARIANT"
	download_and_extract gcc-$GCC_LIBSTDCXX_VERSION.tar.gz \
		gcc-$GCC_LIBSTDCXX_VERSION \
		https://ftpmirror.gnu.org/gcc/gcc-$GCC_LIBSTDCXX_VERSION/gcc-$GCC_LIBSTDCXX_VERSION.tar.gz

	(
		source "$PREFIX/activate"
		run rm -rf ../gcc-build
		run mkdir ../gcc-build
		echo "+ Entering /gcc-build"
		cd ../gcc-build
		echo -n "+ Choosing thread header..."
		target_thread_file=`cc -v 2>&1 | sed -n 's/^Thread model: //p'`
		case $target_thread_file in
		    aix)
			thread_header=config/rs6000/gthr-aix.h
			;;
		    dce)
			thread_header=config/pa/gthr-dce.h
			;;
		    lynx)
			thread_header=config/gthr-lynx.h
			;;
		    mipssde)
			thread_header=config/mips/gthr-mipssde.h
			;;
		    posix)
			thread_header=gthr-posix.h
			;;
		    rtems)
			thread_header=config/gthr-rtems.h
			;;
		    single)
			thread_header=gthr-single.h
			;;
		    tpf)
			thread_header=config/s390/gthr-tpf.h
			;;
		    vxworks)
			thread_header=config/gthr-vxworks.h
			;;
		    win32)
			thread_header=config/i386/gthr-win32.h
			;;
		esac
		echo $thread_header
		export CFLAGS="$STATICLIB_CFLAGS"
		export CXXFLAGS="$STATICLIB_CXXFLAGS"
		sed -i "s/gthr.h/$thread_header/" \
			../gcc-$GCC_LIBSTDCXX_VERSION/libstdc++-v3/configure
		../gcc-$GCC_LIBSTDCXX_VERSION/libstdc++-v3/configure \
			--prefix=$PREFIX --disable-multilib \
			--disable-libstdcxx-visibility --disable-shared
		run make -j$MAKE_CONCURRENCY
		run mkdir -p $PREFIX/lib
		run cp src/.libs/libstdc++.a $PREFIX/lib/
		run cp libsupc++/.libs/libsupc++.a $PREFIX/lib/
	)
	if [[ "$?" != 0 ]]; then false; fi

	echo "Leaving source directory"
	popd >/dev/null
	run rm -rf gcc-$GCC_LIBSTDCXX_VERSION
	run rm -rf gcc-build
}

if ! eval_bool "$SKIP_LIBSTDCXX"; then
	for VARIANT in $VARIANTS; do
		install_libstdcxx $VARIANT
	done
fi


### zlib

function install_zlib()
{
	local VARIANT="$1"
	local PREFIX="/hbb_$VARIANT"

	header "Installing zlib $ZLIB_VERSION static libraries: $VARIANT"
	download_and_extract zlib-$ZLIB_VERSION.tar.gz \
		zlib-$ZLIB_VERSION \
		https://zlib.net/fossils/zlib-$ZLIB_VERSION.tar.gz

	(
		source "$PREFIX/activate"
		export CFLAGS="$STATICLIB_CFLAGS"
		run ./configure --prefix=$PREFIX --static
		run make -j$MAKE_CONCURRENCY
		run make install
	)
	if [[ "$?" != 0 ]]; then false; fi

	echo "Leaving source directory"
	popd >/dev/null
	run rm -rf zlib-$ZLIB_VERSION
}

if ! eval_bool "$SKIP_ZLIB"; then
	for VARIANT in $VARIANTS; do
		install_zlib $VARIANT
	done
fi


### OpenSSL

function install_openssl()
{
	local VARIANT="$1"
	local PREFIX="/hbb_$VARIANT"

	header "Installing OpenSSL $OPENSSL_VERSION static libraries: $PREFIX"
	download_and_extract openssl-$OPENSSL_VERSION.tar.gz \
		openssl-$OPENSSL_VERSION \
		https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz

	(
		source "$PREFIX/activate"

		# OpenSSL already passes optimization flags regardless of CFLAGS
		export CFLAGS=`echo "$STATICLIB_CFLAGS" | sed 's/-O2//'`
		run ./config --prefix=$PREFIX --openssldir=$PREFIX/openssl \
			threads zlib no-shared no-sse2 $CFLAGS $LDFLAGS

		if ! $O3_ALLOWED; then
			echo "+ Modifying Makefiles"
			find . -name Makefile | xargs sed -i -e 's|-O3|-O2|g'
		fi

		run make
		run make install_sw
		run strip --strip-all "$PREFIX/bin/openssl"
		if [[ "$VARIANT" = exe_gc_hardened ]]; then
			run hardening-check -b "$PREFIX/bin/openssl"
		fi
		run sed -i 's/^Libs:.*/Libs: -L${libdir} -lssl -lcrypto -ldl/' $PREFIX/lib/pkgconfig/openssl.pc
		run sed -i 's/^Libs.private:.*/Libs.private: -L${libdir} -lssl -lcrypto -ldl -lz/' $PREFIX/lib/pkgconfig/openssl.pc
		run sed -i 's/^Libs:.*/Libs: -L${libdir} -lssl -lcrypto -ldl/' $PREFIX/lib/pkgconfig/libssl.pc
		run sed -i 's/^Libs.private:.*/Libs.private: -L${libdir} -lssl -lcrypto -ldl -lz/' $PREFIX/lib/pkgconfig/libssl.pc
	)
	if [[ "$?" != 0 ]]; then false; fi

	echo "Leaving source directory"
	popd >/dev/null
	run rm -rf openssl-$OPENSSL_VERSION
}

if ! eval_bool "$SKIP_OPENSSL"; then
	for VARIANT in $VARIANTS; do
		install_openssl $VARIANT
	done
	run mv /hbb_exe_gc_hardened/bin/openssl /hbb/bin/
	for VARIANT in $VARIANTS; do
		run rm -f /hbb_$VARIANT/bin/openssl
	done
fi


### libcurl

function install_curl()
{
	local VARIANT="$1"
	local PREFIX="/hbb_$VARIANT"

	header "Installing Curl $CURL_VERSION static libraries: $PREFIX"
	download_and_extract curl-$CURL_VERSION.tar.bz2 \
		curl-$CURL_VERSION \
		https://curl.haxx.se/download/curl-$CURL_VERSION.tar.bz2

	(
		source "$PREFIX/activate"
		export CFLAGS="$STATICLIB_CFLAGS"
		./configure --prefix="$PREFIX" --disable-shared --disable-debug --enable-optimize --disable-werror \
			--disable-curldebug --enable-symbol-hiding --disable-ares --disable-manual --disable-ldap --disable-ldaps \
			--disable-rtsp --disable-dict --disable-ftp --disable-ftps --disable-gopher --disable-imap \
			--disable-imaps --disable-pop3 --disable-pop3s --without-librtmp --disable-smtp --disable-smtps \
			--disable-telnet --disable-tftp --disable-smb --disable-versioned-symbols \
			--without-libmetalink --without-libidn --without-libssh2 --without-libmetalink --without-nghttp2 \
			--with-ssl
		run make -j$MAKE_CONCURRENCY
		run make install
		if [[ "$VARIANT" = exe_gc_hardened ]]; then
			run hardening-check -b "$PREFIX/bin/curl"
		fi
		run rm -f "$PREFIX/bin/curl"
	)
	if [[ "$?" != 0 ]]; then false; fi

	echo "Leaving source directory"
	popd >/dev/null
	run rm -rf curl-$CURL_VERSION
}

if ! eval_bool "$SKIP_CURL"; then
	for VARIANT in $VARIANTS; do
		install_curl $VARIANT
	done
fi


### SQLite

function install_sqlite()
{
	local VARIANT="$1"
	local PREFIX="/hbb_$VARIANT"

	header "Installing SQLite $SQLITE_VERSION static libraries: $PREFIX"
	download_and_extract sqlite-autoconf-$SQLITE_VERSION.tar.gz \
		sqlite-autoconf-$SQLITE_VERSION \
		https://www.sqlite.org/$SQLITE_YEAR/sqlite-autoconf-$SQLITE_VERSION.tar.gz

	(
		source "$PREFIX/activate"
		export CFLAGS="$STATICLIB_CFLAGS"
		export CXXFLAGS="$STATICLIB_CXXFLAGS"
		run ./configure --prefix="$PREFIX" --enable-static \
			--disable-shared --disable-dynamic-extensions
		run make -j$MAKE_CONCURRENCY
		run make install
		if [[ "$VARIANT" = exe_gc_hardened ]]; then
			run hardening-check -b "$PREFIX/bin/sqlite3"
		fi
		run strip --strip-all "$PREFIX/bin/sqlite3"
	)
	if [[ "$?" != 0 ]]; then false; fi

	echo "Leaving source directory"
	popd >/dev/null
	run rm -rf sqlite-autoconf-$SQLITE_VERSION
}

if ! eval_bool "$SKIP_SQLITE"; then
	for VARIANT in $VARIANTS; do
		install_sqlite $VARIANT
	done
	run mv /hbb_exe_gc_hardened/bin/sqlite3 /hbb/bin/
	for VARIANT in $VARIANTS; do
		run rm -f /hbb_$VARIANT/bin/sqlite3
	done
fi


### Finalizing

if ! eval_bool "$SKIP_FINALIZE"; then
	header "Finalizing"
	run yum clean -y all
	run rm -rf /hbb/share/doc /hbb/share/man
	run rm -rf /hbb_build /tmp/*
	for VARIANT in $VARIANTS; do
		run rm -rf /hbb_$VARIANT/share/doc /hbb_$VARIANT/share/man
	done
fi
