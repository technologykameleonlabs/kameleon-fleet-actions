# kameleon-fleet-actions

Reusable GitHub Actions workflows canon for every KameleonLabs product.

## Why this exists

GitHub-hosted runners (`ubuntu-latest`) cost money per minute and can be blocked by billing/spending-limit failures. The KameleonLabs cluster on OVH has spare capacity. The `arc-runner` self-hosted pool plus a rootless `buildkitd` Deployment removes the dependency on GitHub-hosted runners entirely — at zero per-minute cost — and gives us persistent build layer cache across runs.

This repo holds the reusable workflows so every product (kameleonapp-lab, PadelPeak, EvaleIA, …) reuses the same canon without duplication.

## Reusable workflows

### `build-image-canon.yml`

Build (and push on push events) a Docker image using in-cluster buildkitd.

```yaml
jobs:
  build:
    uses: technologykameleonlabs/kameleon-fleet-actions/.github/workflows/build-image-canon.yml@main
    with:
      image_name: ghcr.io/technologykameleonlabs/myproduct
      dockerfile: Dockerfile
      context: .
      tag_prefix: dev
      build_args: |
        NEXT_PUBLIC_APP_URL=https://myproduct.kameleonlabs.ai
    secrets: inherit
```

On `pull_request` it does a compile-gate build (no push). On `push` to the target branch it builds and pushes to GHCR.

### `vitest-unit-canon.yml`

Run vitest unit tests on the in-cluster ARC runner.

```yaml
jobs:
  test:
    uses: technologykameleonlabs/kameleon-fleet-actions/.github/workflows/vitest-unit-canon.yml@main
    with:
      filter: '@kameleon/api'
      prisma_generate: true
      env_vars: |
        DATABASE_URL=postgresql://ci:ci@localhost:5432/ci
        BETTER_AUTH_SECRET=ci-secret-min-32-chars-not-real
```

## Infrastructure

The runner pool and buildkitd Deployment live in the OVH cluster:

| Component | Namespace | What |
|---|---|---|
| ARC controller | `arc-runners` | Listens on the GitHub Actions queue and spins up runner pods on demand |
| `arc-runner` AutoscalingRunnerSet | `arc-runners` | 0 idle → up to 8 concurrent runners |
| `buildkitd` Deployment | `buildkit-system` | Rootless BuildKit daemon with PVC layer cache |
| NetworkPolicy `buildkitd-ingress` | `buildkit-system` | Restricts buildkitd access to `arc-runners` and `arc-ops-runners` only |

Manifests live in `kameleon-fleet-bootstrap/buildkit/` and `kameleon-fleet-bootstrap/arc-runners/`.

## Per-product migration

In each product repo, replace:

```yaml
runs-on: ubuntu-latest
# steps: checkout / setup buildx / build & push ...
```

with:

```yaml
uses: technologykameleonlabs/kameleon-fleet-actions/.github/workflows/build-image-canon.yml@main
```

One PR per product migrates the build & test workflows. Zero infra configuration on the product side.

## Capacity tuning

- `arc-runner` maxRunners: edit `AutoscalingRunnerSet` in `arc-runners` namespace.
- `buildkitd` replicas: edit the Deployment in `buildkit-system`. PVC is RWO (1 replica only) — to scale, switch to RWX storage class first.
