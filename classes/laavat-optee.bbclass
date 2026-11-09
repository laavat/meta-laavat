# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Laavat Oy
#
# Sign OP-TEE trusted applications with the service, and make the service's key the
# TEE core's TA trust anchor.
#
# Inherit from the optee-os recipe. Three tasks around the recipe's own build:
#
#   do_laavat_fetch_pubkey  before do_configure - the core compiles the key in
#   do_laavat_pack/_sign    after do_compile    - OP-TEESigning over every built .ta
#   do_laavat_unpack        before do_install   - signed .ta files replace the built ones
#
# The core embeds only the public half; TA_SIGN_KEY stays at optee-os's in-tree throwaway,
# because do_laavat_unpack replaces everything it signed at build time. do_install is
# untouched: it packages whichever .ta files are on disk.
#
#   LAAVAT_PUBKEY_SHA256  required - SHA-256 of the DER SubjectPublicKeyInfo to pin
#   LAAVAT_PRODUCT_ID, LAAVAT_OPER_ID, LAAVAT_API_URL, LAAVAT_TOKEN_FILE  as for signing

inherit laavat-sign

LAAVAT_SIGN_OPERATION ??= "OP-TEESigning"
LAAVAT_SIGN_DIR ??= "${WORKDIR}/laavat"
LAAVAT_SIGN_INPUT ??= "${LAAVAT_SIGN_DIR}/tas.tar.gz"
LAAVAT_SIGN_OUTPUT ??= "${LAAVAT_SIGN_DIR}/tas.tar.gz.laavat-signed"
LAAVAT_TA_PUBKEY ??= "${LAAVAT_SIGN_DIR}/ta-pub.pem"
LAAVAT_TA_GLOB ??= "${B}/ta/*/*.ta"

# Only the public half: the core verifies TAs, it never signs them.
EXTRA_OEMAKE:append = " TA_PUBLIC_KEY=${LAAVAT_TA_PUBKEY}"
# The PEM's bytes are in no task hash, so tie the core that embeds it to the pin instead.
do_compile[vardeps] += "LAAVAT_PUBKEY_SHA256"

# Fetching is the same staged CLI, env and network access as signing, minus the request.
do_laavat_fetch_pubkey[depends] += "signing-tool-native:do_populate_sysroot"
do_laavat_fetch_pubkey[network] = "1"
do_laavat_fetch_pubkey[vardepsexclude] += "LAAVAT_TOKEN_FILE"
# Runs first of the three, so it is the one that cleans the shared directory.
do_laavat_fetch_pubkey[cleandirs] = "${LAAVAT_SIGN_DIR}"

do_laavat_pack[depends] += "signing-tool-native:do_populate_sysroot"
do_laavat_unpack[depends] += "signing-tool-native:do_populate_sysroot"

do_laavat_fetch_pubkey() {
    if [ -n "${LAAVAT_SIGN_SKIP}" ]; then
        # EXTRA_OEMAKE points the core at LAAVAT_TA_PUBKEY unconditionally, so leaving the
        # file absent fails do_compile with "No rule to make target". Upstream defaults
        # TA_PUBLIC_KEY to TA_SIGN_KEY, so hand the core the in-tree key that really signs
        # the TAs: the build completes AND the TEE it produces is self-consistent. A
        # throwaway key here would build and then refuse every TA at runtime.
        bbwarn "LAAVAT_SIGN_SKIP is set: TAs stay anchored to optee-os's in-tree key, not the service's"
        [ -f "${S}/keys/default_ta.pem" ] || bbfatal "no ${S}/keys/default_ta.pem to anchor to"
        mkdir -p "${LAAVAT_SIGN_DIR}"
        cp "${S}/keys/default_ta.pem" "${LAAVAT_TA_PUBKEY}"
        exit 0
    fi
    laavat_fetch_pubkey "${LAAVAT_TA_PUBKEY}" "${LAAVAT_PUBKEY_SHA256}"
}

do_laavat_pack() {
    if [ -n "${LAAVAT_SIGN_SKIP}" ]; then
        bbwarn "LAAVAT_SIGN_SKIP is set: no trusted applications packed"
        exit 0
    fi
    set -- ${LAAVAT_TA_GLOB}
    [ -e "$1" ] || bbfatal "no ${LAAVAT_TA_GLOB}: do_compile built no trusted applications"
    mkdir -p "${LAAVAT_SIGN_DIR}"
    # Deterministic, so an unchanged set of TAs resumes its request instead of
    # resubmitting. pack refuses two TAs sharing a basename, which the archive
    # would otherwise flatten into one.
    signing-tool imagesigning pack -O "${LAAVAT_SIGN_INPUT}" "$@"
}

do_laavat_unpack() {
    if [ -n "${LAAVAT_SIGN_SKIP}" ]; then
        bbwarn "LAAVAT_SIGN_SKIP is set: no signed trusted applications installed"
        exit 0
    fi
    # The service re-signs each TA into <name>.signed and drops the original.
    # unpack bounds the archive, refuses anything
    # this build did not send, and stages every member before renaming any - so a rejected
    # or truncated member cannot leave the TA directory half-replaced.
    #
    # Every TA lives in its own directory under ${B}/ta, so each names its own
    # destination. All in one call, not one call per TA: membership is the
    # traversal check, so a second call would be refused for holding the first
    # TA's member.
    set --
    for laavat_ta in ${LAAVAT_TA_GLOB}; do
        set -- "$@" --member "$(basename $laavat_ta)=$laavat_ta"
    done
    [ $# -gt 0 ] || bbfatal "no ${LAAVAT_TA_GLOB}: nothing to install"
    signing-tool imagesigning unpack \
        -A "${LAAVAT_SIGN_OUTPUT}" \
        --strip-suffix .signed \
        --max-bytes "${LAAVAT_ARCHIVE_MAX_BYTES}" \
        "$@"
}

addtask laavat_fetch_pubkey after do_unpack before do_configure
addtask laavat_pack after do_compile before do_laavat_sign
addtask laavat_sign after do_laavat_pack before do_laavat_unpack
# Before do_install, which is unmodified: it packages whichever .ta files are on disk.
addtask laavat_unpack after do_laavat_sign before do_install
