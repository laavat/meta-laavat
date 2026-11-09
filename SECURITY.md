# Security policy

## Reporting a vulnerability

Email **contact@laavat.com** with `[meta-laavat][SECURITY]` in the subject. Please do not
open a public issue or send a patch to a mailing list first.

Include the layer commit, the Yocto series, the recipe or class involved, and
what an attacker gains. We aim to acknowledge within three working days.

## What is in scope

This layer moves signing out of the build and into the LAAVAT Signing Solution,
so the failures worth reporting are the ones that let an artifact be trusted
when it should not be:

- A signed artifact installed after a failed or skipped verification - the
  digest chain in `laavat-sign.bbclass` is meant to be fail-closed, and any
  path that writes `LAAVAT_SIGN_OUTPUT` without it is a bug.
- A trust anchor that is not the one that was pinned: `laavat_fetch_pubkey` and
  `laavat-fitkey` pin the fetched key by SHA-256 of its DER
  SubjectPublicKeyInfo, and a rotated or substituted key must break the build.
- A build that succeeds while producing an unverifiable image - for example a
  failed control-device-tree injection being downgraded to a warning.
- Credential exposure: a token reaching a log, a task hash, a sstate package or
  the deployed rootfs. The classes take a token *path*, never a token.

## What is not in scope

- The service itself, and anything reachable only through its API. Report those
  to the same address, but they are not layer issues.
- Development keys in example or test-bed layers. Those are throwaway by
  construction and marked as such; they are not a finding.
- `signing-tool` defects. Report them against the client, though we will carry a
  backport patch here when one blocks the layer.

## Supported versions

Fixes go to the Yocto series named in `LAYERSERIES_COMPAT_laavat`
(`conf/layer.conf`). Older series get no updates.
