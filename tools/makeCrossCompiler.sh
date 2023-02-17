#!/bin/bash
#cross-compiler script
prefix=/opt/cross
target=arm-unknown-linux-gnueabi
# target=arm-linux
root="$prefix/$target"
rm -vrf "$prefix" >/dev/null 2>&1
mkdir -pv "$root"
export PATH=/opt/cross/bin:$PATH

#check result
check(){
    if (($?!=0));then
        echo "$1 failed!"
        exit 1
    fi
}
#check tarball
check_tarball(){
    if ! ls "${1}"*tar* >/dev/null 2>&1;then
        echo "Not Found $1!"
        exit 1
    fi
}


check_tarball binutils
# check_tarball cloog
check_tarball glibc
check_tarball gmp
# check_tarball isl
check_tarball linux
check_tarball mpc
check_tarball mpfr

for t in *.tar*;do
    if [ ! -d "${t%\.tar\.*}" ];then
        echo "untar $t..."
        tar xf "$t"
    fi
done
#extend pattern matching
shopt -s extglob
pushd  gcc-+([0-9])+(\.+([0-9]))

ln -sfv ../mpfr-+([0-9])+(\.+([0-9])) mpfr
ln -sfv ../gmp-+([0-9])+(\.+([0-9])) gmp
ln -sfv ../mpc-+([0-9])+(\.+([0-9])) mpc
ln -sfv ../isl-+([0-9])+(\.+([0-9])) isl
ln -sfv ../cloog-+([0-9])+(\.+([0-9])) cloog
popd

rm -vrf build-* >/dev/null 2>&1

echo "build binutils..."
mkdir build-binutils && cd $_
../binutils-+([0-9])+(\.+([0-9]))/configure --prefix=$prefix --target=$target --disable-multilib
check "configure binutils"
make -j4
check "make binutils"
make install
check "install binutls"
cd ..

cd linux-+([0-9])+(\.+([0-9]))
pwd
echo "install linux headers..."
make ARCH=arm INSTALL_HDR_PATH=$root headers_install
check "install linux headers"
cd ..

mkdir -p build-gcc && cd $_
echo "build gcc..."
../gcc-+([0-9])+(\.+([0-9]))/configure --prefix=$prefix --target=$target --enable-languages=c,c++ --disable-multilib
check "configure gcc"
make -j4 all-gcc
check "make gcc"
make install-gcc
check "install gcc"
cd ..

echo "build glibc..."
mkdir -p build-glibc && cd $_
../glibc-+([0-9])+(\.+([0-9]))/configure --prefix=$root  --build=$MACHTYPE --host=$target --target=$target --with-headers="$root"/include --disable-multilib libc_cv_forced_unwind=yes
check "configure glibc"
make install-bootstrap-headers=yes install-headers
check "install glibc headers"
make -j4 csu/subdir_lib
check "make startupfiles"
install csu/crt1.o csu/crti.o csu/crtn.o "$root"/lib
$target-gcc -nostdlib -nostartfiles -shared -x c /dev/null -o "$root"/lib/libc.so
check "make libc.so"
touch "$root"/include/gnu/stubs.h
cd ..

echo "build support library..."
cd build-gcc
make -j4 all-target-libgcc
check "make support library"
make install-target-libgcc
cd ..

echo "build standard c library..."
cd build-glibc
make -j4
check "make standard c library"
make install
cd ..

echo "build standard c++ library..."
cd build-gcc
make -j4
check "make standard c++ library"
make install
cd ..
