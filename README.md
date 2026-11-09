# meta-laavat

Sign build artifacts with the [LAAVAT Signing Solution](https://docs.laavat.io/)
from inside a bitbake build.

This layer provides:

- `signing-tool` - the LAAVAT reference client (also `-native` / `-nativesdk`)
- `python3-jwcrypto` - a dependency of the above that no public layer carries
- `laavat-sign.bbclass` - a `do_laavat_sign` task that submits an artifact for
  signing, waits for approval, verifies the returned digest and writes the
  signed file
- `laavat-fitkey.bbclass` / `laavat-fitkey-uboot.bbclass` - sign the kernel FIT
  *and* place the key that verifies it in U-Boot's control device tree

Requires signing-tool >= 3.9.2, which owns the whole signing round trip. The
classes call `imagesigning pack`, `unpack`, `hab-request` and `sign`; none of
those exist in 3.9.1, so an older client parses fine and then fails inside the
first signing task with `invalid choice`.

The recipe in this layer is 3.11.0.

## Dependencies

This layer depends on:

    URI: https://git.yoctoproject.org/poky
    layers: meta
    branch: scarthgap, styhead or walnascar

    URI: https://git.openembedded.org/meta-openembedded
    layers: meta-oe, meta-python
    branch: scarthgap, styhead or walnascar

From whinlatter (5.3) on there is no poky: clone `bitbake`,
`openembedded-core` and `meta-yocto` as siblings instead.
`LAYERSERIES_COMPAT_laavat` names all five releases, and
`make yocto-matrix` in
[meta-laavat-testbed](https://github.com/laavat/meta-laavat-testbed) parses
each one.

## Adding the layer to your build

    bitbake-layers add-layer /path/to/meta-laavat

[docs/INTEGRATION.md](docs/INTEGRATION.md) walks an existing board build
through this - including the kas form - and then wires each signing target:
boot image, FIT kernel image, RAUC bundle.

## Maintainer

Laavat Oy <contact@laavat.com>

## Contributing

Send patches to the maintainer address above with `[meta-laavat]` in the
subject line:

    git send-email --to contact@laavat.com --subject-prefix 'meta-laavat][PATCH'

## Using it

Find the UUIDs your recipe needs:

    signing-tool -c -a "$URL" -t @"$TOKENFILE" product getall
    signing-tool -c -a "$URL" -t @"$TOKENFILE" product get -P <product-id>

`LAAVAT_SIGN_OPERATION` is the subcommand of `signing-tool imagesigning add`,
which chooses how the client builds the request; what the service actually
performs comes from `LAAVAT_OPER_ID`, and a mismatch between the two is
rejected by the service, not by this layer. The class always uploads a file,
so the operation must be one of the file-upload subcommands (`imagesigning add
--help`) - digest-signing and encryption ones need arguments it does not pass.
The names match the service's operation types except `MCUBoot`, whose type is
`SignMcuBoot`.

Put the token in a file readable only by the build user, and let bitbake see
its *path*:

    printf '%s' "$TOKEN" > ~/.laavat-token && chmod 600 ~/.laavat-token
    export LAAVAT_TOKEN_FILE=~/.laavat-token
    export BB_ENV_PASSTHROUGH_ADDITIONS="$BB_ENV_PASSTHROUGH_ADDITIONS LAAVAT_TOKEN_FILE LAAVAT_APPROVER_TOKEN_FILE"

Then, in a `u-boot-%.bbappend`:

    inherit laavat-sign

    LAAVAT_API_URL = "https://signing.example.com/api/v1"
    LAAVAT_PRODUCT_ID = "6c800aa5-d4b0-4e70-95cc-f29d126bc061"
    LAAVAT_OPER_ID = "e444a17e-283d-459a-bc83-61beca04d687"
    LAAVAT_SIGN_OPERATION = "SignUBoot"
    LAAVAT_SIGN_INPUT = "${B}/u-boot.imx"
    LAAVAT_SIGN_OUTPUT = "${B}/u-boot.imx.signed"

    addtask laavat_sign after do_compile before do_deploy

The task can also be run on its own:

    bitbake u-boot -c laavat_sign

A recipe that signs more than one artifact adds a task per artifact, each
setting the variables for its own file - there is no python helper to call, and
`tests/test_layer_shape.py` fails the build if one appears. `laavat-optee` is
the worked example: it signs every TA in one request by packing them into an
archive, which is what `imagesigning pack` and `unpack` are for.

### The classes

`laavat-sign` is the engine; the rest are one per integration, so a recipe
inherits a class and supplies variables rather than copying tasks. Everything
machine-specific - which recipe, which file, which product id - stays in the
BSP layer that does the inheriting.

| Class | Inherit from | What it does |
|---|---|---|
| `laavat-sign` | any recipe | `do_laavat_sign` over one file, or a `hab-archive-v1` request. Every other class builds on it. |
| `laavat-hab` | the boot-image recipe (`imx-boot`) | find the built binary, build `request.json` from the IVT blocks in it, sign it in archive mode, deploy the result. No template and usually no path: `LAAVAT_HAB_IMAGE` is only needed when the machine builds several boot images. |
| `laavat-ahab` | the boot-image recipe, on AHAB parts (i.MX93 ELE, i.MX8QM SECO) | `SignSPSDK` over the whole image. AHAB signs one container rather than per-stage IVTs, so this is a plain file upload with no request to build. |
| `laavat-bootgen` | the recipe building `BOOT.bin` (`xilinx-bootbin`) | pack each `.bif` with the partitions it names, let the **service** run bootgen, install what it returns. The BIF is not parsed here: the service's parser is the authoritative one and understands `[fsbl_config]` settings such as `bh_auth_enable`. |
| `laavat-fitkey` | the kernel recipe, Yocto <= 5.2 | sign the assembled FIT **and** put the service's key where poky looks for the FIT verification key. |
| `laavat-fitimage` | `linux-yocto-fitimage`, Yocto >= 5.3 | the same, where 5.3 moved the FIT into its own recipe. Inherit exactly one of this and `laavat-fitkey`. |
| `laavat-fitkey-uboot` | the u-boot recipe | the other half: inject that key into U-Boot's control device tree. |
| `laavat-rauc` | a recipe that inherits `bundle` | pack the `resign` request, sign it, deploy the signed bundle. |
| `laavat-rauc-keyring` | the recipe owning `/etc/rauc` | install the service's issuing CA as the device keyring, pinned by digest. |
| `laavat-optee` | `optee-os` | fetch and embed the TA trust anchor, then pack / sign / unpack every built `.ta`. |

Both halves of a pair have to be enabled together - `laavat-fitkey` without
`laavat-fitkey-uboot` signs a kernel the device still verifies against the
build's own key, and `laavat-rauc` without `laavat-rauc-keyring` produces a
bundle the device refuses. Guard them on the same variable.

### Variables

| Variable | Meaning | Default |
|---|---|---|
| `LAAVAT_API_URL` | API address | required |
| `LAAVAT_PRODUCT_ID` | Product UUID | required |
| `LAAVAT_OPER_ID` | Operation UUID | required |
| `LAAVAT_SIGN_OPERATION` | `SignUBoot`, `SignHAB`, `SignSPSDK`, `RaucBundleSigningWithOneTimeKey`, ... | required |
| `LAAVAT_SIGN_INPUT` | File to sign; not used when `LAAVAT_SIGN_PAYLOAD` is `hab-archive-v1` | required (file mode) |
| `LAAVAT_SIGN_OUTPUT` | Where the signed payload lands | required |
| `LAAVAT_SIGN_PAYLOAD` | `file` or `hab-archive-v1` | `file` |
| `LAAVAT_ARCHIVE_REQUEST` | Rendered `request.json` path; required when `LAAVAT_SIGN_PAYLOAD` is `hab-archive-v1` | unset |
| `LAAVAT_ARCHIVE_MEMBER` | Which patched binary to install; required if the request patches more than one | unset |
| `LAAVAT_ARCHIVE_MAX_BYTES` | Byte cap on the result archive | `2147483648` |
| `LAAVAT_SIGN_NAME` | Request name | `${PN}-${PV}` |
| `LAAVAT_SIGN_DESC` | Request description | `${PN} ${PV} <operation> for ${MACHINE}` |
| `LAAVAT_SIGN_TIMEOUT` | Seconds to wait for approval and payload | `1800` |
| `LAAVAT_SIGN_REQUIRE_DIGEST` | `0` installs without a digest check, for a service that reports none - only a *missing* input digest becomes advisory; a reported-but-mismatched one still fails. **Refused** for `hab-archive-v1`, which fails the build rather than proceeding: `response.json` travels inside the archive it describes, so without the outer digest the per-member digests prove nothing | `1` |
| `LAAVAT_STATE_DIR` | Where resume state lives; must outlive `WORKDIR` | `${TMPDIR}/laavat-sign` |
| `LAAVAT_SIGN_METADATA_EXTRA` | Extra request metadata as space-separated `name=value` pairs, shown to whoever approves alongside the recipe, version and machine the task fills in - a CI job URL, say. Kept out of the task hash on purpose, so a per-build value does not re-sign unchanged bytes | unset |
| `LAAVAT_SIGN_SKIP` | Set to anything and nothing is signed: each task says what it is not doing, the deploy steps install nothing, and the FIT is anchored to a throwaway key so the build still completes. For building a tier with no account - it produces **unsigned output**, so never set it in a release build | unset |

Per class, on top of those:

| Variable | For | Meaning | Default |
|---|---|---|---|
| `LAAVAT_HAB_IMAGE` | `laavat-hab` | Which boot image to sign; needed only when the machine builds several | unset (searches `LAAVAT_HAB_SEARCH_DIR`) |
| `LAAVAT_HAB_STAGES` | `laavat-hab` | Boot stages to claim IVTs for | `SPL UBOOT` |
| `LAAVAT_AHAB_IMAGE`, `LAAVAT_AHAB_DEPLOY_NAME` | `laavat-ahab` | The image to sign, and the name it deploys under | image required; name `${UUU_BOOTLOADER}` |
| `LAAVAT_BOOTGEN_ARCH` | `laavat-bootgen` | bootgen `-arch`, e.g. `zynqmp` | `${BOOTGEN_ARCH}` |
| `LAAVAT_BOOTGEN_BIFS`, `LAAVAT_BOOTGEN_OUTPUTS` | `laavat-bootgen` | BIF basenames and the `.bin` each produces, in the same order | `bootgen.bif`, `BOOT.bin` |
| `LAAVAT_HAB_DEPLOY_NAME` | `laavat-hab` | The name the signed image deploys under | `${LAAVAT_ARCHIVE_MEMBER}`, ie. `flash.bin` |
| `LAAVAT_PUBKEY_SHA256` | `laavat-optee` | SHA-256 of the DER SubjectPublicKeyInfo to pin the fetched key to | required |
| `LAAVAT_FIT_PUBKEY_SHA256` | `laavat-fitkey`, `laavat-fitimage`, `laavat-fitkey-uboot` | The same pin for FIT verified boot. **One variable for both halves**, not `LAAVAT_PUBKEY_SHA256`: the u-boot recipe cannot see a `:pn-linux-yocto` override, so a per-recipe pin would leave its guard comparing against an empty string | required |
| `LAAVAT_FIT_IMAGE` | `laavat-fitkey`, `laavat-fitimage` | The FIT to sign | the recipe's own build path |
| `LAAVAT_FIT_REQUIRE_CONTROL_DTB` | `laavat-fitkey-uboot` | Whether to require the key in U-Boot's control device tree. Set `"0"` only when the machine takes its device tree from the platform (`CONFIG_OF_BOARD`), and say where the key reaches U-Boot instead | `1` |
| `LAAVAT_FDT_ADD_PUBKEY` | `laavat-fitkey-uboot` | Path to `fdt_add_pubkey`, if the search does not find it | unset (searches `${B}` then `PATH`) |
| `LAAVAT_TA_GLOB` | `laavat-optee` | Which trusted applications to sign | `${B}/ta/*/*.ta` |
| `LAAVAT_RAUC_BUNDLE` | `laavat-rauc` | The bundle to re-sign | `${B}/bundle.raucb` |
| `LAAVAT_RAUC_CA_SHA256` | `laavat-rauc-keyring` | SHA-256 **of the CA file itself**, not of a key - this class installs a file rather than fetching a key. Required, except under `LAAVAT_SIGN_SKIP` | required |
| `LAAVAT_RAUC_CA_FILE` | `laavat-rauc-keyring` | Name of the CA fetched via `SRC_URI` | `service-ca.pem` |
| `LAAVAT_RAUC_CA` | `laavat-rauc-keyring` | Its path, if the release-dependent search is not wanted | unset (searches `UNPACKDIR` then `WORKDIR`) |
| `LAAVAT_RAUC_KEYRING` | `laavat-rauc-keyring` | Where the CA lands on the device | `${sysconfdir}/rauc/ca.cert.pem` |
| `LAAVAT_CLIENT_MIN_VERSION` | all | The client version the failure message names when `imagesigning sign` is missing. The check itself asks the client whether the subcommand exists, so lowering this does not make an old client work | `3.9.2` |

`LAAVAT_SIGN_DIR`, `LAAVAT_BOOTGEN_DIR`, `LAAVAT_TA_PUBKEY` and
`LAAVAT_RAUC_CA_STAGED` name where a task stages its own intermediates under
`WORKDIR`. They have working defaults and exist to be read, not set.

### Download encoding

There is nothing to set. How the service stores a signed object differs per
operation - raw for FIT, RAUC, OP-TEE, xilinx and mcuboot, base64 for the HAB
file-mode path, SPSDK, CMS and AES. signing-tool verifies the reported digest
against both forms and installs whichever one it matched, so the encoding is
decided by the artifact rather than by configuration.

## Licence

MIT. See [LICENSE](LICENSE).

The `signing-tool` client this layer fetches from PyPI is licensed separately
by Laavat Oy; see its own licence.
