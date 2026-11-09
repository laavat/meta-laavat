# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Laavat Oy
#
# Install the service's issuing CA as the device's RAUC keyring.
#
# The other half of laavat-rauc: RaucBundleSigningWithOneTimeKey mints a per-bundle
# certificate, so there is no single signer key to pin - the device has to trust the
# issuing CA. Inherit from the recipe that owns /etc/rauc (poky's rauc-conf).
#
# Pinned by digest, and required: a changed CA breaks the build rather than quietly
# widening what the device accepts. Take it once by hand and paste it in:
#
#     sha256sum service-ca.pem
#
#   LAAVAT_RAUC_CA_SHA256  required - SHA-256 of the CA file being installed
#   LAAVAT_RAUC_CA_FILE    name of the fetched file (default: service-ca.pem)
#   LAAVAT_RAUC_CA         its path, if the release-dependent search is not wanted

LAAVAT_RAUC_CA_FILE ??= "service-ca.pem"
# Empty means "find it": where file:// lands moved between releases, see do_laavat_ca_pin.
LAAVAT_RAUC_CA ??= ""
LAAVAT_RAUC_CA_STAGED ??= "${WORKDIR}/laavat/${LAAVAT_RAUC_CA_FILE}"
LAAVAT_RAUC_KEYRING ??= "${sysconfdir}/rauc/ca.cert.pem"

SRC_URI += "file://${LAAVAT_RAUC_CA_FILE}"
# The CA's bytes are in no task hash, so tie the install that embeds it to the pin.
do_install[vardeps] += "LAAVAT_RAUC_CA_SHA256"

do_laavat_ca_pin() {
    # Without an account there is no service CA to pin against, and demanding one here
    # broke the build a consumer is invited to make - this class signs nothing, so the
    # pin is the only thing LAAVAT_SIGN_SKIP has to relax. The file still has to exist
    # and is still installed, because rauc needs a keyring either way.
    if [ -n "${LAAVAT_SIGN_SKIP}" ] && [ -z "${LAAVAT_RAUC_CA_SHA256}" ]; then
        bbwarn "LAAVAT_SIGN_SKIP is set and no LAAVAT_RAUC_CA_SHA256: installing ${LAAVAT_RAUC_CA_FILE} as the device keyring unverified. This device would accept whatever that file trusts - pin it before shipping."
    else
        [ -n "${LAAVAT_RAUC_CA_SHA256}" ] || bbfatal "LAAVAT_RAUC_CA_SHA256 must pin the CA installed as the device keyring: it is the root of trust for every update this device will ever accept, so a swapped file must fail the build rather than widen it"
    fi
    # Where a file:// source lands moved: ${WORKDIR} on Yocto 5.0, ${WORKDIR}/sources-unpack
    # on 5.1 and 5.2, ${WORKDIR}/sources on 5.3 and later. Search rather than assume, and never
    # assign UNPACKDIR here - a class's ??= is parsed after bitbake.conf's and would win,
    # moving every other source this recipe fetches.
    laavat_ca="${LAAVAT_RAUC_CA}"
    if [ -z "$laavat_ca" ]; then
        for c in "${UNPACKDIR}/${LAAVAT_RAUC_CA_FILE}" "${WORKDIR}/${LAAVAT_RAUC_CA_FILE}"; do
            [ -r "$c" ] && { laavat_ca="$c"; break; }
        done
    fi
    [ -r "$laavat_ca" ] || bbfatal "cannot find ${LAAVAT_RAUC_CA_FILE} under ${UNPACKDIR} or ${WORKDIR}; set LAAVAT_RAUC_CA to the CA to install as the device keyring"
    got=$(sha256sum "$laavat_ca" | cut -d' ' -f1)
    want=$(echo "${LAAVAT_RAUC_CA_SHA256}" | tr 'A-Z' 'a-z' | tr -d '[:space:]')
    [ -z "$want" ] || [ "$got" = "$want" ] || bbfatal "$laavat_ca is $got, pinned to $want"
    # Staged, so do_install installs the bytes this task verified rather than re-reading
    # a path that nothing checked again.
    install -D -m 0644 "$laavat_ca" "${LAAVAT_RAUC_CA_STAGED}"
    bbnote "device keyring pinned to $got"
}
addtask laavat_ca_pin after do_unpack before do_install

do_install:append() {
    install -D -m 0644 ${LAAVAT_RAUC_CA_STAGED} ${D}${LAAVAT_RAUC_KEYRING}
}
