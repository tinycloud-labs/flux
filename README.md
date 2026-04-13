![Kustomize Build](https://github.com/tinycloud-labs/flux/actions/workflows/kustomize-build.yml/badge.svg) 

Managed K8s deployment with FluxCD using base/overlay app-centric structure. 

Bases and overlays are defined per application to keep deployments easy to reason about. There're some intentional non-DRY configuration to favor clarity and locality over abstraction (e.g. when working on `apps/foo/` configs, I don't want to mentally reconstruct how everything is wired together). 

bootstrapping using split-mirrors as a pattern to reuse anything that installs CRDs and then needs CRs applied

Automation:
- [ GitHub Action runs](https://github.com/tinycloud-labs/flux/blob/main/.github/workflows/kustomize-build.yml) `kustomize build` on PRs to catch rendering issues early.
- Renovate bot to update container images.
- Flux reconciliation loop.

### Repo top-level view
```
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
