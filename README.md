# `homelab/flux`

![Validate](https://github.com/tinycloud-labs/flux/actions/workflows/validate.yml/badge.svg)

Managed Kubernetes deployments with FluxCD, intentionally not DRY to favor clarity over abstraction.

Automation:
- [GitHub Action](https://github.com/tinycloud-labs/flux/blob/main/.github/workflows/validate.yml) validates every PR before Flux sees it:
  - [`scripts/validate.sh`](scripts/validate.sh) renders every Flux Kustomization with `flux build`, checks schemas with kubeconform, and checks that `dependsOn` and chart sources exist. Run it locally the same way.
  - [flate](https://github.com/home-operations/flate) renders every HelmRelease with its chart (`flate test hr`) and comments the rendered HelmRelease changes on the PR (`flate diff hr`).
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
