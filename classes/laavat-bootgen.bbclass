# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Laavat Oy
#
# Sign a Xilinx boot image with SignBootgenImage.
#
# Inherit from the recipe that builds BOOT.bin - on meta-xilinx that is xilinx-bootbin,
# which provides virtual/boot-bin and already generates a BIF and stages every partition
# it names into ${B}.
#
# Despite appearing in the same list as SignSPSDK and MCUBoot, this is NOT a plain file
# upload. The service takes an archive holding a request.json, the .bif files it names and
# every partition those BIFs reference, runs bootgen against them with a key it holds, and
# returns a tar.gz of the produced .bin images. So the shape here is laavat-optee's -
# pack, sign, unpack - rather than laavat-ahab's.
#
#   LAAVAT_BOOTGEN_ARCH        bootgen -arch value (default: the recipe's BOOTGEN_ARCH)
#   LAAVAT_BOOTGEN_DIR         where the BIF and its partitions are (default: ${B})
#   LAAVAT_BOOTGEN_BIFS        BIF basenames, in order (default: bootgen.bif)
#   LAAVAT_BOOTGEN_OUTPUTS     the .bin each BIF produces, same order (default: BOOT.bin)
#
# Each output deploys as <its own name>.laavat-signed. It cannot be a single configurable
# name: a request may build several images, and one destination for all of them means the
# last one silently overwrites the rest.
#
# The request names each BIF and omits `items`, which is what tells the service to parse the
# BIF itself. That parser is the authoritative one - it also understands [fsbl_config] lines
# carrying settings like bh_auth_enable - so reproducing bootgen's semantics here would be a
# second implementation of one format, and the kind that fails silently. The only thing read
# out of the BIF on this side is which files to put in the archive.

inherit laavat-sign

LAAVAT_SIGN_OPERATION ??= "SignBootgenImage"
# The archive is uploaded as a plain file; only SignHAB has a request-aware payload mode.
LAAVAT_SIGN_PAYLOAD ??= "file"
LAAVAT_SIGN_DIR ??= "${WORKDIR}/laavat"
LAAVAT_SIGN_INPUT ??= "${LAAVAT_SIGN_DIR}/bootgen.tar.gz"
LAAVAT_SIGN_OUTPUT ??= "${LAAVAT_SIGN_DIR}/signed.tar.gz"

LAAVAT_BOOTGEN_ARCH ??= "${BOOTGEN_ARCH}"
LAAVAT_BOOTGEN_DIR ??= "${B}"
LAAVAT_BOOTGEN_BIFS ??= "bootgen.bif"
LAAVAT_BOOTGEN_OUTPUTS ??= "BOOT.bin"

do_laavat_pack[vardeps] += "LAAVAT_BOOTGEN_ARCH LAAVAT_BOOTGEN_BIFS LAAVAT_BOOTGEN_OUTPUTS"
# A rerun must not sign last run's archive or a stale request beside it.
do_laavat_pack[cleandirs] = "${LAAVAT_SIGN_DIR}"
do_laavat_pack[depends] += "signing-tool-native:do_populate_sysroot"
do_laavat_unpack[depends] += "signing-tool-native:do_populate_sysroot"

do_laavat_pack() {
    if [ -n "${LAAVAT_SIGN_SKIP}" ]; then
        bbwarn "LAAVAT_SIGN_SKIP is set: no bootgen archive packed"
        exit 0
    fi
    [ -n "${LAAVAT_BOOTGEN_ARCH}" ] || bbfatal "LAAVAT_BOOTGEN_ARCH must be set: the service needs a bootgen -arch value, e.g. zynqmp"
    mkdir -p "${LAAVAT_SIGN_DIR}"

    set --
    for laavat_bif in ${LAAVAT_BOOTGEN_BIFS}; do
        [ -f "${LAAVAT_BOOTGEN_DIR}/$laavat_bif" ] || bbfatal "${LAAVAT_BOOTGEN_DIR}/$laavat_bif does not exist; LAAVAT_BOOTGEN_DIR is ${LAAVAT_BOOTGEN_DIR} and the recipe generates the BIF there"
        set -- "$@" --bif "${LAAVAT_BOOTGEN_DIR}/$laavat_bif"
    done
    for laavat_out in ${LAAVAT_BOOTGEN_OUTPUTS}; do
        set -- "$@" --output "$laavat_out"
    done

    # The request names each BIF and omits `items`, which is what tells the service to
    # parse the BIF itself - that parser is the authoritative one, and it also understands
    # [fsbl_config] lines carrying settings like bh_auth_enable. pack reads the BIF only
    # to learn which partitions to carry, and refuses a count mismatch between BIFs and
    # outputs before anything is uploaded.
    signing-tool imagesigning pack -O "${LAAVAT_SIGN_INPUT}" \
        --arch "${LAAVAT_BOOTGEN_ARCH}" "$@"
}

do_laavat_unpack() {
    if [ -n "${LAAVAT_SIGN_SKIP}" ]; then
        bbwarn "LAAVAT_SIGN_SKIP is set: no signed boot images installed"
        exit 0
    fi
    set --
    for laavat_out in ${LAAVAT_BOOTGEN_OUTPUTS}; do
        set -- "$@" --member "$laavat_out"
    done
    [ $# -gt 0 ] || bbfatal "LAAVAT_BOOTGEN_OUTPUTS names nothing to install"
    signing-tool imagesigning unpack \
        -A "${LAAVAT_SIGN_OUTPUT}" -C "${LAAVAT_SIGN_DIR}" \
        --max-bytes "${LAAVAT_ARCHIVE_MAX_BYTES}" "$@"
}

addtask laavat_pack after do_configure before do_laavat_sign
addtask laavat_sign after do_laavat_pack before do_laavat_unpack
addtask laavat_unpack after do_laavat_sign before do_deploy

# Staged into DEPLOYDIR rather than written to DEPLOY_DIR_IMAGE, so the signed image
# travels inside do_deploy's sstate package instead of vanishing on a setscene hit.
do_deploy:append() {
    # A skipped do_laavat_unpack wrote nothing, so there is nothing to deploy.
    if [ -z "${LAAVAT_SIGN_SKIP}" ]; then
        for img in ${LAAVAT_BOOTGEN_OUTPUTS}; do
            install -m 0644 ${LAAVAT_SIGN_DIR}/$img \
                ${DEPLOYDIR}/$img.laavat-signed
        done
    fi
}
