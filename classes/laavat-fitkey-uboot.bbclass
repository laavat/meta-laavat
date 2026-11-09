# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Laavat Oy
#
# The u-boot half of laavat-fitkey. Inherit this from the u-boot recipe whenever the
# kernel recipe inherits laavat-fitkey; the two halves have to agree.
#
# poky's concat_dtb runs ONE mkimage command that both signs a FIT and writes the public
# key into U-Boot's control DTB. Signing uses the key directory's private key - a
# placeholder under laavat-fitkey - so it would overwrite the service's signature and then
# fail poky's own verification a line later. Substituting an inject-only command leaves the
# signature the service's and the key the service's.
#
# What follows the injection changed in Yocto 5.3:
#
#   <= 5.2  upstream verifies the real fitImage staged from the kernel recipe. That is a
#           genuine end-to-end check of the service's signature against the injected key,
#           so it is left alone.
#   >= 5.3  the kernel FIT moved to its own recipe and u-boot no longer depends on it, so
#           upstream verifies a DUMMY FIT built from /dev/null instead. laavat_fit_inject
#           never creates that dummy - signing it would need the private half the service
#           holds - so the check fails on a missing file; and had the file existed it would
#           only have been the placeholder key checking itself. laavat_fit_check_sign
#           stands in, and laavat_fit_assert_anchor makes the check still worth making.
#
# No ordering is added: poky already makes this task read the kernel's sysroot output, so
# the kernel's do_laavat_fitkey and do_laavat_sign have both run by the time it starts.

# Only openssl, for the pin checks below. fdt_add_pubkey comes out of this recipe's own
# build tree: u-boot's "all" target builds tools/, and taking it from there rather than
# from u-boot-tools-native means this layer needs no bbappend on a recipe it does not own.
# A bbappend that changes u-boot-tools for every build that merely has this layer in
# bblayers is what yocto-check-layer's signature test exists to catch.
DEPENDS += "openssl-native"

# Where to find fdt_add_pubkey. The default is searched, not assumed: ${B} is the build
# directory for poky's u-boot but the *source* directory for recipes that build into a
# config-named subdirectory (u-boot-variscite builds into ${B}/<machine>_config/), and some
# u-boot recipes produce no tools at all. Set this to a path to skip the search.
LAAVAT_FDT_ADD_PUBKEY ??= ""

UBOOT_MKIMAGE_SIGN = "laavat_fit_inject"

python __anonymous() {
    if d.getVar("SPL_SIGN_ENABLE") == "1":
        bb.fatal("laavat-fitkey-uboot does not support SPL_SIGN_ENABLE: the SPL path signs a "
                 "second FIT with the same key directory, whose private key is a placeholder "
                 "here, so the SPL image would carry a signature nothing can verify")
    if d.getVar("FIT_SIGN_INDIVIDUAL") == "1":
        bb.fatal("laavat-fitkey-uboot does not support FIT_SIGN_INDIVIDUAL: it injects a "
                 "second, per-image key this layer does not manage, and the images signed "
                 "with it would then fail to verify on the device. Upstream advises against "
                 "it too - sign configurations only")
    # Stand in for the verification exactly when upstream aims it at the dummy FIT that
    # laavat_fit_inject declines to create, which is the 5.3-and-later shape of concat_dtb.
    if "unused.itb" in (d.getVar("concat_dtb") or ""):
        d.setVar("UBOOT_FIT_CHECK_SIGN", "laavat_fit_check_sign")
}

laavat_fit_inject() {
    # Stands in for mkimage in concat_dtb. Its signing arguments are ignored on purpose:
    # signing is the service's job, and injection is the only part wanted here.
    crt="${UBOOT_SIGN_KEYDIR}/${UBOOT_SIGN_KEYNAME}.crt"
    [ -f "$crt" ] || bbfatal "$crt is missing: the kernel recipe's do_laavat_fitkey puts the service's certificate there, and without it there is no key to inject"
    # The key directory lives outside sstate and outside any WORKDIR, so a stale certificate
    # from an earlier configuration can survive a rebuild. Injecting one would anchor the
    # device to a key the service does not hold, and nothing later would notice.
    # Under LAAVAT_SIGN_SKIP the certificate is the placeholder's own, so the pin cannot
    # match and there is nothing to protect: the build is already unsigned by request.
    got=$(openssl x509 -in "$crt" -pubkey -noout \
          | openssl pkey -pubin -outform DER | sha256sum | cut -d" " -f1)
    if [ -z "${LAAVAT_SIGN_SKIP}" ] && [ -z "${LAAVAT_FIT_PUBKEY_SHA256}" ]; then
        # Naming the variable matters: the kernel half accepts LAAVAT_PUBKEY_SHA256 through
        # a ??= and signs happily, so an integrator who set that one arrives here with an
        # empty pin - and, on a four-eyes operation, an approval already spent.
        bbfatal "LAAVAT_FIT_PUBKEY_SHA256 is empty. Both FIT halves read that one variable, not LAAVAT_PUBKEY_SHA256: the u-boot recipe cannot see a :pn-linux-yocto override, so a per-recipe pin leaves this guard with nothing to compare against."
    fi
    if [ -z "${LAAVAT_SIGN_SKIP}" ] && [ "$got" != "${LAAVAT_FIT_PUBKEY_SHA256}" ]; then
        bbfatal "$crt carries key $got, but LAAVAT_FIT_PUBKEY_SHA256 pins" \
                "${LAAVAT_FIT_PUBKEY_SHA256}; refusing to anchor U-Boot to an unpinned key"
    fi
    tool="${LAAVAT_FDT_ADD_PUBKEY}"
    # ${B}/tools for a normal u-boot, ${B}/*/tools for a config-subdirectory build, then
    # PATH for a recipe that builds no tools and an integrator who installed it instead.
    for c in "$tool" "${B}/tools/fdt_add_pubkey" ${B}/*/tools/fdt_add_pubkey \
             "$(command -v fdt_add_pubkey 2>/dev/null)"; do
        [ -n "$c" ] && [ -x "$c" ] && { tool="$c"; break; }
    done
    [ -n "$tool" ] && [ -x "$tool" ] \
        || bbfatal "no fdt_add_pubkey: this u-boot builds none under ${B} and none is on PATH. Set LAAVAT_FDT_ADD_PUBKEY to one, or install it from u-boot-tools."
    "$tool" \
        -a "${FIT_HASH_ALG},${FIT_SIGN_ALG}" \
        -k "${UBOOT_SIGN_KEYDIR}" \
        -n "${UBOOT_SIGN_KEYNAME}" \
        -r conf \
        "${UBOOT_DTB_BINARY}"
}

laavat_fit_check_sign() {
    # Stands in for uboot-fit_check_sign from 5.3 on. Its arguments name a dummy FIT that
    # laavat_fit_inject never creates, and verifying it would prove only that the
    # placeholder key can check its own work.
    bbnote "not verifying upstream's dummy FIT; laavat_fit_assert_anchor checks that the control device tree carries the pinned service key instead"
}

# poky degrades a failed key injection to a warning - "Verified boot won't be available" -
# and the task still succeeds. A developer would get a green build and an image whose kernel
# nothing checks, which is the exact failure this layer exists to prevent. Assert instead.
#
# Machines that take their control device tree from the platform rather than appending one
# (qemuarm64-secureboot sets OF_BOARD) legitimately have no u-boot.dtb, and must set this to
# "0" - the anchor then has to reach U-Boot some other way, and saying so is the point.
LAAVAT_FIT_REQUIRE_CONTROL_DTB ??= "1"

do_uboot_assemble_fitimage[postfuncs] += "laavat_fit_assert_anchor"

laavat_fit_assert_anchor() {
    if [ "${LAAVAT_FIT_REQUIRE_CONTROL_DTB}" != "1" ]; then
        bbnote "LAAVAT_FIT_REQUIRE_CONTROL_DTB is 0: not checking u-boot.dtb for the FIT" \
               "verification key. Whatever supplies this machine's control device tree has" \
               "to carry it instead."
        return
    fi
    # concat_dtb writes this relative to its own working directory, which is ${B} for a
    # normal u-boot but ${B}/<config>/ for a recipe that builds into a subdirectory, so look
    # in both rather than assuming.
    signed="${UBOOT_DTB_SIGNED}"
    for c in "$signed" "${B}/${UBOOT_DTB_SIGNED}" ${B}/*/"${UBOOT_DTB_SIGNED}"; do
        [ -e "$c" ] && { signed="$c"; break; }
    done
    if [ ! -e "$signed" ]; then
        bbfatal "${UBOOT_DTB_SIGNED} does not exist, so the FIT verification key was never" \
                "written into U-Boot's control device tree and the kernel would boot" \
                "unverified. If this machine takes its device tree from the platform, set" \
                "LAAVAT_FIT_REQUIRE_CONTROL_DTB = \"0\" and supply the key there."
    fi
    if [ -n "${LAAVAT_SIGN_SKIP}" ]; then
        bbwarn "LAAVAT_SIGN_SKIP is set: checking that the throwaway key landed, not the service's"
    fi
    grep -aq "key-${UBOOT_SIGN_KEYNAME}" "$signed" \
        || bbfatal "$signed carries no key named ${UBOOT_SIGN_KEYNAME}: the injection reported success but nothing landed"
    # The name proves a node exists; only the key material proves it is the right one, and
    # from 5.3 on this is the whole of the post-injection check. fdt_add_pubkey writes
    # rsa,modulus as the raw big-endian modulus, so the certificate's own modulus - already
    # pinned against LAAVAT_FIT_PUBKEY_SHA256 above - appears verbatim in the tree.
    mod=$(openssl x509 -in "${UBOOT_SIGN_KEYDIR}/${UBOOT_SIGN_KEYNAME}.crt" -noout -modulus \
          | sed "s/^Modulus=//" | tr "A-F" "a-f")
    od -An -tx1 -v "$signed" | tr -d " \n" | grep -q "$mod" \
        || bbfatal "$signed names ${UBOOT_SIGN_KEYNAME} but does not carry its key material; U-Boot would check the kernel against a key the service does not hold"
    bbnote "u-boot control device tree $signed carries ${UBOOT_SIGN_KEYNAME} and its key material"
}
