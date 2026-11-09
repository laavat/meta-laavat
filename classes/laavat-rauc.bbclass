# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Laavat Oy
#
# Re-sign a finished RAUC bundle with the service.
#
# Inherit from a recipe that inherits `bundle`. RAUC's own `rauc resign` shape: do_bundle
# signs locally with whatever RAUC_KEY_FILE names, then RaucBundleSigningWithOneTimeKey
# re-signs the finished .raucb - rather than pushing a PKCS#11 URI through do_bundle.
#
# The operation mints a per-bundle certificate, so the device trusts the issuing CA rather
# than any one key. Installing that CA as the device keyring is the other half:
# laavat-rauc-keyring.bbclass, inherited from the rauc recipe.
#
#   LAAVAT_PRODUCT_ID, LAAVAT_OPER_ID, LAAVAT_API_URL, LAAVAT_TOKEN_FILE  as for signing

inherit laavat-sign

LAAVAT_SIGN_OPERATION ??= "RaucBundleSigningWithOneTimeKey"
LAAVAT_SIGN_DIR ??= "${WORKDIR}/laavat"
# The operation takes a tar.gz of request.json + the bundle (a "resign" request), not
# a bare .raucb, so the pack task builds that and the class signs the archive as a file.
LAAVAT_SIGN_INPUT ??= "${LAAVAT_SIGN_DIR}/resign.tar.gz"
LAAVAT_SIGN_OUTPUT ??= "${LAAVAT_SIGN_DIR}/bundle.raucb.laavat-signed"
LAAVAT_RAUC_BUNDLE ??= "${B}/bundle.raucb"

# Beside ${B}, not in it: do_bundle[cleandirs] wipes ${B} on every rebuild. Cleaned by the
# packing task, which runs first - on do_laavat_sign it would delete its own input.
do_laavat_pack[cleandirs] = "${LAAVAT_SIGN_DIR}"
do_laavat_pack[vardeps] += "RAUC_BUNDLE_FORMAT"

python __anonymous() {
    # Without `bundle` there is no do_bundle to hang the pack task on, and the addtask
    # below fails with a dependency error that names no cause.
    if not bb.data.inherits_class("bundle", d):
        bb.fatal("laavat-rauc must be inherited from a recipe that inherits `bundle`: "
                 "it re-signs what do_bundle built")
}

do_laavat_pack[depends] += "signing-tool-native:do_populate_sysroot"

do_laavat_pack() {
    if [ -n "${LAAVAT_SIGN_SKIP}" ]; then
        bbwarn "LAAVAT_SIGN_SKIP is set: no RAUC resign request packed"
        exit 0
    fi
    [ -f "${LAAVAT_RAUC_BUNDLE}" ] || bbfatal "${LAAVAT_RAUC_BUNDLE} is missing: do_bundle built no bundle"
    [ -n "${RAUC_BUNDLE_FORMAT}" ] || bbfatal "RAUC_BUNDLE_FORMAT is unset: the request's format must match the bundle"
    mkdir -p "${LAAVAT_SIGN_DIR}"
    # format must match the bundle's own manifest, so it is read off the recipe.
    printf '{"format": "%s", "resign": true, "inputFile": "bundle.raucb"}\n' \
        "${RAUC_BUNDLE_FORMAT}" > "${LAAVAT_SIGN_DIR}/request.json"
    cp "${LAAVAT_RAUC_BUNDLE}" "${LAAVAT_SIGN_DIR}/bundle.raucb"
    # Deterministic, so an unchanged bundle resumes its request instead of resubmitting.
    signing-tool imagesigning pack -O "${LAAVAT_SIGN_INPUT}" \
        "${LAAVAT_SIGN_DIR}/request.json" "${LAAVAT_SIGN_DIR}/bundle.raucb"
}

addtask laavat_pack after do_bundle before do_laavat_sign
addtask laavat_sign after do_laavat_pack before do_deploy

# bundle.bbclass sets SSTATE_SKIP_CREATION:task-deploy, so unlike the imx-boot and kernel
# wirings there is no do_deploy_setscene here that could cover the signing.
do_deploy:append() {
    # A skipped do_laavat_sign wrote nothing, so there is nothing to deploy.
    if [ -z "${LAAVAT_SIGN_SKIP}" ]; then
        install -m 0644 ${LAAVAT_SIGN_OUTPUT} \
            ${DEPLOYDIR}/${BUNDLE_LINK_NAME}${BUNDLE_EXTENSION}.laavat-signed
    fi
}
