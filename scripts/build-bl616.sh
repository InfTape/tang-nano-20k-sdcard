#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sdk_dir="${BL_SDK_BASE:-${repo_dir}/.deps/bouffalo_sdk}"
toolchain_dir="${BL616_TOOLCHAIN:-${repo_dir}/.deps/toolchain_gcc_t-head_linux}"

export BL_SDK_BASE="${sdk_dir}"
export PATH="${toolchain_dir}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

msc_source="${sdk_dir}/components/usb/cherryusb/class/msc/usbd_msc.c"
msc_patch="${repo_dir}/patches/cherryusb-refresh-msc-capacity.patch"
if ! grep -q "Refresh backend geometry for removable or late-ready media" "${msc_source}"; then
    git -C "${sdk_dir}" apply --ignore-space-change --ignore-whitespace "${msc_patch}"
fi
msc_xfer_patch="${repo_dir}/patches/cherryusb-msc-16k-backend.patch"
msc_xfer_upgrade_patch="${repo_dir}/patches/cherryusb-msc-4k-to-16k.patch"
if grep -q "MSC_BACKEND_MAX_XFER 4096U" "${msc_source}"; then
    git -C "${sdk_dir}" apply --ignore-space-change --ignore-whitespace \
        "${msc_xfer_upgrade_patch}"
elif ! grep -q "MSC_BACKEND_MAX_XFER 16384U" "${msc_source}"; then
    git -C "${sdk_dir}" apply --ignore-space-change --ignore-whitespace "${msc_xfer_patch}"
fi

cd "${repo_dir}/bl616"
make -j"${BUILD_JOBS:-4}"
