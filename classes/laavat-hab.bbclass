# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Laavat Oy
#
# Sign a boot image with SignHAB in archive mode (hab-archive-v1).
#
# Inherit from the recipe that builds the boot binary. The pack task asks
# signing-tool to read the IVTs out of the binary that was just built and
# render request.json from them; the sign task uploads that request with the
# binaries it names and installs the patched member.
#
# The BSP layer usually supplies nothing but the deployed name:
#
#   LAAVAT_HAB_IMAGE         the built binary to sign. Optional: when unset, the single
#                            file under LAAVAT_HAB_SEARCH_DIR starting with a HAB IVT is
#                            used, and a machine that builds several fails with every name
#   LAAVAT_HAB_SEARCH_DIR    where to look for it (default: ${S})
#   LAAVAT_HAB_STAGES        boot stages in image order (default: SPL UBOOT)
#   LAAVAT_HAB_DEPLOY_NAME   deployed as <name>.laavat-signed (default: the member name)
#   LAAVAT_ARCHIVE_MEMBER    the binary's name inside the archive (default: flash.bin)
#
# LAAVAT_HAB_STAGES selects IVTs in file order, it does not merely count them. An i.MX8M
# flash.bin carries THREE, because imx-mkimage emits two overlapping descriptors for the
# u-boot FIT; only one of those can be signed, since the longer region contains the
# shorter one's CSF area. The default "SPL UBOOT" signs IVTs 0 and 1, and any IVT no
# stage claimed is warned about rather than dropped in silence.
#
# There is no request template any more. Rendering one needed bitbake to expand it, which
# is exactly the kind of work that no longer lives in this layer.
#
# A request the generic shape cannot express - a FIT stage also authenticating its
# sub-images, whose offsets come from `make print_fit_hab` - is written by hand. Inherit
# laavat-sign directly for that, with LAAVAT_SIGN_PAYLOAD = "hab-archive-v1" and
# LAAVAT_ARCHIVE_REQUEST naming the file: do_laavat_pack here always renders over
# LAAVAT_ARCHIVE_REQUEST, so inheriting this class would overwrite it.

inherit laavat-sign

LAAVAT_SIGN_PAYLOAD ??= "hab-archive-v1"
LAAVAT_SIGN_OPERATION ??= "SignHAB"
LAAVAT_SIGN_DIR ??= "${WORKDIR}/laavat"
LAAVAT_ARCHIVE_REQUEST ??= "${LAAVAT_SIGN_DIR}/request.json"
LAAVAT_ARCHIVE_MEMBER ??= "flash.bin"
LAAVAT_SIGN_OUTPUT ??= "${LAAVAT_SIGN_DIR}/${LAAVAT_ARCHIVE_MEMBER}.laavat-signed"
LAAVAT_HAB_STAGES ??= "SPL UBOOT"
LAAVAT_HAB_SEARCH_DIR ??= "${S}"
LAAVAT_HAB_DEPLOY_NAME ??= "${LAAVAT_ARCHIVE_MEMBER}"

do_laavat_pack[depends] += "signing-tool-native:do_populate_sysroot"
do_laavat_pack[vardeps] += "LAAVAT_HAB_STAGES LAAVAT_ARCHIVE_MEMBER"
# A rerun must not sign last run's binary or a stale request beside it.
do_laavat_pack[cleandirs] = "${LAAVAT_SIGN_DIR}"

do_laavat_pack() {
    if [ -n "${LAAVAT_SIGN_SKIP}" ]; then
        bbwarn "LAAVAT_SIGN_SKIP is set: no HAB request rendered"
        exit 0
    fi
    if [ -n "${LAAVAT_HAB_IMAGE}" ]; then
        set -- --image "${LAAVAT_HAB_IMAGE}"
    else
        set -- --search-dir "${LAAVAT_HAB_SEARCH_DIR}"
    fi

    # The tool reports an unclaimed IVT and an unsigned sibling image on stderr, and
    # both say an image is shipping unsigned. laavat_run is what puts them on the
    # console instead of only in ${T}/log.do_laavat_pack.
    laavat_run "rendering the HAB request" \
        signing-tool imagesigning hab-request "$@" \
        --stages ${LAAVAT_HAB_STAGES} \
        --member "${LAAVAT_ARCHIVE_MEMBER}" \
        -O "${LAAVAT_ARCHIVE_REQUEST}"
}

addtask laavat_pack after do_compile before do_laavat_sign
addtask laavat_sign after do_laavat_pack before do_deploy

# Staged into DEPLOYDIR rather than written to DEPLOY_DIR_IMAGE, so the signed image
# travels inside do_deploy's sstate package instead of vanishing on a setscene hit.
do_deploy:append() {
    # A skipped do_laavat_sign wrote nothing, so there is nothing to deploy.
    if [ -z "${LAAVAT_SIGN_SKIP}" ]; then
        # Non-empty by default here, unlike laavat-ahab - but an integrator who empties
        # LAAVAT_ARCHIVE_MEMBER would deploy a dotfile and never see the signed image.
        [ -n "${LAAVAT_HAB_DEPLOY_NAME}" ] || bbfatal "LAAVAT_HAB_DEPLOY_NAME is empty: name the boot image to deploy the signed copy as"
        install -m 0644 ${LAAVAT_SIGN_OUTPUT} \
            ${DEPLOYDIR}/${LAAVAT_HAB_DEPLOY_NAME}.laavat-signed
    fi
}
