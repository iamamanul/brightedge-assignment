# Architecture, NFRs & Repository Maintenance

Required artefact #2.

## 1. System Architecture

```
                         ┌──────────────────────────┐
                         │       Kubernetes cluster  │
                         │                            │
  Client requests ───▶  │  Service (ClusterIP)      │
                  │            │               │
                         │            ▼               │
                         │  Deployment "data-sync"    │
                         │  (replicas managed by HPA) │
                         │   ├─ /health ──▶ JSON probe response
                         │   └─ /metrics ─▶ Prometheus text
                         │            │               │
                         │            ▼               │
                         │      Redis (cache)         │
                         └──────────────────────────┘

Non-container workloads:
  GCP Compute / Rocky Linux ── Ansible role ── systemd service
```

Both deployment paths share the environment contract `APP_ENV`, `REDIS_HOST`, `LOG_LEVEL`, `WORKERS`, and `MAX_CONNECTIONS`. Consistent names allow unified log ingestion, metrics aggregation, and alert thresholds across platforms.

## 2. Non-functional requirements (NFRs) and how the chart meets them

| NFR | How it's addressed |
|---|---|
| **Availability** | `PodDisruptionBudget` (minAvailable 1 staging / 2 production) prevents voluntary disruptions (node drains, cluster upgrades) from taking the service below quorum. Multiple replicas + readiness probes mean the Service only routes to pods that are actually ready. |
| **Scalability** | HPA on CPU utilization, min/max tuned per environment (1-3 default, 2-6 staging, 3-20 production). See `DESIGN.md` for why CPU-only HPA isn't sufficient at 2,000 req/s burst and what's recommended instead (KEDA on queue depth/RPS). |
| **Resilience to noisy neighbours** | Resource `requests`/`limits` are set per environment so the scheduler can bin-pack correctly and the kubelet can throttle/OOM-protect appropriately. See `DESIGN.md` Q2 for node-level isolation (taints, priority classes, dedicated pools). |
| **Observability** | `/metrics` scraped every 30s via `ServiceMonitor`; `/health` used for liveness/readiness so broken pods self-heal without a human needing to notice first. |
| **Security / secret hygiene** | `REDIS_PASSWORD` is a Kubernetes `Secret`, never a plain env value in the ConfigMap; checksum annotations force a rollout whenever the secret changes so stale pods don't run with an old credential. Real password material is never committed (see `TRADEOFFS.md` §3). |
| **Zero-downtime rollout** | Standard `RollingUpdate` Deployment strategy (Kubernetes default) + readiness probes means old pods are only removed once new ones report ready; PDB caps how many can be down at once during voluntary disruptions. |
| **Zone resilience** | Kustomize `topologySpreadConstraint` (production overlay) spreads pods across GCP zones so a single zone outage doesn't take out all replicas. |
| **Consistency across platforms** | Ansible role and Helm chart both read the same three core env vars from role/values, so behaviour doesn't silently diverge between the VM and Kubernetes deployment paths. |

Monitoring evidence is retained in `monitoring/screenshots/`: `dashboard.png` captures the Grafana overview and `prometheus-targets.png` captures Prometheus target discovery. The reusable dashboard definition is stored in `monitoring/dashboards/data-sync-overview.json`.

## 3. Repository layout

```
.
├── helm/charts/data-sync/          # Part 1: Helm chart
│   ├── Chart.yaml
│   ├── values.yaml                 # safe local/dev defaults
│   ├── values.staging.yaml
│   ├── values.production.yaml
│   ├── templates/
│   └── README.md                   # install/upgrade commands live here
├── standard/data-sync/production/  # Kustomize overlay on top of `helm template`
│   ├── kustomization.yaml
│   └── render.sh
├── ansible/                         # Part 2: VM-based deployment
│   ├── roles/be-data-sync/
│   ├── playbooks/playbook-data-sync.yml
│   └── group_vars/service.yml
├── monitoring/                       # Observability evidence and dashboard export
│   ├── dashboards/data-sync-overview.json
│   └── screenshots/
├── DESIGN.md                        # Part 3: written design answers
├── TRADEOFFS.md                     # Artefact 1
└── ARCHITECTURE.md                  # Artefact 2 (this file)
```

## 4. How to maintain this repository

- **One chart version bump per behavioural change.** Bump `Chart.yaml`
  `version` (SemVer) any time templates or default values change; bump
  `appVersion` only when the underlying app image changes. This keeps
  `helm history` meaningful for rollbacks.
- **Never edit `values.production.yaml` and deploy directly.** Changes go
  through a PR, `helm lint` + `helm template` run in CI against all three
  values files, and a diff of the rendered manifest is reviewed before merge
  (`helm template ... | kubectl diff -f -` against the live cluster is the
  safest pre-merge check once a real cluster exists).
- **Treat `values.yaml` as the single source of truth for the shape of
  config.** Environment files should only ever *override* values that already
  exist in `values.yaml` — if staging needs a brand-new key, add it to
  `values.yaml` first with a sane default, then override it per environment.
  This keeps `helm lint` catching typos instead of silently creating unused
  keys.
- **Secrets never enter git as real values.** CI/CD or a human operator
  supplies them via `--set` / `--set-file` from a secret store at deploy
  time. `values*.yaml` only ever contain clearly-fake placeholders (see
  `TRADEOFFS.md` §3), enforced with a simple pre-commit grep for
  `REPLACE_ME` still present at merge time being *expected*, not a bug.
- **Kustomize overlay is regenerated, not hand-edited.** `base-rendered.yaml`
  is a build artefact (`render.sh` output) and is gitignored; only
  `kustomization.yaml` and `render.sh` are source of truth. Set
  `REDIS_PASSWORD` in the environment when rendering a real production
  manifest so the generated Secret and checksum use the deployment value.
- **Ansible role changes require `ansible-lint` to pass** and a dry run
  (`--check --diff`) against a representative host before targeting the full
  `service` group.
- **DESIGN.md is a living document.** Revisit it whenever traffic patterns,
  node pool layout, or the secret rotation cadence change — it should always
  reflect the *current* plan, not just the plan at assignment time.
