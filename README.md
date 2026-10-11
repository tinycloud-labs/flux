# `homelab/flux`

![Kustomize Build](https://github.com/tinycloud-labs/flux/actions/workflows/kustomize-build.yml/badge.svg) 

Managed Kubernetes deployments with FluxCD, intentionally not DRY to favor clarity over abstraction.

Automation:
- [ GitHub Action runs](https://github.com/tinycloud-labs/flux/blob/main/.github/workflows/kustomize-build.yml) `kustomize build` on PRs to catch rendering issues early.
- Renovate to update container images.
- Integrated FluxCD `Alert` and `Provider` CRDs with Discord webhooks to receive deployment and activity notifications

### Repo top-level view
```
bootstrap/           # controllers, operators, configs, etc
    ├── ...
apps/                # reusable applications definitions
    ├── ...
clusters/
    └── prod/            # monitored by a Flux instance on a K3s-prod
```
