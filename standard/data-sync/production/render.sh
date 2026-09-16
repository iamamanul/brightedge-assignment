#!/usr/bin/env bash
# Renders Helm chart for production and updates SECRET_CHECKSUM dynamically.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
CHART_DIR="$REPO_ROOT/helm/charts/data-sync"
OVERLAY_DIR="$REPO_ROOT/standard/data-sync/production"

HELM_SECRET_ARGS=()
if [[ -n "${REDIS_PASSWORD:-}" ]]; then
  HELM_SECRET_ARGS=(--set-string "redis.password=${REDIS_PASSWORD}")
fi

# 1. Render production manifest
helm template data-sync "$CHART_DIR" \
  -f "$CHART_DIR/values.yaml" \
  -f "$CHART_DIR/values.production.yaml" \
  "${HELM_SECRET_ARGS[@]}" \
  > "$OVERLAY_DIR/base-rendered.yaml"

# 2. Extract Secret and calculate SHA256 checksum
SECRET_CHECKSUM=$(awk '/^kind: Secret$/,/^---/' "$OVERLAY_DIR/base-rendered.yaml" | sha256sum | cut -d' ' -f1)

# 3. Dynamically patch the value on the line following the JSON patch path.
sed -i -E \
  "/path: \/spec\/template\/metadata\/annotations\/SECRET_CHECKSUM/{n;s/(value:).*/\\1 \"${SECRET_CHECKSUM}\"/;}" \
  "$OVERLAY_DIR/kustomization.yaml"

echo "Successfully rendered base-rendered.yaml and updated SECRET_CHECKSUM to: ${SECRET_CHECKSUM}"
echo "To deploy overlay: kubectl kustomize $OVERLAY_DIR | kubectl apply -f -"
