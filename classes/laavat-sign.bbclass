# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Laavat Oy
#
# Sign a build artifact with the LAAVAT Signing Solution.
#
# Requires signing-tool >= 3.9.2, which owns the whole round trip: submitting
# or resuming a request, waiting for the service to accept it before approving,
# waiting for the result, verifying both digests and installing the artifact.
# None of that is Yocto's business, so none of it is here any more.
#
# The token never enters bitbake: LAAVAT_TOKEN_FILE holds a *path*, which is
# passed to the CLI as '-t @<path>'. Never put a token in a variable - a shell
# task's body is written to ${T}/run.do_laavat_sign.<pid> with every variable
# expanded, so a token in a variable is a token on disk.
#
# Deliberate tradeoff: this signs live over the network from inside the build,
# because a request can sit waiting for a human approver. It is a plain
# addtask - not in SSTATETASKS, no setscene variant - so the task is never
# itself sstate-restored. It is still stamped, so an unchanged task hash does
# not spend a second approval. Ordering it before a task that IS sstate-backed
# is a separate question: see "Troubleshooting" in docs/INTEGRATION.md.

inherit laavat-client

LAAVAT_SIGN_NAME ??= "${PN}-${PV}"
LAAVAT_SIGN_DESC ??= "${PN} ${PV} ${LAAVAT_SIGN_OPERATION} for ${MACHINE}"
LAAVAT_SIGN_TIMEOUT ??= "1800"

# Extra request metadata, shown to whoever approves the request alongside the
# recipe/version/machine the task fills in. Space-separated name=value pairs,
# so a value cannot contain a space:
#   LAAVAT_SIGN_METADATA_EXTRA = "ci_job=${CI_JOB_URL} commit=${CI_COMMIT_SHA}"
# Use :append to add to it rather than replacing a site-wide setting.
LAAVAT_SIGN_METADATA_EXTRA ??= ""
LAAVAT_SIGN_REQUIRE_DIGEST ??= "1"

# Whether a recipe signs one plain file or an archived SignHAB request.
# LAAVAT_ARCHIVE_MAX_BYTES bounds the result archive it unpacks.
LAAVAT_SIGN_PAYLOAD ??= "file"
LAAVAT_ARCHIVE_MAX_BYTES ??= "2147483648"

# Parse and build without credentials. The signing tasks then do nothing and
# say so, which is what lets a layer consumer evaluate this without an account
# and what keeps a -world build honest.
LAAVAT_SIGN_SKIP ??= ""

# Resume state must outlive WORKDIR: under rm_work a pending request would be
# forgotten and resubmitted rather than resumed, which for a four-eyes
# approval means the approved request is abandoned.
LAAVAT_STATE_DIR ??= "${TMPDIR}/laavat-sign"

# Staging the native tool for a standalone `-c laavat_sign` needs a
# task-level dependency: DEPENDS only feeds do_prepare_recipe_sysroot, which
# a bare addtask run never executes.
do_laavat_sign[depends] += "signing-tool-native:do_populate_sysroot"
do_laavat_sign[network] = "1"
# bitbake writes a shell task's body with every variable expanded, so the token PATH would
# otherwise reach the task hash and moving the token file would spend a fresh approval on an
# artifact that has not changed.
#
# The exclusion has to name the function whose body carries the reference, not just the task:
# bb.data.build_dependencies subtracts vardepsexclude from a key's DIRECT references only, and
# generate_dependency_hash then unions in gendeps[dep] for every called function with no
# exclusion applied. do_laavat_sign reaches LAAVAT_TOKEN_FILE through laavat_sign_common, so
# the task-level flag alone left it in the signature.
do_laavat_sign[vardepsexclude] += "LAAVAT_TOKEN_FILE LAAVAT_APPROVER_TOKEN_FILE LAAVAT_SIGN_METADATA_EXTRA"
laavat_sign_common[vardepsexclude] += "LAAVAT_TOKEN_FILE"

laavat_sign_common() {
    if [ -n "${LAAVAT_SIGN_SKIP}" ]; then
        bbwarn "LAAVAT_SIGN_SKIP is set: ${LAAVAT_SIGN_OUTPUT} will NOT be signed"
        exit 0
    fi
    [ -n "${LAAVAT_API_URL}" ] || bbfatal "LAAVAT_API_URL must be set to use laavat-sign"
    [ -n "${LAAVAT_PRODUCT_ID}" ] || bbfatal "LAAVAT_PRODUCT_ID must be set to use laavat-sign"
    [ -n "${LAAVAT_OPER_ID}" ] || bbfatal "LAAVAT_OPER_ID must be set to use laavat-sign"
    [ -n "${LAAVAT_SIGN_OPERATION}" ] || bbfatal "LAAVAT_SIGN_OPERATION must be set to use laavat-sign"
    [ -n "${LAAVAT_SIGN_OUTPUT}" ] || bbfatal "LAAVAT_SIGN_OUTPUT must be set to use laavat-sign"
    [ -r "${LAAVAT_TOKEN_FILE}" ] || bbfatal "LAAVAT_TOKEN_FILE must point at a readable token file; add it to BB_ENV_PASSTHROUGH_ADDITIONS"
    laavat_require_client
    mkdir -p "${LAAVAT_STATE_DIR}" "$(dirname ${LAAVAT_SIGN_OUTPUT})"
}

do_laavat_sign() {
    laavat_sign_common

    # The client's python3-cryptography aborts on import unless OpenSSL 3 can
    # find its legacy provider, which no task environment points at.
    export OPENSSL_MODULES="${STAGING_LIBDIR_NATIVE}/ossl-modules"

    if [ "${LAAVAT_SIGN_PAYLOAD}" = "hab-archive-v1" ]; then
        [ -n "${LAAVAT_ARCHIVE_REQUEST}" ] || bbfatal "LAAVAT_ARCHIVE_REQUEST must point at a rendered request.json to use hab-archive-v1"
        set -- --payload hab-archive-v1 -F "${LAAVAT_ARCHIVE_REQUEST}" \
               --max-bytes "${LAAVAT_ARCHIVE_MAX_BYTES}"
        if [ -n "${LAAVAT_ARCHIVE_MEMBER}" ]; then
            set -- "$@" --member "${LAAVAT_ARCHIVE_MEMBER}"
        fi
    elif [ "${LAAVAT_SIGN_PAYLOAD}" = "file" ]; then
        [ -n "${LAAVAT_SIGN_INPUT}" ] || bbfatal "LAAVAT_SIGN_INPUT must be set to use laavat-sign"
        set -- -F "${LAAVAT_SIGN_INPUT}"
    else
        bbfatal "LAAVAT_SIGN_PAYLOAD must be 'file' or 'hab-archive-v1', got '${LAAVAT_SIGN_PAYLOAD}'"
    fi

    [ -z "${LAAVAT_APPROVER_TOKEN_FILE}" ] \
        || set -- "$@" --approver-token "@${LAAVAT_APPROVER_TOKEN_FILE}"
    [ "${LAAVAT_SIGN_REQUIRE_DIGEST}" != "0" ] || set -- "$@" --allow-unverified
    # After the built-ins below, so a name given here overrides one of theirs.
    for kv in ${LAAVAT_SIGN_METADATA_EXTRA}; do set -- "$@" --metadata "$kv"; done

    laavat_run "signing ${LAAVAT_SIGN_INPUT}${LAAVAT_ARCHIVE_REQUEST}" \
        signing-tool -c -a "${LAAVAT_API_URL}" -t "@${LAAVAT_TOKEN_FILE}" \
        imagesigning sign \
        --operation "${LAAVAT_SIGN_OPERATION}" \
        -P "${LAAVAT_PRODUCT_ID}" --operid "${LAAVAT_OPER_ID}" \
        -N "${LAAVAT_SIGN_NAME}" -D "${LAAVAT_SIGN_DESC}" \
        -O "${LAAVAT_SIGN_OUTPUT}" \
        --state-dir "${LAAVAT_STATE_DIR}" \
        --wait-timeout "${LAAVAT_SIGN_TIMEOUT}" \
        --metadata '{"recipe": "${PN}", "version": "${PV}", "machine": "${MACHINE}"}' \
        "$@"
}

# No ordering here, so the task is standalone-callable:
#   bitbake <recipe> -c laavat_sign
# Consumers wire it into their build with:
#   addtask laavat_sign after do_compile before do_deploy
addtask laavat_sign
