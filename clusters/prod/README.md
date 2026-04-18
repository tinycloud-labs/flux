# clusters/prod

This directory is the entrypoint Flux watches for the prod cluster. It uses Flux-native
Kustomization resources to organize releases and manage dependencies between them.

## How it works

`kustomization.yaml` is the native Kustomize entrypoint. It lists every Flux Kustomization
resource in this directory, which Flux applies to the cluster.

Each `*.yaml` file (except `kustomization.yaml`) is a Flux Kustomization resource representing
a single concern (e.g., a Helm repos, a set of custom resources). These use `dependsOn` to
express ordering so Flux do not reconcile a resource until all its dependencies
report healthy.

Each Flux Kustomization points to a dedicated directory elsewhere in the repo (e.g., under `bootstrap/`
or `apps/`) that contains its own `kustomization.yaml` that assemble the final K8s manifests
for that component.

## Dependency order

flux-system -> helm-repos -> bootstrap components (csi-driver-nfs, metallb, metallb-config) -> apps & monitoring
