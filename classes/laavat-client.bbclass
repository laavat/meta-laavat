# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Laavat Oy
#
# How this layer talks to signing-tool. Inherited by laavat-sign, so every consumer
# gets it; not useful on its own.
#
# Two things every signing task needs, and neither bitbake nor the client provides:
#
#   the client's warnings have to reach the console. A shell task's stderr goes to
#   ${T}/log.do_<task> and nowhere else, and the warnings sign.py prints all say the
#   same thing - an artifact is being installed without its input having been
#   confirmed. Nobody greps a build log for that, so laavat_run lifts them.
#
#   the client has to be new enough. This layer calls verbs 3.9.1 does not have, and
#   argparse's "invalid choice" would otherwise arrive inside a network task, after
#   the whole BSP has built - and, for a four-eyes operation, possibly after an
#   approval has already been spent.

LAAVAT_CLIENT_MIN_VERSION ??= "3.9.2"

laavat_fetch_pubkey[vardepsexclude] += "LAAVAT_TOKEN_FILE"

# Run the client and lift what it says. $1 names the step for the failure message,
# the rest is the command.
laavat_run() {
    laavat_what="$1"
    shift
    # Captured, not piped: a pipeline's status is its last command's, so reading the
    # output directly from a pipe would throw the client's exit code away.
    laavat_out=$("$@" 2>&1) || {
        echo "$laavat_out" >&2
        bbfatal "$laavat_what failed"
    }
    echo "$laavat_out" | while IFS= read -r laavat_line; do
        case "$laavat_line" in
            WARNING:*) bbwarn "${laavat_line#WARNING: }" ;;
            NOTE:*)    bbnote "${laavat_line#NOTE: }" ;;
            *)         [ -z "$laavat_line" ] || echo "$laavat_line" ;;
        esac
    done
}

# Asked of the client rather than read from --version: a locally built or patched
# client reports whatever its version file says, and what matters is whether the
# subcommand this layer is about to call exists.
laavat_require_client() {
    signing-tool imagesigning sign --help >/dev/null 2>&1 \
        || bbfatal "the signing-tool on PATH is too old for this layer: 'imagesigning sign' does not exist. meta-laavat needs >= ${LAAVAT_CLIENT_MIN_VERSION}; 3.9.1 and earlier offer only add, approve, get, getall and getapprovals."
}

# Fetch an operation's public key, pinned. Two integrations need it rather than
# a per-artifact call: OP-TEE's TA trust anchor, and FIT verified boot, whose
# public half sits in U-Boot's control DTB. The private half never leaves the
# service in either case.
#
# The pin is required. This key is the root of trust for everything the product
# will ever load, so a rotated key must break the build rather than silently
# become the anchor. Take it once by hand:
#   signing-tool -c -a "$URL" -t "@$TOKENFILE" \
#       product getpubkey -P <product> --operid <oper> -O key.pem
laavat_fetch_pubkey() {
    [ -n "$1" ] || bbfatal "laavat_fetch_pubkey needs an output path"
    [ -n "$2" ] || bbfatal "the public key must be pinned by SHA-256 of its DER SubjectPublicKeyInfo, so a rotated key breaks the build instead of becoming the new anchor unnoticed"
    [ -n "${LAAVAT_API_URL}" ] || bbfatal "LAAVAT_API_URL must be set to fetch a public key"
    [ -n "${LAAVAT_PRODUCT_ID}" ] || bbfatal "LAAVAT_PRODUCT_ID must be set to fetch a public key"
    [ -n "${LAAVAT_OPER_ID}" ] || bbfatal "LAAVAT_OPER_ID must be set to fetch a public key"
    [ -r "${LAAVAT_TOKEN_FILE}" ] || bbfatal "LAAVAT_TOKEN_FILE must point at a readable token file"
    export OPENSSL_MODULES="${STAGING_LIBDIR_NATIVE}/ossl-modules"
    mkdir -p "$(dirname $1)"
    rm -f "$1"
    laavat_run "fetching the public key" \
        signing-tool -c -a "${LAAVAT_API_URL}" -t "@${LAAVAT_TOKEN_FILE}" \
        product getpubkey -P "${LAAVAT_PRODUCT_ID}" --operid "${LAAVAT_OPER_ID}" \
        -O "$1" --fingerprint "$2"
    # A silent success that wrote nothing would surface much later as a missing file.
    [ -s "$1" ] || bbfatal "the public key was not written to $1"
}
