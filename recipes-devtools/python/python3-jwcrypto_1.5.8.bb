SUMMARY = "Implementation of JOSE Web standards"
HOMEPAGE = "https://github.com/latchset/jwcrypto"
LICENSE = "LGPL-3.0-or-later"
LIC_FILES_CHKSUM = "file://LICENSE;md5=e6a600fd5e1d9cbde2d983680233ad02"

inherit pypi python_hatchling

SRC_URI[sha256sum] = "c3d7114b6f6e65b52f6b7da817eb8cb8423e1da31e1ef13508447c81ecbdcc34"

RDEPENDS:${PN} += "python3-cryptography"

BBCLASSEXTEND = "native nativesdk"
