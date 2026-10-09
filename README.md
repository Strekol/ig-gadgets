# ig-gadgets

Patched [Inspektor Gadget](https://inspektor-gadget.io/) gadgets. Upstream pinned by tag in
`IG_VERSION`, one patch file per change in `patches/`, images published to ghcr.io.

| Gadget | Patch | Adds |
|---|---|---|
| `trace_sni` | `trace_sni-endpoints.patch` | `src` / `dst` L4 endpoints of the connection carrying the ClientHello (IPv4 and IPv6), so an SNI event can be tied to its TCP connection |
| `trace_tcp` | `trace_tcp-close-bytes.patch` | `bytes_sent` / `bytes_received` on `close` events, the socket's lifetime counters (what `tcplife` reports); zero on other types |

Both are proposed upstream; a patch is deleted once a release carries it.

## Images

```
ghcr.io/strekol/ig-gadgets/trace_sni:v0.56.1-patched.1
ghcr.io/strekol/ig-gadgets/trace_tcp:v0.56.1-patched.1
```

Public, pulled anonymously like the upstream gadgets. Tag = `<IG_VERSION>-patched.<n>`; the release
workflow refuses a tag whose IG part differs from `IG_VERSION`. The images are not signed: run them
with `--verify-image=false` (or `operator.oci.verify-image: false` in the IG config).

```sh
ig run ghcr.io/strekol/ig-gadgets/trace_tcp:v0.56.1-patched.1 --verify-image=false
```

## Release

Push a `v<ig>-patched.<n>` tag: `.github/workflows/release.yml` checks the tag, runs `make check`
and `make build`, then `make push` with the job's `GITHUB_TOKEN`, and fails unless
the images are anonymously pullable. Pull requests and `develop` run
`pre-commit` and `make check` (`.github/workflows/check.yml`).

## Local

```sh
make check                      # patches apply on the pinned upstream
make build                      # ig image build via the upstream builder container (docker), then verify
make build TAG=v0.56.1-dev      # default tag is <IG_VERSION>-dev
make verify                     # export under build/oci/, patched fields present
make push AUTH_FILE=<file>      # ig image push to IMAGE_BASE/<gadget>:TAG
```

Needs `ig` (release binary, same version as `IG_VERSION`), docker, curl, git and GNU tar.
`make build` sets the images' `org.opencontainers.image.source` to this repository
(`SOURCE_URL`). `make push` takes its credentials from `AUTH_FILE` (docker-style `config.json`),
else from `/var/lib/ig/config.json`, else from `~/.docker/config.json`.

Runtime check of a built gadget, from the ig container (root in the container, docker daemon
access):

```sh
ig image export <image> gadgets.tar
docker run --rm -v igstore:/var/lib/ig -v $PWD:/work ghcr.io/inspektor-gadget/ig:v0.56.1 image import /work/gadgets.tar
docker run --rm --privileged --pid=host --net=host -v /:/host -v /sys/kernel/debug:/sys/kernel/debug \
  -v /sys/fs/bpf:/sys/fs/bpf -v /run:/run -v igstore:/var/lib/ig \
  ghcr.io/inspektor-gadget/ig:v0.56.1 run <image> --verify-image=false -o json --timeout 30
# meanwhile: docker run --rm curlimages/curl -sS -o /dev/null https://example.com
```

## Bumping IG

1. `IG_VERSION` and `IG_SHA256_AMD64` in `.github/workflows/release.yml` (from the release's
   `SHA256SUMS`).
2. `make check`; rework a patch that no longer applies.
3. Tag `v<ig>-patched.1`.
