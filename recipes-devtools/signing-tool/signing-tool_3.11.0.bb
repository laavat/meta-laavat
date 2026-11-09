SUMMARY = "Laavat Signing Solution CLI tool"
HOMEPAGE = "https://docs.laavat.io/"
LICENSE = "Proprietary"
LIC_FILES_CHKSUM = "file://LICENSE;md5=d376b9fcd04494b37ef63b7705452e77"

inherit pypi python_setuptools_build_meta

# PEP 625: the sdist is signing_tool-<version>.tar.gz. This also keeps the
# default S correct.
PYPI_PACKAGE = "signing_tool"

SRC_URI[sha256sum] = "dc09fbc91fb329accf586943a94724b3b240329660aa2882b800fc483babca50"

RDEPENDS:${PN} = "\
    python3-asn1crypto \
    python3-certifi \
    python3-cryptography \
    python3-dateutil \
    python3-jwcrypto \
    python3-json \
    python3-logging \
    python3-requests \
    python3-six \
    python3-urllib3 \
"

BBCLASSEXTEND = "native nativesdk"
