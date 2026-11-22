#!/usr/bin/env bash
#
# Validates the Flux manifests of a cluster without needing a running cluster.
#
#   1. Every YAML file in the repo parses.
#   2. Starting at the cluster path, every Flux Kustomization is rendered with
#      `flux build kustomization`, the same way kustomize-controller would.
#      Child Kustomizations found in the output are rendered too, so the whole
#      tree is covered (e.g. monitoring -> monitoring-prometheus).
#   3. Everything rendered is checked against Kubernetes and CRD schemas.
#   4. Every dependsOn and HelmRelease chart source points to an object that
#      exists in the rendered output.
#
# HelmRelease charts themselves are rendered by flate in CI.
#
# Requires: git, flux, yq (mikefarah, v4), kubeconform, curl, tar
# Usage:    scripts/validate.sh [cluster-path]    (default: ./clusters/prod)

set -o errexit -o nounset -o pipefail
shopt -s nullglob

cluster_path="${1:-./clusters/prod}"

# Objects that exist in the cluster but are not defined in this repo.
# The flux-system GitRepository is created by the FluxInstance (Terraform).
external_objects=(
  "GitRepository/flux-system/flux-system"
)

# Extra CRD schemas for objects that Flux's own schemas don't cover
# (VolSync, MetalLB, Prometheus Operator, ...).
crd_catalog='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

# Kinds whose schema is missing or out of date in the catalog above.
# Remove an entry once the catalog catches up.
schema_skip_kinds=(
  BitwardenSecret     # not published in the catalog
  ReplicationSource   # catalog predates VolSync 0.17 (no spec.restic.moverVolumes)
)

# Selects Flux Kustomizations (not kustomize's own kustomization.yaml files).
is_flux_kustomization='.kind == "Kustomization" and .apiVersion == "kustomize.toolkit.fluxcd.io/*"'

failed=0
fail() {
  echo "  FAIL: $*"
  failed=1
}

# All paths in Flux Kustomizations are relative to the repo root.
cd "$(git rev-parse --show-toplevel)"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
mkdir -p "$work_dir/rendered" "$work_dir/kustomizations"

echo "==> Checking YAML syntax"
while IFS= read -r file; do
  if ! yq 'true' "$file" > /dev/null 2>&1; then
    fail "$file is not valid YAML"
    yq 'true' "$file" 2>&1 >/dev/null | sed 's/^/        /' || true
  fi
done < <(git ls-files --cached --others --exclude-standard -- '*.yaml' '*.yml')

echo "==> Rendering Flux Kustomizations"
# The root Kustomization is owned by the FluxInstance, so create it here.
flux create kustomization flux-system \
  --source=GitRepository/flux-system \
  --path="$cluster_path" \
  --export > "$work_dir/kustomizations/flux-system.yml"

pending=("$work_dir/kustomizations/flux-system.yml")
while ((${#pending[@]} > 0)); do
  kustomization="${pending[0]}"
  pending=("${pending[@]:1}")

  name="$(yq '.metadata.name' "$kustomization")"
  path="$(yq '.spec.path' "$kustomization")"
  output="$work_dir/rendered/$name.yaml"
  echo "  $name ($path)"

  if [[ ! -d "$path" ]]; then
    fail "Kustomization '$name' points to $path, which does not exist"
    continue
  fi
  if ! flux build kustomization "$name" \
    --path "$path" \
    --kustomization-file "$kustomization" \
    --dry-run > "$output"; then
    fail "Kustomization '$name' failed to build"
    rm -f "$output"
    continue
  fi

  # Queue the child Kustomizations this one applies, one file per object.
  children="$work_dir/kustomizations/$name"
  mkdir -p "$children"
  (cd "$children" && yq --split-exp '.metadata.name' "select($is_flux_kustomization)" "$output")
  pending+=("$children"/*.yml)
done

rendered=("$work_dir"/rendered/*.yaml)
if ((${#rendered[@]} == 0)); then
  fail "nothing was rendered"
  exit 1
fi

echo "==> Validating schemas"
# Use the CRD schemas published with the installed Flux version.
flux_version="$(flux version --client -o yaml | yq '.flux')"
flux_schemas="$work_dir/flux-schemas"
mkdir -p "$flux_schemas/master-standalone-strict"
curl -sSfL "https://github.com/fluxcd/flux2/releases/download/$flux_version/crd-schemas.tar.gz" |
  tar -xzf - -C "$flux_schemas/master-standalone-strict"

skip_list="$(IFS=,; echo "${schema_skip_kinds[*]}")"
if ! kubeconform -strict -summary \
  -skip "$skip_list" \
  -schema-location default \
  -schema-location "$flux_schemas" \
  -schema-location "$crd_catalog" \
  "${rendered[@]}"; then
  fail "schema validation failed"
fi

echo "==> Checking references"
# Every object as "Kind/namespace/name", plus the ones that live outside the repo.
inventory="$work_dir/inventory.txt"
{
  yq --no-doc '.kind + "/" + .metadata.namespace + "/" + .metadata.name' "${rendered[@]}"
  printf '%s\n' "${external_objects[@]}"
} | sort -u > "$inventory"

# Every reference as "<target> <referrer>". A missing namespace means "same
# namespace as the referrer", which is how Flux resolves it.
# $ns and $name inside the yq expressions are yq variables, not shell ones.
references="$work_dir/references.txt"
# shellcheck disable=SC2016
{
  # Flux Kustomization -> the source it builds from
  yq --no-doc "select($is_flux_kustomization)
    | .metadata.namespace as \$ns
    | .spec.sourceRef.kind + \"/\" + (.spec.sourceRef.namespace // \$ns) + \"/\" + .spec.sourceRef.name
      + \" Kustomization/\" + \$ns + \"/\" + .metadata.name" "${rendered[@]}"

  # Flux Kustomization -> the Kustomizations it waits for
  yq --no-doc "select($is_flux_kustomization)
    | .metadata.namespace as \$ns
    | .metadata.name as \$name
    | .spec.dependsOn[]?
    | \"Kustomization/\" + (.namespace // \$ns) + \"/\" + .name
      + \" Kustomization/\" + \$ns + \"/\" + \$name" "${rendered[@]}"

  # HelmRelease -> the repository its chart comes from
  yq --no-doc 'select(.kind == "HelmRelease")
    | .metadata.namespace as $ns
    | .spec.chart.spec.sourceRef as $src
    | select($src != null)
    | $src.kind + "/" + ($src.namespace // $ns) + "/" + $src.name
      + " HelmRelease/" + $ns + "/" + .metadata.name' "${rendered[@]}"

  # HelmRelease -> the HelmReleases it waits for
  yq --no-doc 'select(.kind == "HelmRelease")
    | .metadata.namespace as $ns
    | .metadata.name as $name
    | .spec.dependsOn[]?
    | "HelmRelease/" + (.namespace // $ns) + "/" + .name
      + " HelmRelease/" + $ns + "/" + $name' "${rendered[@]}"
} > "$references"

while read -r target referrer; do
  if ! grep -qxF "$target" "$inventory"; then
    fail "$referrer refers to $target, which is not defined"
  fi
done < "$references"
echo "  $(wc -l < "$references" | tr -d ' ') references checked"

if ((failed)); then
  echo "==> Validation failed"
  exit 1
fi
echo "==> All checks passed"
