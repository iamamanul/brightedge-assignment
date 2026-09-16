# System Design: Scaling, Workload Isolation & Secret Rotation

## Q1. Scaling strategy: cutting scale-out lag from ~90s to under 20s

CPU is a lagging signal: polling, scale-up decisions, image pulls, startup,
and readiness checks complete only after the burst has begun.

### Recommended Architecture: KEDA with Leading Metric Indicators

```
Request queue depth / RPS  ──▶  KEDA ScaledObject  ──▶  HPA  ──▶  Deployment
        (Prometheus)              (metric adapter)
```

- Scale on **requests-per-second** or **Redis queue depth**, both of which rise before CPU saturates.
- Set KEDA polling to 5 seconds, scale-up stabilization to 0 seconds, and scale-down stabilization to 120 seconds.
- **Pre-warm a small standing buffer:** keep `minReplicas` higher than the CPU-idle baseline, for example 4 instead of 2.
- **Shrink startup time:** use a small image with dependencies baked in and a
   fast readiness check.
- **Metrics to watch:** p95/p99 request latency, Redis connection pool
  saturation, HPA/KEDA scale event timestamps vs. traffic timestamps (to
  measure actual reaction lag), and pod time-to-ready.

**Trade-offs:** KEDA adds an operator and a second scaling concept to
operate and debug. Higher `minReplicas` costs more baseline compute even at
idle. Faster scale-up policies risk over-scaling on noisy/short-lived spikes,
so scale-down should stay conservative to avoid thrashing.

## Q2. Workload isolation from noisy neighbours (e.g. ClickHouse)

Layered approach, cheapest first:

1. **Resource requests/limits** (already in the chart) reserve capacity and
   enforce CPU/memory ceilings, limiting basic cgroup contention.
2. **PriorityClasses**: give `data-sync` a higher `PriorityClass` than
   best-effort analytics jobs so that under node pressure, ClickHouse pods
   are evicted first, not `data-sync`.
3. **Node affinity / anti-affinity**: prefer scheduling `data-sync` pods away
   from nodes already running ClickHouse, using
   `podAntiAffinity` with `requiredDuringSchedulingIgnoredDuringExecution`
   (or `preferred...` if the cluster is small and strict separation isn't
   always achievable).
4. **Taints/tolerations**: taint a subset of nodes for latency-sensitive
   workloads (e.g. `dedicated=latency-sensitive:NoSchedule`) and add the
   matching toleration only to `data-sync`, keeping ClickHouse off those
   nodes entirely.
5. **ResourceQuota / LimitRange per namespace**: cap how much CPU/memory the
   analytics namespace can consume cluster-wide, so a ClickHouse backfill job
   can't quietly claim capacity meant for other workloads.
6. **Dedicated node pool**: use one if CPU controls do not address ClickHouse
   I/O or memory-bandwidth contention. It removes contention but costs idle
   capacity and adds another pool to manage and upgrade.

Use a dedicated pool immediately when hard latency SLOs cannot tolerate
noisy-neighbour variance.

## Q3. Zero-downtime REDIS_PASSWORD rotation every 90 days

**Secret delivery:** store the password in GCP Secret Manager (or AWS Secrets
Manager) and sync it into the chart's Kubernetes `Secret` with **External
Secrets Operator**. ESO polls and updates it automatically.

**Rollout strategy:**

1. Rotate Redis using a **dual-password window** if supported, such as two ACL
   credentials, so existing connections remain valid.
2. ESO updates the k8s `Secret` with the new password.
3. The Deployment's `checksum/secret` annotation changes, triggering a
   **RollingUpdate** that respects `maxUnavailable`/`maxSurge` and the PDB.
4. New pods pick up the new password while old pods retain the still-valid
   credential until replaced.
5. Once all pods are rolled (readiness probes confirm each is healthy on the
   new credential), revoke the old password on the Redis side.

**Verifying success without an outage:**

- Watch `kubectl rollout status deployment/data-sync` and confirm no pods enter
   `CrashLoopBackOff`.
- Watch `/health` success and Redis authentication errors in Grafana; defer
   revocation if errors rise.
- Confirm via `kubectl exec` into a freshly-rolled pod (or a synthetic
  health-check job) that it can actually read/write a test key in Redis
  using the environment it was started with, before revoking the old
  password.
- Only revoke the old password once 100% of pods are on the new revision
  *and* the error-rate dashboards have been clean for a full rollout window
  (e.g. 10-15 minutes) — this buffer catches any slow stragglers or retry
  storms.

**Trade-off:** this depends on Redis supporting a dual-credential window;
if it doesn't, rotation must instead be sequenced (new password written to
Redis and the Secret in the same maintenance step) which reintroduces a
short window where already-running pods can fail auth until they're rolled —
mitigated by keeping the rollout fast (small `maxUnavailable`, generous
`maxSurge`) so that window is seconds, not minutes.
