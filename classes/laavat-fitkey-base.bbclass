# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Laavat Oy
#
# Shared half of the two FIT-signing classes. Not inherited directly.
#
# poky keeps one invariant - a single key directory both signs the FIT and supplies the
# public key written into U-Boot's control DTB, so the two always match. The service breaks
# it in one place: the private half never leaves the HSM, so no local mkimage pass can
# produce the real signature. Rather than patch poky, this establishes a different
# invariant and keeps it honest:
#
#   the key directory holds the SERVICE's certificate and a PLACEHOLDER private key.
#   Every local signature is provisional; SignKernel replaces it before anything reads
#   the artifact. The key in the DTB is the service's, and is final.
#
# Where the FIT is built moved in Yocto 5.3, so the two consumers differ only in which
# recipe they attach to and which file they sign:
#
#   laavat-fitkey     <= 5.2, on the kernel recipe (kernel-fitimage.bbclass)
#   laavat-fitimage   >= 5.3, on linux-yocto-fitimage (kernel-fit-image.bbclass)
#
#   LAAVAT_FIT_PUBKEY_SHA256  required - SHA-256 of the DER SubjectPublicKeyInfo to pin
#   LAAVAT_PRODUCT_ID, LAAVAT_OPER_ID, LAAVAT_API_URL, LAAVAT_TOKEN_FILE  as for signing

inherit laavat-sign

LAAVAT_SIGN_OPERATION ??= "SignKernel"
# One variable for both halves. The u-boot recipe cannot see a :pn-linux-yocto override,
# so a per-recipe pin would leave its guard comparing against an empty string.
LAAVAT_PUBKEY_SHA256 ??= "${LAAVAT_FIT_PUBKEY_SHA256}"

# LAAVAT_FIT_IMAGE is the consumer's to set: the two halves sign different files, and
# which one poky deploys depends on the release and on INITRAMFS_IMAGE_BUNDLE.
LAAVAT_SIGN_DIR ??= "${WORKDIR}/laavat"
LAAVAT_SIGN_INPUT ??= "${LAAVAT_FIT_IMAGE}"
LAAVAT_SIGN_OUTPUT ??= "${LAAVAT_SIGN_DIR}/fitImage.laavat-signed"
# poky sets this for its own mkimage pass; the placeholder key matches it.
FIT_SIGN_NUMBITS ??= "2048"

do_laavat_fitkey[depends] += "signing-tool-native:do_populate_sysroot"
do_laavat_fitkey[network] = "1"
# The key bytes are in no task hash, so tie the tasks that consume them to the pin instead.
do_laavat_fitkey[vardeps] += "LAAVAT_PUBKEY_SHA256 UBOOT_SIGN_KEYNAME"
do_laavat_sign[vardeps] += "LAAVAT_PUBKEY_SHA256"
# A failed rerun must not leave the previous run's signed image behind.
do_laavat_sign[cleandirs] = "${LAAVAT_SIGN_DIR}"


do_laavat_fitkey[depends] += "openssl-native:do_populate_sysroot"
do_laavat_fitkey[vardepsexclude] += "LAAVAT_TOKEN_FILE"

do_laavat_fitkey() {
    # Self-contained: without LAAVAT_SIGN_SKIP laavat_fetch_pubkey exports this before the
    # openssl calls below, and with it there is no fetch to do the exporting.
    export OPENSSL_MODULES="${STAGING_LIBDIR_NATIVE}/ossl-modules"
    # Both classes need somewhere to put the service certificate.
    [ -n "${UBOOT_SIGN_KEYDIR}" ] || bbfatal "UBOOT_SIGN_KEYDIR must be set: it names where poky looks for the FIT signing key, which is where this class puts the service's certificate"
    [ -n "${UBOOT_SIGN_KEYNAME}" ] || bbfatal "UBOOT_SIGN_KEYNAME must be set: it names where poky looks for the FIT signing key, which is where this class puts the service's certificate"

    mkdir -p "${UBOOT_SIGN_KEYDIR}"
    laavat_key="${UBOOT_SIGN_KEYDIR}/${UBOOT_SIGN_KEYNAME}.key"
    laavat_crt="${UBOOT_SIGN_KEYDIR}/${UBOOT_SIGN_KEYNAME}.crt"

    # Kept, not regenerated: a new placeholder key each build changes the FIT bytes and so
    # opens a fresh signing request - for a four-eyes operation, a fresh approval.
    if [ ! -f "$laavat_key" ]; then
        # 0600 before a byte is written: the directory is usually world-readable.
        (umask 077; openssl genrsa -out "$laavat_key" "${FIT_SIGN_NUMBITS}") \
            || bbfatal "could not write a placeholder FIT signing key to $laavat_key"
        bbnote "wrote a placeholder FIT signing key to $laavat_key; SignKernel replaces every signature it makes"
    fi

    mkdir -p "${LAAVAT_SIGN_DIR}"
    # mkimage -K and fdt_add_pubkey read only the modulus and exponent out of
    # <keyname>.crt, and never check its signature - so wrapping the service's key in a
    # certificate signed by the placeholder is what hands that key to poky. RSA only:
    # fdt_add_pubkey cannot use anything else, and it fails at u-boot build time, which
    # for the kernel half is *after* an approval has already been spent.
    if [ -n "${LAAVAT_SIGN_SKIP}" ]; then
        # No account: the certificate carries the placeholder's own key, so poky signs and
        # verifies against one throwaway key and the build completes - unsigned, and said so.
        bbwarn "LAAVAT_SIGN_SKIP is set: the FIT will be anchored to a throwaway key, not the service's"
        set --
    else
        laavat_pub="${LAAVAT_SIGN_DIR}/fit-pub.pem"
        laavat_fetch_pubkey "$laavat_pub" "${LAAVAT_PUBKEY_SHA256}"
        openssl asn1parse -in "$laavat_pub" | grep -q rsaEncryption \
            || bbfatal "FIT signing needs an RSA key; this operation's key is not one"
        set -- -force_pubkey "$laavat_pub"
    fi
    openssl req -new -key "$laavat_key" -subj "/CN=${UBOOT_SIGN_KEYNAME}" \
        -out "${LAAVAT_SIGN_DIR}/fit.csr" \
        || bbfatal "could not build the certificate request for the service key"
    openssl x509 -req -in "${LAAVAT_SIGN_DIR}/fit.csr" -signkey "$laavat_key" \
        "$@" -days 36500 -out "$laavat_crt.part" \
        || bbfatal "could not wrap the service key in a certificate"
    mv "$laavat_crt.part" "$laavat_crt"
    bbnote "wrote $laavat_crt"
}

do_laavat_fitimage_install() {
    if [ -n "${LAAVAT_SIGN_SKIP}" ]; then
        bbwarn "LAAVAT_SIGN_SKIP is set: the FIT keeps its placeholder signature"
        exit 0
    fi
    # Put the service-signed FIT back where poky left the provisional one.
    [ -n "${LAAVAT_FIT_IMAGE}" ] || bbfatal "LAAVAT_FIT_IMAGE is empty: it names the FIT poky built and deploys, and only laavat-fitkey and laavat-fitimage know which file that is"
    [ -s "${LAAVAT_SIGN_OUTPUT}" ] || bbfatal "do_laavat_sign produced no ${LAAVAT_SIGN_OUTPUT}"
    # Whole or not at all: a truncated fitImage would be deployed and installed as if signed.
    cp "${LAAVAT_SIGN_OUTPUT}" "${LAAVAT_FIT_IMAGE}.part"
    mv "${LAAVAT_FIT_IMAGE}.part" "${LAAVAT_FIT_IMAGE}"
    bbnote "installed the service-signed FIT over ${LAAVAT_FIT_IMAGE}"
}
