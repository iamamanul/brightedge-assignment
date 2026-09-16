# data-sync Helm Chart

Universal Helm chart for packaging and deploying the `data-sync` FastAPI microservice across staging and production Kubernetes environments.

## Chart Manifest Structure

| File | Purpose |
|---|---|
| `templates/deployment.yaml` | Application lifecycle, container ports, rolling updates, ConfigMap mounts, probes, and checksum annotations. |
| `templates/configmap-nginx.yaml` | Nginx configuration for JSON `/health` and Prometheus `/metrics` responses. |
| `templates/service.yaml` | Internal ClusterIP service. |
| `templates/hpa.yaml` | CPU-based HorizontalPodAutoscaler. |
| `templates/configmap.yaml` | Non-sensitive environment variables. |
| `templates/secret.yaml` | Sensitive runtime credentials such as `REDIS_PASSWORD`. |
| `templates/pdb.yaml` | Minimum available replicas during voluntary disruptions. |
| `templates/servicemonitor.yaml` | Prometheus Operator scrape configuration for `/metrics`. |

## Endpoint Emulation Engine

The chart uses `nginx:1.27-alpine` as a lightweight runtime stand-in and mounts a custom virtual host:

- Liveness and readiness probes call `GET /health`, which returns HTTP 200 and `{"status":"ok"}`.
- Prometheus scrapes `GET /metrics`, which returns valid exposition text.

Update `image.repository` and `image.tag` for the production Python/FastAPI image. The stand-in and application contract both use port `8080`.

## Observability Verification

The repository includes captured monitoring evidence for the chart configuration:

- [Grafana data-sync overview dashboard](../../../monitoring/screenshots/dashboard.png)
- [Prometheus targets](../../../monitoring/screenshots/prometheus-targets.png)
- [Exportable Grafana dashboard JSON](../../../monitoring/dashboards/data-sync-overview.json)

The screenshots verify the dashboard view and that Prometheus can discover the configured scrape target. In a live cluster, confirm the same state with the Prometheus and Grafana instances installed for that environment.

## Secret handling

Values files contain `REPLACE_ME` placeholders so linting and template rendering work without real credentials. **Never commit a real password.** In production:

- Use External Secrets Operator to sync `REDIS_PASSWORD` from GCP Secret Manager or AWS Secrets Manager, or
- Pass it at deploy time with `--set redis.password="$REDIS_PASSWORD"` from a CI secret store.

The Deployment already annotates pods with a checksum of the Secret/ConfigMap
content, so any password rotation automatically triggers a rolling restart
without anyone needing to `kubectl rollout restart` by hand.

## Redis Dependency

Redis is referenced as an external or managed dependency. A production setup may add the `bitnami/redis` sub-chart or use a managed Redis service.

## Install / upgrade commands

### Prerequisites (local kind cluster)

```bash
# one-time: install helm if you don't have it
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# optional but recommended for the ServiceMonitor CRD to mean anything:
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace
```

### Lint & render (no cluster needed)

```bash
cd helm/charts/data-sync
helm lint . -f values.yaml -f values.staging.yaml
helm lint . -f values.yaml -f values.production.yaml
helm template data-sync . -f values.yaml -f values.staging.yaml

cd ../../..
```

### Staging

```bash
kubectl create namespace data-sync-staging --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install data-sync ./helm/charts/data-sync \
  -f ./helm/charts/data-sync/values.yaml \
  -f ./helm/charts/data-sync/values.staging.yaml \
  --namespace data-sync-staging
```

### Production

```bash
kubectl create namespace data-sync-production --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install data-sync ./helm/charts/data-sync \
  -f ./helm/charts/data-sync/values.yaml \
  -f ./helm/charts/data-sync/values.production.yaml \
  --set redis.password="$REDIS_PASSWORD" \
  --namespace data-sync-production
```

Then apply the Kustomize overlay (zone spreading + secret-checksum annotation)
on top of the rendered production manifest:

```bash
bash standard/data-sync/production/render.sh
kubectl kustomize standard/data-sync/production | kubectl apply -f -
```

### Rollback

```bash
helm history data-sync -n data-sync-production
helm rollback data-sync <REVISION> -n data-sync-production
```
