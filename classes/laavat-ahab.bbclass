# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Laavat Oy
#
# Sign an AHAB boot image with SignSPSDK.
#
# AHAB is the boot ROM signature check on i.MX93 and later, replacing HABv4. It is a
# different format with different tooling - containers signed through SPSDK, not IVTs and
# CSFs signed through CST - so nothing in laavat-hab or signingtool.imx_ivt applies. What it
# shares with every other target is the shape: upload one file, get one signed file back.
#
# That makes this class thin on purpose. It is laavat-sign with the operation, the stored
# encoding and the deploy step filled in, so a recipe needs the inherit and a path:
#
#   LAAVAT_AHAB_IMAGE        the built boot image to sign. Required.
#   LAAVAT_AHAB_DEPLOY_NAME  deployed as <name>.laavat-signed (default: UUU_BOOTLOADER)
#
# Why LAAVAT_AHAB_IMAGE is required rather than auto-detected, as laavat-hab's is: an i.MX
# BSP routinely builds several boot images from one recipe, and imx93evk is no exception -
# IMXBOOT_TARGETS is "flash_singleboot flash_singleboot_gdet flash_singleboot_gdet_auto",
# so imx-boot writes three. Only the integrator knows which one ships. laavat-hab can offer
# a default because it can recognise a HABv4 IVT by its header; recognising an AHAB
# container is not implemented here, and guessing wrong would sign the wrong artifact.
#
# The stored encoding used to be a variable here. It is not any more: signing-tool
# installs whichever form the reported digest matched, so nothing has to declare an
# encoding it cannot see.

inherit laavat-sign

LAAVAT_SIGN_OPERATION ??= "SignSPSDK"
LAAVAT_SIGN_DIR ??= "${WORKDIR}/laavat"
LAAVAT_SIGN_INPUT ??= "${LAAVAT_AHAB_IMAGE}"
LAAVAT_SIGN_OUTPUT ??= "${LAAVAT_SIGN_DIR}/flash.bin.laavat-signed"
LAAVAT_AHAB_DEPLOY_NAME ??= "${UUU_BOOTLOADER}"

# LAAVAT_AHAB_IMAGE unset leaves LAAVAT_SIGN_INPUT empty, which laavat-sign already
# reports as a missing required variable, so there is no second check here.

addtask laavat_sign after do_compile before do_deploy

# Staged into DEPLOYDIR rather than written to DEPLOY_DIR_IMAGE, so the signed image
# travels inside do_deploy's sstate package instead of vanishing on a setscene hit.
do_deploy:append() {
    # A skipped do_laavat_sign wrote nothing, so there is nothing to deploy.
    if [ -z "${LAAVAT_SIGN_SKIP}" ]; then
        # The default is UUU_BOOTLOADER, which only meta-freescale's own machines set.
        # Empty would install the signed image as ".laavat-signed" - a dotfile, deployed
        # successfully, invisible beside the unsigned original that nothing replaced.
        [ -n "${LAAVAT_AHAB_DEPLOY_NAME}" ] || bbfatal "LAAVAT_AHAB_DEPLOY_NAME is empty: this machine does not set UUU_BOOTLOADER, so name the boot image to deploy the signed copy as"
        install -m 0644 ${LAAVAT_SIGN_OUTPUT} \
            ${DEPLOYDIR}/${LAAVAT_AHAB_DEPLOY_NAME}.laavat-signed
    fi
}
