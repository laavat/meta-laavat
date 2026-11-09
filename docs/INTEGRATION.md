# Integrating meta-laavat into an existing build

You already have a Yocto build for your board that works. This guide adds
signing to it: the build submits an artifact to the LAAVAT Signing Solution,
waits for approval, checks the digest, and installs the signed result. Nothing
else about your build changes.

[README.md](../README.md) is the reference manual - every variable and the
exact verification rules. This guide is the
walkthrough, and links there rather than repeating it.

## What actually happens during a build

Signing is an ordinary bitbake task, `do_laavat_sign`, flagged `[network] = "1"`
and placed in the recipe's task graph between the task that produces the artifact
and the one that consumes it. When it runs it:

1. **uploads** the artifact and opens a signing request against a product and an
   operation, authenticated by a bearer token read from a file;
2. **waits** for approval - self-approved with an approver token, or blocked up to
   `LAAVAT_SIGN_TIMEOUT` while a human approves (four-eyes);
3. **downloads** the signed result from the presigned URL the service returns;
4. **verifies** two digests - that the download is what the service says it
   produced, and that it covers the file you actually submitted - and only then
   writes the output path.

Any failure at any step leaves that output path **absent**. There is no unsigned
fallback, so a build cannot quietly ship an unsigned artifact.

The one way to build without an account is to ask for it: `LAAVAT_SIGN_SKIP`
set to anything makes every task above say what it is not doing and stand down,
the deploy steps install nothing, and the FIT is anchored to a throwaway key so
the build still completes. It warns at each step and produces unsigned output,
so it belongs in an evaluation build and nowhere near a release. `make
skip-smoke` in [meta-laavat-testbed](https://github.com/laavat/meta-laavat-testbed)
is what keeps that path working.

The private key never leaves the service. Where an integration must embed a
*verification* key (OP-TEE's TA anchor, U-Boot's FIT key), that public half is
fetched during the build and pinned by digest, so a rotated key breaks the build
instead of silently becoming the new anchor.

## The whole integration, on one page

Each target is a class you `inherit` from a bbappend on a recipe you already
have. Sections 5 to 8 are the detail; this is the shape:

| Target | Inherit from | On top of the `inherit` you supply |
|---|---|---|
| Boot image, HABv4 (i.MX6, i.MX8M) | your boot recipe (`imx-boot`) | `LAAVAT_HAB_DEPLOY_NAME`, and `LAAVAT_HAB_IMAGE` only if the machine builds several - section 5 |
| Boot image, AHAB (i.MX93, i.MX8QM) | your boot recipe (`imx-boot`) | `LAAVAT_AHAB_IMAGE`, required here - section 5b |
| Kernel FIT | your kernel recipe **and** your u-boot recipe | nothing; `LAAVAT_FIT_PUBKEY_SHA256` goes in your config |
| RAUC bundle | your bundle recipe | nothing |
| RAUC device keyring | the recipe owning `/etc/rauc` (`rauc-conf`) | `LAAVAT_RAUC_CA_SHA256` |
| OP-TEE TAs | `optee-os` | nothing; `LAAVAT_PUBKEY_SHA256` goes in your config |
| Xilinx `BOOT.bin` | `xilinx-bootbin` | nothing on a stock meta-xilinx machine - section 9b |

Everything else - product and operation ids, the API URL, token paths - is
configuration, not code, and is the same for every target (sections 3 and 4).

Four of those seven need **only** the `inherit`. The boot image is the one with
real work in it, because its input is a file whose name your BSP may not put in
any variable; section 5 covers how to find it, and section 5b covers why the
AHAB parts make you name it yourself.

## Before you start

- A build that builds. `bitbake <your-image>` succeeds today.
- From whoever runs your LAAVAT service: the API URL, a token for a user in
  the requester group, and - per signing target - a product UUID, an operation
  UUID, and the operation's name.
- Network from the build machine to that URL. Signing happens during the
  build, not after it.

You do not need to change how you fetch layers, which distro you use, or how
you run bitbake.

## 1. Add the layer

A *layer* is a directory of recipes and configuration that bitbake includes.
Adding this one changes nothing until a recipe uses it.

Put `meta-laavat` beside your other layers, however you vendor layers today,
then:

    bitbake-layers add-layer /path/to/meta-laavat

Success: `bitbake-layers show-layers` now lists `laavat`, and your next
`bitbake` parse is clean.

With [kas](https://kas.readthedocs.io/), add it as a repo entry in a
*fragment* - a small YAML file merged into your build config - instead:

    repos:
      meta-laavat:
        path: layers/meta-laavat

Success: after `kas checkout`, `build/conf/bblayers.conf` names it.

Your own glue layer - the one holding the bbappends from sections 5 to 8 -
is an ordinary layer. If you have never written one, `bitbake-layers
create-layer` scaffolds it; the whole of `conf/layer.conf` needs to be no more
than:

    BBPATH .= ":${LAYERDIR}"
    BBFILES += "${LAYERDIR}/recipes-*/*/*.bb ${LAYERDIR}/recipes-*/*/*.bbappend"
    BBFILE_COLLECTIONS += "myglue"
    BBFILE_PATTERN_myglue = "^${LAYERDIR}/"
    BBFILE_PRIORITY_myglue = "10"
    LAYERDEPENDS_myglue = "core"
    LAYERSERIES_COMPAT_myglue = "scarthgap"

One trap if you gate a bbappend on a BSP that is not always present: bitbake
treats a `.bbappend` matching no recipe as an **error**, not a no-op, so such an
append belongs in `BBFILES_DYNAMIC` keyed on that layer's collection rather than
in `BBFILES`.

`meta-laavat` itself needs `core` and `meta-python` (from meta-openembedded),
and declares `LAYERSERIES_COMPAT` for scarthgap (5.0 LTS), styhead (5.1), walnascar (5.2),
whinlatter (5.3) and wrynose (6.0). On any other series bitbake refuses to parse and says
so, naming `LAYERSERIES_COMPAT`.

What "supported" means differs across that list, and the test-bed's
[`docs/yocto-matrix.md`](https://github.com/laavat/meta-laavat-testbed/blob/main/docs/yocto-matrix.md)
is the full account: 5.0 is the one proven end to end against a live service and a booted device; the
rest are verified by parsing the QEMU tier and by task wiring. 5.3 additionally builds
u-boot green, and needs the 5.3-only FIT split - `laavat-fitimage` on
`linux-yocto-fitimage` rather than `laavat-fitkey` on the kernel.

## 2. Get a client the class can use

`laavat-sign.bbclass` requires **signing-tool >= 3.9.2**. The classes call
`imagesigning pack`, `unpack`, `hab-request` and `sign`, and none of those verbs
exists before 3.9.2 - 3.9.1 offers only `add`, `approve`, `get`, `getall` and
`getapprovals`.

The recipe in this layer is 3.11.0, so the client the build uses already
has them. If the build still stops in the first signing task, something
overrode the version down - `laavat_require_client` says so rather than
argparse's `invalid choice`.

Success: `signing-tool imagesigning sign --help` exists. That is the check the
classes make, and it is the one that matters - `PV` can say anything.

To build a client of your own instead - a pre-release, or a fork - add a recipe
with your `PV` and select it. The string has to match that `PV` exactly:

    PREFERRED_VERSION_signing-tool = "<your PV>"
    PREFERRED_VERSION_signing-tool-native = "<your PV>"

## 3. Point the build at the service

Put the token in a file readable only by the build user. The token itself
never enters bitbake - only the file's path does.

    printf '%s' "$TOKEN" > ~/.laavat-token && chmod 600 ~/.laavat-token
    export LAAVAT_TOKEN_FILE=~/.laavat-token
    export BB_ENV_PASSTHROUGH_ADDITIONS="$BB_ENV_PASSTHROUGH_ADDITIONS LAAVAT_TOKEN_FILE LAAVAT_APPROVER_TOKEN_FILE"

bitbake empties the task environment and repopulates it from what it was told
to keep, so the passthrough line is not optional. The alternative is to name
the path in `local.conf` instead, which is what
[meta-laavat-testbed](https://github.com/laavat/meta-laavat-testbed) does:

    LAAVAT_API_URL = "https://signing.example.com/api/v1"
    LAAVAT_TOKEN_FILE = "/build/laavat/token-writer.jwt"

If the service uses a private CA, point the client at the bundle from
`local.conf`. The `export` keyword is required - the client reads it out of
the task environment, not out of bitbake:

    export REQUESTS_CA_BUNDLE = "/build/laavat/ca.crt"

**Never disable TLS verification.** The client has a flag for it; leave it
unused. A CA bundle is the fix.

Setting `LAAVAT_APPROVER_TOKEN_FILE` makes the build approve its own request.
Unset it to keep approval separate: the build then waits for a human approver, up to
`LAAVAT_SIGN_TIMEOUT` (1800 s). Production setups typically keep approval
separate (four-eyes).

Success: the first call in section 4 returns your products. If that fails from this
machine with this token, no bitbake wiring will fix it.

## 4. Find your product and operation ids

Two client calls give you every id you need. Run them wherever `signing-tool`
is installed - a host `pip install`, or `bitbake signing-tool-native -c devshell`:

    signing-tool -c -a "$URL" -t @"$TOKENFILE" product getall
    signing-tool -c -a "$URL" -t @"$TOKENFILE" product get -P <product-id>

The first lists products with their UUIDs; the second lists that product's
operations with theirs. Each signing target needs one `LAAVAT_PRODUCT_ID`, one
`LAAVAT_OPER_ID`, and the operation *name* for `LAAVAT_SIGN_OPERATION`
(`SignHAB`, `SignKernel`, ...), which is a `signing-tool imagesigning add`
subcommand. The name and the id must agree - the service rejects a mismatch,
this layer does not.

Different targets usually mean different operations and sometimes different
products, so set the ids per recipe rather than globally. With kas that is a
`:pn-` override.

## 5. Sign the boot image (i.MX HAB)

HAB is the i.MX boot ROM's signature check. Each boot stage begins with an
IVT (a small header) that points at a CSF (the block holding the signature the
ROM verifies).

**A multi-container boot image must use `hab-archive-v1`.** File-mode
`SignHAB` handles single-container images only: given an i.MX8M `flash.bin` it
signs and returns the first (SPL) container, which passes the digest check but
is not a bootable image. Archive mode returns the whole image with a CSF
patched in per stage, and it is what `laavat-hab` uses.

Wire it in a bbappend on your BSP's boot recipe (`imx-boot` on NXP and
Variscite BSPs). A *bbappend* is a file that adds to a recipe someone else owns
without editing it: name it `<recipe>_%.bbappend` and put it in a layer of your
own that is listed in `bblayers.conf`.

`laavat-hab.bbclass` carries the whole mechanism - finding the binary, building
`request.json`, reading each stage's IVT block back out of it, signing the
archive and staging the result. On a Variscite BSP the entire integration is one
board fact:

    inherit laavat-hab
    LAAVAT_HAB_DEPLOY_NAME = "${UUU_BOOTLOADER}"     # deployed <name>.laavat-signed

**You do not normally have to say which file to sign.** With
`LAAVAT_HAB_IMAGE` unset the class takes the one file under `${S}` that begins
with a HAB IVT, and says which it picked. That default exists because most BSPs
do not publish the name: of three i.MX BSPs surveyed only Variscite does
(`BOOT_IMAGE_SD`), while `meta-freescale` composes it in task shell -

    cp ${BOOT_STAGING}/flash.bin ${S}/${BOOT_CONFIG_MACHINE_EXTRA}-${target}

- with `BOOT_CONFIG_MACHINE_EXTRA` local to the task, and `meta-phytec`
composes it in task python. There is nothing to reference on either, so
reconstructing it by hand was the most error-prone step in an integration.

**When your machine builds more than one boot image**, the class will not guess.
Phytec's `phyboard-polis-imx8mm-5` sets `UBOOT_CONFIG ??= "fspi sd"` and
`IMXBOOT_TARGETS = "flash_evk flash_evk_flexspi"`, so it produces several, and
only you know which one ships. The build then fails naming each candidate
exactly, ready to paste:

    LAAVAT_HAB_IMAGE = "${S}/imx-boot-phyboard-polis-imx8mm-5-sd.bin-flash_evk"

Set it as a literal, or with the variables the BSP's own task code uses - but
note that a bare `${UBOOT_CONFIG}` is wrong on such a machine, because it holds
a list and the deployed image is built from the *first* entry.
`LAAVAT_HAB_SEARCH_DIR` moves the search if your BSP builds somewhere other than
`${S}`. `LAAVAT_ARCHIVE_MEMBER` (the binary's name inside the archive) defaults
to `flash.bin`.

`UUU_BOOTLOADER` is meta-freescale's rather than Variscite's, so the deploy-name
half usually ports across i.MX BSPs unchanged.

The request is generated, not written: one CSF per named stage, the first
`hab4-spl` with `authenticate.auto` and every later one authenticating the
block read out of its own IVT. That covers each stage's header region, which is
all an IVT describes.

**`LAAVAT_HAB_STAGES` selects IVTs in file order, it does not merely count
them.** The default is `SPL UBOOT`, and an i.MX8M `flash.bin` carries *three*
IVTs: imx-mkimage emits two overlapping descriptors for the u-boot FIT, same
start and different lengths (measured on an i.MX8MM image: offset `0x57C00`
for `0x1020`, and again for `0x3020`). Only one of the two can be signed,
because the longer region contains the shorter one's CSF area and would
authenticate a signature written after its own hash was taken. So two stages
sign IVTs 0 and 1; any IVT no stage claims gets a build warning naming its
offset, rather than being dropped in silence.

**When you need a request the generated shape cannot express**, write
`request.json` by hand and inherit `laavat-sign` directly instead of
`laavat-hab` - whose pack task always renders over `LAAVAT_ARCHIVE_REQUEST`, so
it would overwrite yours:

    inherit laavat-sign
    LAAVAT_SIGN_PAYLOAD = "hab-archive-v1"
    LAAVAT_SIGN_OPERATION = "SignHAB"
    LAAVAT_ARCHIVE_REQUEST := "${THISDIR}/files/request.json"

Use `:=`, or `${THISDIR}` expands to the class's directory rather than yours.
The case that needs one is a FIT stage that also authenticates its sub-images
(u-boot, dtb, ATF), whose file offsets need a FIT parse - take those from
`make print_fit_hab`.

The addresses are read back out of the image rather than pasted in because
they are properties of the binary your build just produced, not of the recipe:
where each IVT sits, and how many stages the image really has, is knowable only
by reading it. Encoding comes from `request.json`'s `outputEncoding`; the stored
encoding is ignored here. The class installs into `${DEPLOYDIR}`, not `${DEPLOY_DIR_IMAGE}`
- see the sstate rule in section 10.

Run it, naming the task:

    bitbake imx-boot -c laavat_sign

Success:

    NOTE: rendered .../laavat/request.json
    NOTE: submitted signing request 3d2c8a34-...
    NOTE: signed .../laavat/flash.bin.laavat-signed (request 3d2c8a34-...)

The last line carries no sha256 because archive mode checks the digest over the
archive and each binary inside it, not over one file.

The generated request covers each signed stage's IVT header block, which is
what the IVTs carry. A production request adds the FIT sub-image blocks
(U-Boot, dtb, ATF) from `make print_fit_hab`, which is what the hand-written
request above is for.

### 5b. AHAB parts (i.MX93, i.MX8QM)

From i.MX93 on, the boot ROM checks **AHAB** rather than HABv4: signed
containers through SPSDK, not IVTs and CSFs through CST. Different format,
different tooling, so none of the mechanism in section 5 applies - no IVT
reading, no `request.json`, no stages. What it shares with every other target
is the shape: upload one file, get one signed file back. The operation is
`SignSPSDK`, and `laavat-ahab` is that wiring already done:

    inherit laavat-ahab
    LAAVAT_AHAB_IMAGE = "${S}/imx-boot-${MACHINE}-sd.bin-flash_singleboot"
    LAAVAT_AHAB_DEPLOY_NAME = "${UUU_BOOTLOADER}"     # deployed <name>.laavat-signed

**`LAAVAT_AHAB_IMAGE` is required**, which is the one place this differs from
section 5. `laavat-hab` can pick the boot image out of `${S}` because a HABv4
IVT is recognisable by its header; recognising an AHAB container is not
implemented, and guessing wrong would sign the wrong artifact. These BSPs build
several boot images from one recipe - `imx93evk` sets `IMXBOOT_TARGETS =
"flash_singleboot flash_singleboot_gdet flash_singleboot_gdet_auto"`, so
`imx-boot` writes three, `gdet` being the glitch-detector variant - and only
you know which one ships.

`LAAVAT_AHAB_DEPLOY_NAME` defaults to `UUU_BOOTLOADER`, which only
meta-freescale's own machines set. On a machine that does not set it, leaving it
empty is refused rather than deploying the signed image as `.laavat-signed` - a
dotfile, deployed successfully, sitting invisibly beside the unsigned original
that nothing replaced.

AHAB is proven at build time only: no emulator in the test-bed models an i.MX boot ROM, so
what is verified is that the image the service returns is the signed form of the
one submitted.

## 6. Sign the FIT kernel image, and anchor U-Boot to the service

**Which class depends on your Yocto release.** Up to 5.2 the FIT is built by
`kernel-fitimage.bbclass` on the kernel recipe. Yocto 5.3 replaced that with
`kernel-fit-image.bbclass` and moved the FIT into its own recipe, so the hooks
the old class used (`do_assemble_fitimage`, `do_kernel_generate_rsa_keys`,
`fitImage-none`) no longer exist:

| Yocto | inherit | on which recipe |
| --- | --- | --- |
| <= 5.2 | `laavat-fitkey` | your kernel recipe |
| >= 5.3 | `laavat-fitimage` | `linux-yocto-fitimage` |

The u-boot half is `laavat-fitkey-uboot` on both, unchanged. `laavat-fitkey`
fails at parse time on 5.3 with a message naming the replacement.

`SignKernel` rewrites the FIT's configuration signature nodes with the
product's key. On its own that is half a chain of trust: U-Boot verifies the
kernel against whatever public key sits in its control device tree, and while
that is still your build's dev key, the service's signature is never checked
and the boot is not anchored to anything the service holds.

`laavat-fitkey` does both halves, and does them through machinery poky already
has. poky keeps one invariant - a single key directory both signs the FIT and
supplies the public key written into the control device tree, so the two always
match. The service breaks it in exactly one place: the private half never
leaves the HSM. So the class establishes a different invariant instead:

> the key directory holds the **service's certificate** and a **placeholder**
> private key. Every local signature is provisional; `SignKernel` replaces it
> before anything reads the artifact. The key in the device tree is the
> service's, and is final.

The placeholder key exists only because poky signs unconditionally and refuses
to build without one. It signs nothing that survives.

Requires `kernel-fitimage` in `KERNEL_CLASSES` and `UBOOT_SIGN_ENABLE = "1"`;
both are checked at parse time, by name.

In a bbappend on your **kernel** recipe:

    inherit laavat-fitkey

and in a bbappend on your **u-boot** recipe:

    inherit laavat-fitkey-uboot

Both halves are required. poky splits FIT signing across the two recipes: the
kernel assembles and signs the image, and u-boot writes the public key into the
control device tree while re-signing the copy it verifies. That re-signing
would use the placeholder key and destroy the service's signature, so the
u-boot half substitutes an inject-only step.

Then, in your configuration:

    LAAVAT_PRODUCT_ID:pn-<your-kernel> = "<product uuid>"
    LAAVAT_OPER_ID:pn-<your-kernel>    = "<operation uuid>"
    LAAVAT_FIT_PUBKEY_SHA256 = "<sha256 of the DER SubjectPublicKeyInfo>"

`LAAVAT_FIT_PUBKEY_SHA256` is deliberately *not* per-recipe: both halves read
it, and the u-boot recipe cannot see a `:pn-<kernel>` override. Get the value
once, by hand, so that a rotated key breaks the build rather than silently
becoming the anchor of everything the product will ever boot:

    signing-tool -c -a "$LAAVAT_API_URL" -t "@$TOKENFILE" \
        product getpubkey -P <product> --operid <oper> -O k.pem
    openssl pkey -pubin -in k.pem -outform DER | sha256sum

### Machines with no control device tree of their own

Some machines take their control device tree from the platform rather than
appending one - `qemuarm64-secureboot` sets `OF_BOARD`, and U-Boot then builds
no `u-boot.dtb` at all. There is nothing to inject into, and poky reports this
as a *warning* while the build succeeds: "Failure while adding public key to
u-boot binary. Verified boot won't be available." A green build with an
unverified kernel is the failure this layer exists to prevent, so the class
turns it into an error.

If that is genuinely your machine, say so, and carry the key to U-Boot by
whatever supplies the device tree:

    LAAVAT_FIT_REQUIRE_CONTROL_DTB = "0"

### A bundled initramfs

`INITRAMFS_IMAGE_BUNDLE = "1"` is refused, and the refusal is deliberate.

With it set, poky does not sign the FIT you think it does. `kernel-fitimage`
assembles a *second* image - `fitImage-bundle`, with the initramfs inside it,
built by `do_assemble_fitimage_initramfs` - points `fitImage` at that one, and
skips installing `fitImage` in `do_install` altogether. The service would sign
`fitImage-none`, which in that configuration reaches nothing: the image the
device boots keeps the placeholder signature, the build stays green, and the
device refuses every kernel you give it.

Build the initramfs as its own image (`INITRAMFS_IMAGE` without
`INITRAMFS_IMAGE_BUNDLE`) and the FIT the service signs is the FIT that boots.
On Yocto 5.3 and later `laavat-fitimage` is unaffected: `kernel-fit-image`
builds exactly one image, at `${B}/fitImage`, and deploys it either way.

### rm_work

Exclude the kernel: the signed FIT is read from and written into the kernel
workdir, which `rm_work` would delete while the stamps still say the tasks are
done.

    RM_WORK_EXCLUDE += "linux-<your-kernel>"

Success, in the kernel's log:

    NOTE: public key .../fit-pub.pem pinned to e893c44f...
    NOTE: submitted signing request 1903a480-...
    NOTE: installed the service-signed FIT over .../fitImage-none

and in u-boot's, two different assurances that are worth telling apart. The class
asserts that the key really landed in the control device tree - it greps the
signed DTB for the key name and makes a failed injection fatal, where poky would
downgrade it to a warning and ship a green build:

    NOTE: u-boot control device tree .../u-boot.dtb-signed carries laavat and its key material

That is a check on the *anchor*. The check on the *signature* is poky's own
`UBOOT_FIT_CHECK_SIGN`, which runs inside `concat_dtb` and verifies the service's
signature against the service's key - the line that makes the chain meaningful:

    Verifying Hash Integrity ... sha256,rsa2048:laavat+ OK

## 7. Sign the RAUC bundle

This is RAUC's own recommended shape: `rauc bundle` signs with a cheap dev
key, then a separate step re-signs the finished bundle with the real one.
Nothing pushes a PKCS#11 URI through `do_bundle`.

The RAUC operations do not take a bare `.raucb`. The payload is a `.tar.gz` of
a `request.json` plus the bundle - the service untars every RAUC payload and
fails when it finds no `request.json`. See
[Sign the boot image (i.MX HAB)](#5-sign-the-boot-image-imx-hab), which is the worked example of one.

`laavat-rauc.bbclass` does the packing, the signing and the staging. On the
bundle recipe that is the whole integration:

    inherit laavat-rauc

The request it builds is one line -
`{"format": "verity", "resign": true, "inputFile": "bundle.raucb"}` - with
`format` read off `RAUC_BUNDLE_FORMAT` rather than hard-coded, so it always
matches the bundle's own manifest. The tar is built deterministically (member
`mtime` 0, gzip header with no mtime and no filename) so an unchanged bundle
resumes its pending request instead of submitting a second one, and the packing
directory sits beside `${B}` rather than in it, because `do_bundle[cleandirs]`
wipes `${B}` on every rebuild.

**The device half is separate, and it is the half that matters.**
`RaucBundleSigningWithOneTimeKey` mints a per-bundle certificate, so there is no
single signer key to pin - the device must trust the *issuing CA*. Inherit
`laavat-rauc-keyring` from the recipe that owns `/etc/rauc` (poky's `rauc-conf`)
and pin it:

    inherit laavat-rauc-keyring
    LAAVAT_RAUC_CA_SHA256 = "<sha256sum of the CA PEM>"

The pin is required: that file is the root of trust for every update the device
will ever accept, so a swapped one has to fail the build rather than silently
widen what it accepts. The class fetches it via `SRC_URI`, checks the digest
before `do_install`, and installs it as `/etc/rauc/ca.cert.pem`.

**meta-rauc can already install a keyring** - `rauc-conf` takes
`RAUC_KEYRING_URI` / `RAUC_KEYRING_FILE` and puts the file in the same place.
The *only* thing `laavat-rauc-keyring` adds is the fail-closed digest check.
Use one or the other, not both: setting `RAUC_KEYRING_URI` as well just fetches
a second file that nothing checks. If you would rather stay on meta-rauc's
mechanism, that is a legitimate choice - you are choosing to have no pin, and
a substituted CA will not be caught at build time.

**The pin guards the file, not RAUC's choice of file.** RAUC reads its keyring
path from `[keyring] path=` in `/etc/rauc/system.conf`. If that names anything
other than the file this class installs, the pinned CA sits on the device
unused and the keyring actually in force is unpinned - and nothing at build
time can see it, because `system.conf` belongs to your BSP. Check it once:

    grep -A1 '\[keyring\]' /etc/rauc/system.conf   # on the built image

and either leave it at the default `ca.cert.pem` or point
`LAAVAT_RAUC_KEYRING` at whatever your `system.conf` names.

    bitbake <your-bundle-recipe> -c laavat_sign

Success:

    NOTE: submitted signing request fbc71ea9-...
    NOTE: signed .../laavat/bundle.raucb.laavat-signed (request fbc71ea9-..., sha256 a588c8ca...)

Check it with `rauc info --keyring <the product's CA>`: it verifies, the
bundle format is preserved, and the signer is a one-time certificate minted at
signing time - the same CA `laavat-rauc-keyring` puts on the device. Verify
against your dev CA instead and the bundle passes in the build and is rejected
on the target.

## 8. OP-TEE trusted applications

`OP-TEESigning` signs OP-TEE Trusted Applications (`.ta` files) - file mode,
like section 6, except the file is a tar.gz of TAs and the result is unpacked
back in place rather than staged as-is.

**a. Turn the target on.** `MACHINE_FEATURES:append = " optee"`. Provided your
machine conf or BSP already sets the load address and DDR size OP-TEE needs,
this one line is the whole switch.

**b. Inherit the class and pin the anchor.** `laavat-optee.bbclass` is the
whole integration on the optee-os recipe:

    inherit laavat-optee
    LAAVAT_PUBKEY_SHA256 = "<sha256 of the DER SubjectPublicKeyInfo>"

It runs four tasks around the recipe's own build: `do_laavat_fetch_pubkey`
(before `do_configure`), `do_laavat_pack` (`${B}/ta/*/*.ta` into a
deterministic tar.gz), `do_laavat_sign`, and `do_laavat_unpack` (each signed
`.ta` back over its build-tree original, before the unmodified `do_install`
packages whichever files are on disk).

optee-os embeds a public key at build time and never needs the matching
private one, so the class points `TA_PUBLIC_KEY` at the fetched PEM through
`EXTRA_OEMAKE` and leaves `TA_SIGN_KEY` at optee-os's own default - whatever
it signs during the build is discarded and replaced before install. The pin is
required and fail-closed; take it once by hand, as in
[Sign the FIT kernel image](#6-sign-the-fit-kernel-image-and-anchor-u-boot-to-the-service):

    signing-tool -c -a "$LAAVAT_API_URL" -t "@$TOKENFILE" \
        product getpubkey -P <PRODUCT_ID> --operid <OPER_ID> \
        -O ta-pub.pem --fingerprint <SHA256>

The operation key must be RSA: optee-os's `pem_to_pub_c.py` emits an RSA
modulus/exponent pair and nothing else.

**Two facts about the wire format**, both already handled by the class. **The service renames
every member**: one request signs each TA in the archive and returns them as
`<name>.signed`, dropping the unsigned original - match on the raw name and
every member looks like one you never sent. And the encoding is `raw`.

The unpack is deliberately strict, because it writes over artifacts the device
will load: the archive is bounded by entry count and declared size before a
byte is read, a member nobody sent or a named TA the service did not return
fails the task, and every member is staged to a sibling `.part` before any
rename - so a rejected or short-read member cannot leave `${B}/ta` half
replaced. Same code path as `hab_archive`'s result staging
(`signingtool.archive.unpack_over`).

**Only in-tree TAs are covered.** The anchor this class installs is the
service's key, and OP-TEE's core verifies every TA it loads against that one
key. A TA built outside this build - a vendor-supplied binary, a TA from
another project, anything signed with its own key - is refused at load time by
a core anchored this way. Those TAs have to go through the same `OP-TEESigning`
operation, or the device needs a core built to trust more than one key, which
is an optee-os configuration matter and not something this layer can do for
you.

To verify a signed TA yourself, parse its header and check the signature with
`openssl pkeyutl -verify` against the fetched public key: algo `0x70414930` is
RSASSA-PSS/MGF1/SHA-256 with saltlen `-1`, and the signed data is
`header[:20] || everything after the signature`.

## 9. Other operations

`LAAVAT_SIGN_OPERATION` can name any of the file-upload subcommands
`signing-tool imagesigning add --help` lists. Most of them - `SignSPSDK`,
`SignMcuBoot` and the rest - wire up like section 6: the operation name, the two
ids and the input path change, nothing else does. `SignSPSDK` for AHAB boot
images is the one that has a class of its own - section 5b.

Two are not plain file signing, whatever the subcommand list suggests, because
what they upload is an archive:

- `OP-TEESigning` needs the pack/sign/unpack shape in section 8; `laavat-optee`
  is it.
- `SignBootgenImage` (Xilinx) needs the same shape. The archive holds a
  `request.json`, the `.bif` files it names and every partition those BIFs
  reference; the service runs bootgen against them with a key it holds and
  returns a tar.gz of the `.bin` images produced. `laavat-bootgen` builds all of
  that from the BIF the recipe already generates - see section 9b.

How the service stores the signed object (raw or base64) differs per
operation, but there is nothing to configure: signing-tool checks the reported
digest against both forms and installs the one that matches - see
[Download encoding](../README.md#download-encoding). A download that matches
neither fails the build and no output is written.

### 9b. Xilinx boot images (bootgen)

On the recipe that builds `BOOT.bin` - `xilinx-bootbin` on meta-xilinx, which
provides `virtual/boot-bin`:

    inherit laavat-bootgen

That is the whole integration on a stock meta-xilinx machine. The class reads the
BIF the recipe generates during `do_configure`, derives the partition list from
it, packs `request.json` + the BIFs + the partitions, signs, and unpacks the
returned images.

Only override these if the recipe is not stock:

    LAAVAT_BOOTGEN_ARCH        bootgen -arch value (default: the recipe's BOOTGEN_ARCH)
    LAAVAT_BOOTGEN_DIR         where the BIF and its partitions are (default: ${B})
    LAAVAT_BOOTGEN_BIFS        BIF basenames, in order (default: bootgen.bif)
    LAAVAT_BOOTGEN_OUTPUTS     the .bin each BIF produces, same order (default: BOOT.bin)

`LAAVAT_BOOTGEN_BIFS` and `LAAVAT_BOOTGEN_OUTPUTS` must correspond one to one; a
BIF produces exactly one image, and a mismatch fails the task rather than
signing the wrong pairing.

The partition list is not something you write, and it is not something this
layer interprets either. The request names the BIF and leaves `items` out,
which is what tells the service to parse the BIF itself - that parser also
understands `[fsbl_config]` lines carrying settings such as `bh_auth_enable`.
The only thing read from the BIF on this side is which files to put in the
archive beside it, and getting that wrong is loud: bootgen fails on a missing
partition rather than producing a wrongly-configured image.

## 10. Troubleshooting

**The signing task did not run, and there is no error.** Run it by name:

    bitbake <recipe> -c laavat_sign

`do_laavat_sign` is never restored from sstate (bitbake's shared-state cache
of finished task results) itself, but on an incremental build a setscene hit
(bitbake restoring a covering task's output from that cache) on a task that
*covers* it - `do_deploy` is the usual one - marks it covered and signing
never happens. Naming the task is the rule. The structural fix: stage into
`${DEPLOYDIR}` so the signed file travels inside `do_deploy`'s sstate package,
or order the task so nothing sstate-backed covers it.

**`LAAVAT_TOKEN_FILE must point at a readable token file; add it to
BB_ENV_PASSTHROUGH_ADDITIONS`.** The variable is set in your shell but bitbake
dropped it. section 3.

**`<VARIABLE> must be set to use laavat-sign`.** A required variable is
missing for this recipe. In archive mode the required input variable is
`LAAVAT_ARCHIVE_REQUEST`, not `LAAVAT_SIGN_INPUT`.

**`no HAB image found under ...`** or **`several files begin with a HAB IVT`**.
`laavat-hab` finds the boot image by reading IVT headers rather than by
trusting a BSP variable, because only Variscite publishes one. When the search
finds nothing or cannot choose, set `LAAVAT_HAB_IMAGE` to the file you mean.
The check exists so a wrong answer fails loudly rather than signing nothing.

**`digest mismatch for <request>: expected ..., got ...`.** The artifact the
service returned is not the one it reported, in either storage encoding - so
this is a corrupted or substituted download rather than a configuration
mistake. Nothing was installed. Re-run; if it repeats, the request is worth
looking at server-side before spending another approval.

**The build is green but the board does not boot.** If this is a
multi-container i.MX image signed in file mode, you were handed the first
container only. section 5.

**`submitting the signing request failed (exit ...)`** with an authorization
error from the service. The token expired - they are short-lived. Mint a new
one into the same path and re-run; the pending request is resumed, not
duplicated.

**The task waited and then timed out.** The request is still alive. Approve it
and re-run the task: `NOTE: resuming signing request <id>` means the same
request was picked up rather than a duplicate created. Raise
`LAAVAT_SIGN_TIMEOUT` if human approval routinely takes longer.

**With kas: a variable you set is being ignored.** kas emits
`local_conf_header` sections in alphabetical key order, so a section whose key
sorts later wins on plain assignments. Name your section accordingly, or use
`:pn-` overrides, which win regardless of order. Naming the section `live`,
which sorts after most feature keys, is one way to do it.
