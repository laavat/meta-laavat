# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Laavat Oy
#
# Sign the kernel FIT with the service, and give U-Boot the key that verifies it.
# Yocto 5.2 and earlier, where kernel-fitimage.bbclass builds the FIT on the kernel recipe.
#
# Inherit from the kernel recipe. The u-boot recipe needs laavat-fitkey-uboot.bbclass as
# well: poky splits FIT signing across the two, and both halves have to agree.
#
# On Yocto 5.3 and later use laavat-fitimage instead: kernel-fitimage.bbclass was replaced
# by kernel-fit-image.bbclass, the FIT moved to its own linux-yocto-fitimage recipe, and
# do_assemble_fitimage / do_kernel_generate_rsa_keys / fitImage-none no longer exist.

inherit laavat-fitkey-base

# fitImage-none is what poky signs and then installs into the sysroot; u-boot verifies THAT
# copy, not the deployed one. Signing it in place is what makes every downstream consumer
# correct from a single hook - replacing only ${DEPLOYDIR}/fitImage leaves u-boot checking
# a placeholder signature against the service's key, which fails on any board that reads
# its own control DTB.
LAAVAT_FIT_IMAGE ??= "${B}/${KERNEL_OUTPUT_DIR}/fitImage-none"

python __anonymous() {
    if d.getVar("UBOOT_SIGN_ENABLE") != "1":
        bb.fatal("laavat-fitkey needs UBOOT_SIGN_ENABLE = \"1\": with it off poky builds no "
                 "signed FIT and there is nothing for SignKernel to sign")
    if "kernel-fitimage" not in (d.getVar("KERNEL_CLASSES") or "").split():
        bb.fatal("laavat-fitkey needs kernel-fitimage in KERNEL_CLASSES: there is no fitImage. "
                 "On Yocto 5.3 and later that class does not exist - the FIT is built by the "
                 "linux-yocto-fitimage recipe, so inherit laavat-fitimage there instead")
    if d.getVar("INITRAMFS_IMAGE_BUNDLE") == "1":
        bb.fatal("laavat-fitkey does not support INITRAMFS_IMAGE_BUNDLE. With it set, poky "
                 "assembles a SECOND fitImage with the initramfs inside it "
                 "(fitImage-bundle, built by do_assemble_fitimage_initramfs), points "
                 "fitImage at that one, and skips installing fitImage in do_install "
                 "altogether. The service would sign fitImage-none, which then reaches "
                 "nothing: the deployed and booted image would carry poky's placeholder "
                 "signature, the build would be green, and the device would refuse every "
                 "kernel it was given. Build the initramfs as its own image rather than "
                 "bundling it, or leave the kernel unsigned on this machine")
    for laavat_var in ("UBOOT_SIGN_KEYDIR", "UBOOT_SIGN_KEYNAME"):
        if not d.getVar(laavat_var):
            bb.fatal("%s must be set: it names where poky looks for the FIT signing "
                     "key, which is where this class puts the service's certificate"
                     % laavat_var)
}

# Before poky's generator, which skips its own key generation when both files already exist.
addtask laavat_fitkey after do_unpack before do_kernel_generate_rsa_keys
# Before do_install, which carries the FIT into the sysroot that u-boot verifies against.
addtask laavat_sign after do_assemble_fitimage before do_laavat_fitimage_install
addtask laavat_fitimage_install after do_laavat_sign before do_install do_deploy
