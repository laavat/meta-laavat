# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Laavat Oy
#
# Sign the kernel FIT with the service, and give U-Boot the key that verifies it.
# Yocto 5.3 and later, where the FIT is built by its own recipe.
#
# Inherit from linux-yocto-fitimage, NOT from the kernel. 5.3 replaced
# kernel-fitimage.bbclass with kernel-fit-image.bbclass and moved the FIT into a separate
# recipe; kernel.bbclass now errors outright if fitImage is still named in KERNEL_IMAGETYPE.
# The u-boot half is unchanged - laavat-fitkey-uboot, on the u-boot recipe, as before.
#
# On Yocto 5.2 and earlier use laavat-fitkey instead.
#
# The signed image replaces ${B}/fitImage before do_install and do_deploy, so the copy that
# reaches the sysroot and the copy that reaches the deploy directory are both the service's.

inherit laavat-fitkey-base

# kernel-fit-image.bbclass builds exactly one image, at ${B}/fitImage, and its do_install
# copies that file. There is no fitImage-none in this layout: nothing signs locally except
# the placeholder pass, and that writes in place.
LAAVAT_FIT_IMAGE ??= "${B}/fitImage"

python __anonymous() {
    # 5.3 renamed the switch but keeps UBOOT_SIGN_ENABLE as the default source.
    if d.getVar("FIT_KERNEL_SIGN_ENABLE") != "1" and d.getVar("UBOOT_SIGN_ENABLE") != "1":
        bb.fatal("laavat-fitimage needs FIT_KERNEL_SIGN_ENABLE = \"1\" (or UBOOT_SIGN_ENABLE, "
                 "which it defaults to): with signing off the FIT carries no signature node "
                 "and there is nothing for SignKernel to replace")
    for laavat_var in ("UBOOT_SIGN_KEYDIR", "UBOOT_SIGN_KEYNAME"):
        if not d.getVar(laavat_var):
            bb.fatal("%s must be set: it names where poky looks for the FIT signing "
                     "key, which is where this class puts the service's certificate"
                     % laavat_var)
}

# Before the FIT is built, so the placeholder key and the service certificate are both in
# place when mkimage runs.
addtask laavat_fitkey after do_unpack before do_compile
addtask laavat_sign after do_compile before do_laavat_fitimage_install
addtask laavat_fitimage_install after do_laavat_sign before do_install do_deploy
