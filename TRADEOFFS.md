# Options Considered & Trade-offs

This document lists the decisions made while building the `data-sync` Helm
chart, Kustomize overlay, and Ansible role, and why the alternatives were not
chosen. Required artefact #1.

## 1. Helm chart structure

**Chosen:** A single chart with three layered values files
(`values.yaml` → `values.staging.yaml` → `values.production.yaml`), no
sub-charts except a documented (not implemented) `bitnami/redis` dependency.

**Considered:**
- *Separate chart per environment*: rejected because it guarantees drift between
  staging and production over time; a single templated chart with overrides
  keeps the two in sync by construction.
- *Helmfile / umbrella chart across all BrightEdge services*: rejected for
  this task: out of scope, adds a second tool to learn for a single-service
  deploy. Worth revisiting once more services follow this pattern.

**Trade-off accepted:** values files can grow large as more environments are
added (e.g. `values.dr.yaml`). Mitigated by keeping `values.yaml` as the only
source of full defaults and letting environment files only override deltas.

## 2. Scaling: HPA (CPU) vs KEDA vs both

**Chosen for the chart itself:** stock `autoscaling/v2` HPA on CPU
utilization, because it needs no extra operator and satisfies the assignment
requirement directly.

**Considered:** KEDA scaling on a custom metric (e.g. Redis queue depth or
request rate). This is what's actually recommended in `DESIGN.md` for
solving the real lag-spike problem, since CPU-based HPA reacts *after* pods
are already saturated. It was not made the chart default because it requires
KEDA to be installed cluster-wide, which is a platform-level decision outside
this microservice's chart.

**Trade-off accepted:** the shipped chart under-reacts to burst traffic vs.
what `DESIGN.md` recommends; `autoscaling.behavior` is exposed in values so a
future PR can add KEDA + a `ScaledObject` chart without restructuring.

## 3. Secret handling

**Chosen:** a plain Kubernetes `Secret` templated from `values.redis.password`
with a placeholder value in every values file, plus a checksum annotation on
the pod template so rollouts pick up changes automatically.

**Considered:**
- *Sealed Secrets* (encrypt at rest in git): a real candidate, not adopted
  here purely because it requires the `kubeseal` controller to be running in
  the target cluster, which we can't assume for `kind` smoke-testing.
- *External Secrets Operator + GCP Secret Manager*: the actual recommended
  production approach (documented in `DESIGN.md` Q3 and the chart README),
  not implemented in the chart to keep this exercise runnable with
  `helm template` / `kind` alone, no cloud credentials required.

**Trade-off accepted:** as shipped, a real password would sit in a values
file if someone forgot to override it. This is flagged loudly in the README
and chart comments rather than silently accepted.

## 4. Kustomize overlay vs. doing everything in the Helm chart

**Chosen:** topology spread constraints and the `SECRET_CHECKSUM` annotation
are applied via a Kustomize patch on top of `helm template` output, as the
assignment specifies, rather than adding more `if` blocks to the Deployment
template.

**Considered:** adding `topologySpreadConstraints` directly as a Helm value:
simpler, but the assignment explicitly asks for a Kustomize-based patch
layer, matching how BrightEdge already treats Kustomize as the
workload-level configuration point on top of Helm-rendered bases.

**Trade-off accepted:** two tools (Helm + Kustomize) to reason about instead
of one; mitigated with `render.sh` which does both steps as one command.

## 5. Pod health and metrics scaffolding

**Chosen:** A custom Nginx virtual configuration mounted into the `nginx:1.27-alpine` stand-in image to serve `/health` JSON and Prometheus-compatible `/metrics` output.

**Considered:** a tiny custom Python/FastAPI image built for this exercise:
rejected as unnecessary effort per the assignment's own tip ("use placeholder
image, we don't expect you to build image from scratch").

**Trade-off accepted:** the metrics are static scaffolding and must be replaced or extended when the production application image is introduced.

## 6. Ansible: role scope and idempotency

**Chosen:** one role, `be-data-sync`, gated by `when: be_role == 'service'`,
using `git`, `pip` inside a dedicated virtualenv, and a Jinja2 systemd unit
with a `notify`-driven restart handler.

**Considered:** a single monolithic playbook with inline tasks instead of a
role. It was rejected because it breaks the team's existing `be-{service}` role convention
and isn't reusable across environments/hosts.

**Trade-off accepted:** more files/boilerplate for a small role, in exchange
for consistency with the rest of the Ansible codebase.
