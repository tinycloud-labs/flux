# `homelab/flux`

![Kustomize Build](https://github.com/tinycloud-labs/flux/actions/workflows/kustomize-build.yml/badge.svg) 

Managed Kubernetes deployments with FluxCD using a simple base/overlay, app-centric structure.

Each app has its own base and overlays so things stay easy to follow. Some parts are intentionally not DRY to favor clarity and locality over abstraction. For example: when working in `apps/foo/` everything I need should be easy to follow without mentally reconstructing how it's wired.

Release dependencies are handled with Flux Kustomize. Bootstrap stuff goes first, then the apps. Monitoring has its own order too: bootstrap -> Prometheus -> Grafana -> Loki.

Automation:
- [ GitHub Action runs](https://github.com/tinycloud-labs/flux/blob/main/.github/workflows/kustomize-build.yml) `kustomize build` on PRs to catch rendering issues early.
- Renovate to update container images.

### Repo top-level view
```
bootstrap/           # controllers, operators, configs, etc
    ├── ...
apps/                # reusable applications definitions
    ├── ...
clusters/            # environment-specific wiring
    ├── dev/             # monitored by a Flux instance on a K3s-dev
    └── prod/            # monitored by a Flux instance on a K3s-prod
```

### `apps/` organization

- Bases are reusable and not environment aware
- Overlays are environment specific

```
apps/
├── app-foo/
│   ├── base/
│   │   ├── values.yaml        # generic Helm values
│   │   ├── release.yaml       # flux release manifest
│   │   └── kustomization.yaml
│   └── overlays/
│       ├── dev/
│       │   ├── patch.yaml          # env-specific Helm values 
│       │   └── kustomization.yaml
│       └── prod/
│           ├── patch.yaml          # env-specific Helm values 
│           └── kustomization.yaml
└── ...
```

### `clusters/` organization

Each cluster call the needed releases

```
clusters/
└── prod/
    ├── flux-system/
    └── apps/
        ├── kustomization.yaml     # calls the apps from /apps
        └── common-patch.yaml      # applies cluster-specific params
```
