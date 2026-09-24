#!/usr/bin/env bash
# Build patches/mister/mem_wc/prebuilt/mem_wc-<vermagic>.ko for a MiSTer kernel.
#
#   bash scripts/build_mem_wc.sh --host 192.168.20.81        # config from the device
#   bash scripts/build_mem_wc.sh --config path/to/config --release 6.18.38-MiSTer
#   [--ref <git ref>]   kernel commit/branch (default: MiSTer-v6.18)
#
# Everything runs in a throwaway debian:bookworm container at the host's native
# arch, so the kernel tree is checked out on a case-sensitive filesystem (a macOS
# checkout of Linux-Kernel_MiSTer silently drops the xt_CONNMARK/xt_connmark
# style case pairs). The compiler is the ARM GNU Toolchain 10.2-2020.11 -- the
# one the MiSTer kernel names in /proc/version -- in its aarch64- or x86_64-host
# build to match the container.
#
# The module only has to match the running kernel's vermagic and struct
# layouts: the MiSTer kernel has CONFIG_MODVERSIONS and CONFIG_MODULE_SIG off.
# modules_prepare does not produce Module.symvers, so modpost runs with
# KBUILD_MODPOST_WARN=1 and the script instead checks that every symbol the
# module imports has an EXPORT_SYMBOL* in the kernel source (6.18's
# /proc/kallsyms no longer lists __ksymtab_* entries, so the device cannot be
# asked directly). The decisive check is still an insmod on the device: an
# unexported import fails there with "Unknown symbol".
#
# The "-MiSTer" suffix is not in the kernel config (CONFIG_LOCALVERSION is
# empty); the MiSTer build passes it as LOCALVERSION. --release (or the
# device's `uname -r` under --host) supplies it, and the script fails unless
# the built module's vermagic starts with exactly that release.
set -euo pipefail
cd "$(dirname "$0")/.."

REF=MiSTer-v6.18
HOST=""
CONFIG=""
RELEASE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --ref) REF=$2; shift 2 ;;
        --host) HOST=$2; shift 2 ;;
        --config) CONFIG=$2; shift 2 ;;
        --release) RELEASE=$2; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done
[ -n "$HOST" ] || [ -n "$CONFIG" ] || { echo "need --host or --config" >&2; exit 2; }

WORK=build/mem_wc-kbuild
mkdir -p "$WORK"
if [ -n "$HOST" ]; then
    ssh "root@$HOST" 'zcat /proc/config.gz' > "$WORK/device.config"
    ssh "root@$HOST" 'cat /proc/version' > "$WORK/device.version"
    RELEASE=$(ssh "root@$HOST" 'uname -r')
else
    cp "$CONFIG" "$WORK/device.config"
fi
[ -n "$RELEASE" ] || { echo "need --release with --config" >&2; exit 2; }

docker run --rm --pull always -v "$PWD:/src" -w /src debian:bookworm bash -euc '
REF='"$REF"'
RELEASE='"$RELEASE"'
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    bc bison flex make gcc libc6-dev libssl-dev libelf-dev git ca-certificates \
    curl xz-utils kmod >/dev/null

case "$(uname -m)" in
    aarch64) TCH=aarch64 ;;
    x86_64)  TCH=x86_64 ;;
    *) echo "unsupported container arch $(uname -m)"; exit 1 ;;
esac
TC=gcc-arm-10.2-2020.11-$TCH-arm-none-linux-gnueabihf
cd /tmp
curl -sSL "https://developer.arm.com/-/media/Files/downloads/gnu-a/10.2-2020.11/binrel/$TC.tar.xz" | tar -xJ
CROSS=/tmp/$TC/bin/arm-none-linux-gnueabihf-

git init -q linux && cd linux
git remote add origin https://github.com/MiSTer-devel/Linux-Kernel_MiSTer.git
git fetch -q --depth 1 origin "$REF"
git checkout -q FETCH_HEAD
echo "kernel: $(git log -1 --format="%h %cs %s")"

cp /src/build/mem_wc-kbuild/device.config .config
make -s ARCH=arm CROSS_COMPILE=$CROSS olddefconfig
# olddefconfig must not have changed anything that reaches codegen.
diff <(grep "^CONFIG_" /src/build/mem_wc-kbuild/device.config | sort) \
     <(grep "^CONFIG_" .config | sort) > /tmp/cfgdiff || true
if [ -s /tmp/cfgdiff ]; then echo "config drift after olddefconfig:"; cat /tmp/cfgdiff; fi
KV=$(make -s ARCH=arm CROSS_COMPILE=$CROSS LOCALVERSION= kernelrelease)
case "$RELEASE" in
    "$KV"*) LV=${RELEASE#"$KV"} ;;
    *) echo "device release $RELEASE is not kernel $KV at $REF"; exit 1 ;;
esac
make -s ARCH=arm CROSS_COMPILE=$CROSS LOCALVERSION="$LV" modules_prepare
echo "kernelrelease: $(make -s ARCH=arm CROSS_COMPILE=$CROSS LOCALVERSION="$LV" kernelrelease)"

rm -rf /tmp/m && mkdir /tmp/m
cp /src/patches/mister/mem_wc/mem_wc.c /tmp/m/
echo "obj-m := mem_wc.o" > /tmp/m/Kbuild
make -s -C /tmp/linux M=/tmp/m ARCH=arm CROSS_COMPILE=$CROSS LOCALVERSION="$LV" KBUILD_MODPOST_WARN=1 modules 2>&1 \
    | grep -v "undefined!$" || true
test -f /tmp/m/mem_wc.ko
rel=$(modinfo -F vermagic /tmp/m/mem_wc.ko | cut -d" " -f1)
[ "$rel" = "$RELEASE" ] || { echo "vermagic release $rel != device $RELEASE"; exit 1; }
out=/src/patches/mister/mem_wc/prebuilt/mem_wc-$rel.ko
${CROSS}strip --strip-debug /tmp/m/mem_wc.ko -o "$out"
missing=0
for sym in $(${CROSS}nm -u "$out" | awk "{print \$2}"); do
    # param_ops_<type> is exported by STANDARD_PARAM_DEF(<type>, ...) in kernel/params.c.
    if ! git grep -qE "EXPORT_SYMBOL(_GPL)?\\($sym\\)" -- "*.c" "*.S" &&
       ! { case $sym in param_ops_*) grep -q "^STANDARD_PARAM_DEF(${sym#param_ops_}," kernel/params.c ;; *) false ;; esac; }; then
        echo "no EXPORT_SYMBOL for imported symbol: $sym"; missing=1
    fi
done
echo "vermagic: $(modinfo -F vermagic "$out")"
[ $missing -eq 0 ] || exit 1
echo "all imports exported; wrote $out"
'

