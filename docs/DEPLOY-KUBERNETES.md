# Kubernetes Deployment

This guide covers deploying the application to a production Kubernetes cluster using the manifests in [`k8s/`](../k8s/).

## Prerequisites

Before deploying, ensure you have the following available:

- **kubectl** — the Kubernetes CLI, matching (or within one minor version of) your cluster. Verify with `kubectl version --client`.
- **kustomize** — used to build the manifests. `kubectl` ships with `kustomize` built in (`kubectl kustomize`), but a standalone `kustomize` binary is also supported. Verify with `kustomize version`.
- **A Kubernetes cluster** — with a valid `kubectl` context configured. Confirm with `kubectl config current-context` and `kubectl cluster-info`.
- **An ingress controller** — e.g. [ingress-nginx](https://kubernetes.github.io/ingress-nginx/). The `Ingress` resource in `k8s/` assumes an ingress controller is installed and watching `Ingress` resources.
- **cert-manager** — for automatic TLS certificate issuance. Install it and configure a `ClusterIssuer` (e.g. Let's Encrypt) before applying the ingress. See the [cert-manager docs](https://cert-manager.io/docs/).

## What gets deployed

Everything lives in the `synapsvault` namespace (set by `k8s/kustomization.yaml`):

| Resource | Purpose |
| --- | --- |
| `Deployment/backend` | API server on port 3000, with a `migrate` initContainer that runs `drizzle-kit migrate` before each new version starts |
| `Service/backend`, `HorizontalPodAutoscaler/backend` | ClusterIP on port 3000; scales 2–10 replicas on CPU |
| `Deployment/frontend`, `Service/frontend` | nginx serving the built SPA on port 80 |
| `ConfigMap/backend-config` | Non-secret backend settings (network, RPC URLs, CORS origins) |
| `ClusterIssuer/letsencrypt-prod` | cert-manager ACME issuer (HTTP-01 via nginx) used by the ingress TLS annotation |
| `Ingress/app-api` | `https://<host>/api/*` → backend, with the `/api` prefix stripped |
| `Ingress/app-web` | `https://<host>/*` → frontend |

Before the first deploy, replace `app.example.com` in `k8s/ingress.yaml` and `ALLOWED_ORIGINS` in `k8s/configmap.yaml` with your real host.

Images are built from this repo's `backend/Dockerfile` and `frontend/Dockerfile` with the `SynapsVault/backend` and `SynapsVault/frontend` repositories as build contexts, and pushed to `ghcr.io/synapsvault/deploy/{backend,backend-migrate,frontend}`.

## 0. Install cert-manager and the ClusterIssuer

The ingress requests a certificate via the `cert-manager.io/cluster-issuer: letsencrypt-prod` annotation, so cert-manager and a matching `ClusterIssuer` must exist before the ingress is applied.

1. Install cert-manager (including its CRDs):

   ```sh
   kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
   ```

   Wait for it to become ready:

   ```sh
   kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=180s
   ```

2. Make sure an ingress controller (e.g. ingress-nginx) is installed and that your domain's DNS `A`/`CNAME` record points at the ingress load balancer address. HTTP-01 validation requires the domain to resolve to the ingress.

3. Edit `k8s/cluster-issuer.yaml` and set `spec.acme.email` to a real contact address (and, optionally, switch `spec.acme.server` to the Let's Encrypt staging URL while testing). Then apply it:

   ```sh
   kubectl apply -f k8s/cluster-issuer.yaml
   ```

   It is also part of the kustomization, so `kubectl apply -k k8s/` applies it too. Verify it is ready:

   ```sh
   kubectl get clusterissuer letsencrypt-prod
   ```

   The `READY` column should show `True` once the ACME account is registered.

## 1. Create the secrets

The backend reads its secrets from a Secret named `backend-secret`, which must exist before the workloads are applied. Create it out-of-band so real values are never committed. [`k8s/secrets.yaml`](../k8s/secrets.yaml) documents the expected keys; it is deliberately **not** part of the kustomization, so `kubectl apply -k` never overwrites the real secret with placeholders.

Create the namespace first (if it does not already exist):

```sh
kubectl create namespace synapsvault
```

Create the secret from an env file (recommended, so values are not left in shell history), using the keys listed in `k8s/secrets.yaml`:

```sh
kubectl create secret generic backend-secret \
  --namespace synapsvault \
  --from-env-file=./secrets.env
```

If you need to update an existing secret:

```sh
kubectl create secret generic backend-secret \
  --namespace synapsvault \
  --from-env-file=./secrets.env \
  --dry-run=client -o yaml | kubectl apply -f -
```

> **Note:** After rotating secrets, restart the workloads so the new values are picked up:
> `kubectl rollout restart deployment/backend -n synapsvault`.

### Managing `backend-secret` with External Secrets Operator

Instead of creating the secret by hand, you can let the [External Secrets Operator (ESO)](https://external-secrets.io/) sync it from your secret backend (AWS Secrets Manager, Vault, GCP Secret Manager, Azure Key Vault, ...).

1. **Install ESO** into the cluster:

   ```sh
   helm repo add external-secrets https://charts.external-secrets.io
   helm install external-secrets external-secrets/external-secrets \
     --namespace external-secrets --create-namespace
   ```

2. **Create a `SecretStore`/`ClusterSecretStore`** that points at your secret backend and holds the credentials ESO uses to read it. See the [ESO provider docs](https://external-secrets.io/latest/provider/aws-secrets-manager/) for the exact spec of your provider.

3. **Store the backend values** under a single remote secret (e.g. `synapsvault/backend`) with one property per key listed in `k8s/secrets.yaml` (`DATABASE_URL`, `JWT_SECRET`, `SESSION_SECRET`, ...).

4. **Apply the example manifest**, adjusting `secretStoreRef` and the `remoteRef` keys to match your store:

   ```sh
   kubectl apply -f k8s/examples/external-secret.yaml
   ```

   [`k8s/examples/external-secret.yaml`](../k8s/examples/external-secret.yaml) creates an `ExternalSecret` that materializes the `backend-secret` Secret with the same keys the backend expects. It is intentionally **not** part of `k8s/kustomization.yaml`, so `kubectl apply -k k8s/` never touches it.

5. **Verify the sync**:

   ```sh
   kubectl get externalsecret backend-secret -n synapsvault
   kubectl get secret backend-secret -n synapsvault
   ```

   The `ExternalSecret` should report `SecretSynced` and the `backend-secret` Secret should exist. ESO refreshes it on the `refreshInterval` set in the manifest; restart the workloads after a rotation as noted above.

## 2. Apply the manifests

Build and apply everything under `k8s/` with kustomize:

```sh
kubectl apply -k k8s/
```

To preview what will be applied without changing the cluster:

```sh
kubectl kustomize k8s/
```

The manifests reference images by a pinned tag (not `:latest`), so a plain `kubectl apply -k k8s/` deploys a known, reproducible build. To deploy a different build, pin the tags first (this is what CI does):

```sh
cd k8s
kustomize edit set image \
  backend=ghcr.io/synapsvault/deploy/backend:<sha> \
  backend-migrate=ghcr.io/synapsvault/deploy/backend-migrate:<sha> \
  frontend=ghcr.io/synapsvault/deploy/frontend:<sha>
```

Replace `<sha>` with the commit SHA (or any immutable tag/digest) of the build you want to run. Using a digest (`@sha256:...`) is also supported and is the most reproducible option. Commit the resulting `k8s/kustomization.yaml` change if you want the pin to persist.

### Continuous deployment

The [Deploy to Kubernetes](../.github/workflows/deploy-k8s.yml) workflow runs on pushes to `main` that touch `backend/`, `frontend/` or `k8s/`, on manual dispatch (where you can choose the app repo refs), and on `repository_dispatch` events sent by the app repos. It builds and pushes all three images tagged with the commit SHA, pins those tags, applies the kustomization and waits for both rollouts.

It needs a base64-encoded kubeconfig in the `KUBECONFIG` secret of the `production` environment (`base64 -w0 < kubeconfig`). Until that secret exists, the deploy job is skipped with a warning; images are still built and pushed.

#### Environment selection and cluster identity checks

Manual dispatches choose an `environment` (`production` or `staging`); pushes to `main` deploy `production`. Each environment applies its own overlay into its own namespace:

| Environment | Kustomization | Namespace |
| --- | --- | --- |
| `production` | `overlays/production` | `synapsvault-production` |
| `staging` | `overlays/staging` | `synapsvault-staging` |

The job runs in the matching GitHub environment, so `KUBE_CONFIG` can differ per environment. Set these **variables** on each GitHub environment to the cluster that environment must deploy to:

| Variable | Example | Compared against |
| --- | --- | --- |
| `KUBE_EXPECTED_CONTEXT` | `prod-cluster` | `kubectl config current-context` |
| `KUBE_EXPECTED_SERVER` | `https://prod.k8s.example.com:6443` | the current context's cluster `server` |

Before anything is applied, the workflow checks the kubeconfig context and API server against these values. It also checks that the rendered overlay targets only the environment's namespace. If either variable is missing or anything differs, the job fails before any cluster change. For example, selecting `production` while `KUBE_CONFIG` holds staging credentials fails.

#### Failure diagnostics

When any deploy step fails, the workflow always collects pod status, pod YAML,
namespace events and the `backend-migrate` Job status into a `deploy-diagnostics/`
artifact (`deploy-diagnostics-<environment>-<run>-<attempt>`). Every line is passed
through `scripts/sanitize-diagnostics.mjs` before upload: Kubernetes Secret objects
are dropped entirely, sensitive env values (`*PASSWORD*`, `*TOKEN*`, `*KEY*`, DSNs,
credentials in URLs) are replaced with `[REDACTED]`, and non-sensitive values such
as image tags and log levels are kept so the artifact is still useful.

`node --test test/failure-diagnostics.test.cjs` verifies the sanitizer and collector
with fake `kubectl` output.
#### Timeout budget

The deploy job has a hard ceiling of **30 minutes** (`timeout-minutes` on the job) and
every step has its own cap. Once a step exceeds its cap GitHub cancels it, and once the
job reaches 30 minutes the whole run is cancelled — a stalled `kubectl` call or a hung
rollout wait cannot run indefinitely.

| Phase | Step budget |
| --- | --- |
| Checkout / ref resolution / kubeconfig / target verification | 10 minutes each |
| Apply, rollout wait, DNS checks, manifest upload | 10 minutes each |
| Whole deploy job | 30 minutes |

Image builds happen in the `SynapsVault/backend` and `SynapsVault/frontend` workflows,
not in this repository. Those build jobs must carry their own `timeout-minutes`
(15 minutes recommended); this deploy consumes only digest-pinned artifacts, so a
build that exceeds its budget never produces a deployable image.

`npm run check:deploy-timeouts` verifies that the job ceiling and every step timeout
are present; `test/deploy-timeouts.test.cjs` also proves the checker rejects a workflow
with a missing ceiling or step timeout.
#### Image signature gate

Immediately before `kubectl apply`, every image in the rendered kustomization must be
pinned by `sha256` digest and carry a cosign signature from the expected build workflow:

| Variable | Example |
| --- | --- |
| `COSIGN_IDENTITY` | `https://github.com/SynapsVault/backend/.github/workflows/build-image.yml@refs/heads/main` |
| `COSIGN_OIDC_ISSUER` | `https://token.actions.githubusercontent.com` |

The gate is implemented by `scripts/verify-image-signatures.sh`. Missing variables, a
mutable tag, an unsigned image, or a signature from a different identity/issuer all stop
the deploy before any manifest is applied.

#### SBOM and provenance gate

Right after the signature gate, `scripts/verify-image-attestations.sh` checks that every
rendered image carries a readable **SBOM** and a **provenance** attestation tied to its
digest (#157). For each digest-pinned image it runs `cosign verify-attestation` with the
same `COSIGN_IDENTITY` / `COSIGN_OIDC_ISSUER`, decodes the in-toto statement and requires
that the statement's `subject` contains the image's `sha256` digest and that its predicate
is not empty.

| Variable (optional) | Default | Purpose |
| --- | --- | --- |
| `SBOM_PREDICATE_TYPE` | `spdxjson` | `cosign verify-attestation --type` for the SBOM (e.g. `cyclonedx`) |
| `PROVENANCE_PREDICATE_TYPE` | `slsaprovenance` | `--type` for provenance (e.g. `slsaprovenance1`) |

The app build workflows must attach both attestations to the pushed digest, for example
`cosign attest --type spdxjson --predicate sbom.spdx.json <image>@sha256:<digest>` and the
equivalent provenance attestation. A missing attestation, an unreadable statement, or an
attestation whose subject is a different digest fails the job before `kubectl apply` with
an error naming the image, the attestation kind and the digests that were attested. Since
promotion runs the same gate, such an image can never be promoted to production.

`node --test test/verify-image-attestations.test.cjs` covers these cases with fake
`kubectl`/`yq`/`cosign` binaries.

#### Release manifest

Every deploy uploads a `release-manifest-<environment>-<run id>-<attempt>` artifact containing `release-manifest.json`. The file records:

- the environment and namespace;
- the full commit SHAs of this repository (`sources.deploy`), and of `SynapsVault/backend` and `SynapsVault/frontend` resolved from the pinned refs in `.github/workflows/app-versions.env` (`sources.backend` and `sources.frontend`, each with the requested `ref`);
- the image digests the rolled-out `backend` and `frontend` pods run, and the digest-pinned image applied for the `backend-migrate` Job (`images.backend`, `images.frontend`, `images.backend_migrate`);
- the workflow run URL (`workflow_run_url`);
- for a promotion, the staging run it was promoted from (`promoted_from_staging_run`, otherwise `null`).

The deploy fails if any of the three source revisions is not a full commit SHA. The app SHAs are checked before anything is applied, and all three are checked again before the manifest is uploaded. Use the manifest as the evidence link when adding a row to [`RELEASE-COMPATIBILITY.md`](RELEASE-COMPATIBILITY.md).

#### Promoting staging to production

Production can be released from a verified staging deploy instead of from app refs
(#153). Run the workflow manually with `environment: production` and
`promote_staging_run_id` set to the run ID of a successful staging deploy:

```sh
gh workflow run deploy-k8s.yml -R SynapsVault/deploy \
  -f environment=production -f promote_staging_run_id=<staging-run-id>
```

The workflow then:

1. checks that the run is a successful `Deploy to Kubernetes` run and downloads its
   latest `release-manifest-staging-<run id>-<attempt>` artifact (the run must be recent
   enough that the artifact has not expired);
2. requires the manifest to be for `staging`, with full backend/frontend commit SHAs and
   digest-pinned `backend`, `backend_migrate` and `frontend` images;
3. skips the backend/frontend source checkouts and takes the refs and SHAs from the
   manifest, so nothing is resolved or rebuilt again;
4. patches the production overlay so the `backend` and `frontend` Deployments and the
   `backend-migrate` Job use exactly those digests, and fails if the rendered images
   differ;
5. runs the signature and SBOM/provenance gates, applies, waits for the rollouts, and
   finally compares the production release manifest with the staging one, failing unless
   the backend, migration and frontend digests are identical.

Promotion is rejected for any environment other than `production`. Staging manifests
written before `images.backend_migrate` was recorded cannot be promoted; redeploy staging
and promote that run.

#### Triggering a deploy from the app repos

The backend and frontend repos can trigger a deploy when they change by sending a `repository_dispatch` event to this repo. The workflow listens for the `app-deploy` event type and reads the refs from the payload:

| `client_payload` field | Default | Purpose |
| --- | --- | --- |
| `backend_ref` | `refs/heads/main` | Git ref of `SynapsVault/backend` to build |
| `frontend_ref` | `refs/heads/main` | Git ref of `SynapsVault/frontend` to build |
| `backend_repository` (optional) | `SynapsVault/backend` | Must be a permitted source repository |
| `frontend_repository` (optional) | `SynapsVault/frontend` | Must be a permitted source repository |

Refs are validated **before any checkout or build**: each must be a full 40-character SHA
or a `refs/heads/…` / `refs/tags/…` reference, and any supplied repository field must be
one of `SynapsVault/backend` or `SynapsVault/frontend`. Malformed payloads stop the job
immediately. The accepted refs and their resolved full SHAs are recorded in the release
manifest (`sources.*.ref` / `sources.*.sha`), so a dispatch can be traced to exact revisions.

Add a workflow like this to each app repo (`.github/workflows/deploy.yml`). It needs a token with `contents: write` on this repo stored as the `DEPLOY_DISPATCH_TOKEN` secret:

```yaml
name: Trigger deploy

on:
  push:
    branches: [main]

jobs:
  dispatch:
    runs-on: ubuntu-latest
    steps:
      - name: Dispatch deploy-k8s
        uses: peter-evans/repository-dispatch@v3
        with:
          token: ${{ secrets.DEPLOY_DISPATCH_TOKEN }}
          repository: SynapsVault/deploy
          event-type: app-deploy
          client-payload: |
            {
              "backend_ref": "${{ github.sha }}",
              "frontend_ref": "${{ github.sha }}"
            }
```

Set only the ref for the repo that changed (e.g. the backend repo sends `backend_ref` and leaves `frontend_ref` at its default). You can also dispatch manually with the GitHub CLI:

```sh
gh api repos/SynapsVault/deploy/dispatches \
  -f event_type=app-deploy \
  -f 'client_payload[backend_ref]=<sha>'
```

## 3. Verify the rollout

Watch the rollout status of each deployment:

```sh
kubectl rollout status deployment/<name> -n synapsvault
```

Inspect the resulting resources:

```sh
kubectl get all -n synapsvault
kubectl get ingress -n synapsvault
kubectl get pods -n synapsvault -o wide
```

Check that pods are `Running` and `Ready`, and that the ingress has an address assigned. If a pod is not becoming ready, inspect it:

```sh
kubectl describe pod <pod> -n synapsvault
kubectl logs <pod> -n synapsvault
```

### Verifying the API docs endpoint

The smoke test (`scripts/06-smoke-test.js`) does not accept any `200` response for the API docs path. It fetches the documented OpenAPI/Swagger endpoint and validates the response body: the content must be JSON with an OpenAPI/Swagger signature (e.g. an `openapi` or `swagger` version field and a `paths` object). A response that is `200` but returns HTML — for example an ingress SPA fallback serving `index.html` for the docs path — fails the check.

If the smoke test reports the docs endpoint returned HTML or non-OpenAPI content, confirm the ingress routes the docs path to the backend rather than the frontend:

```sh
kubectl get ingress -n synapsvault
curl -fsS -H 'Accept: application/json' https://<host>/api/docs-json | head -n 5
```

The response should be JSON, not `<!DOCTYPE html>`.

## 4. Scale

Scale a deployment manually:

```sh
kubectl scale deployment/<name> --replicas=5 -n synapsvault
```

> **Note:** If a HorizontalPodAutoscaler (HPA) manages the deployment, manual scaling will be overridden by the HPA. Adjust the HPA's `minReplicas`/`maxReplicas` instead (see below).

### Namespace resource quotas

Each environment has its own `ResourceQuota` named `compute-budget` (#166), defined in
the overlay rather than in `k8s/`, so staging and production budgets are independent:

| Resource | Peak use | Staging (`overlays/staging/resourcequota.yaml`) | Production (`overlays/production/resourcequota.yaml`) |
| --- | --- | --- | --- |
| `pods` | 6 | 8 | 12 |
| `requests.cpu` | 450m | 600m | 1 |
| `limits.cpu` | 2250m | 3 | 5 |
| `requests.memory` | 576Mi | 768Mi | 1280Mi |
| `limits.memory` | 1920Mi | 2560Mi | 4Gi |
| `requests.ephemeral-storage` | 576Mi | 768Mi | 1280Mi |
| `limits.ephemeral-storage` | 2816Mi | 3Gi | 6Gi |

"Peak use" is the worst case of a normal deploy: the default `RollingUpdate` surge adds
one extra `backend` and one extra `frontend` pod while the old ones still run (backend
1+1, frontend 2+1), and the `backend-migrate` Job pod runs at the same time. Staging
keeps a small margin over that peak; production keeps about twice the peak so it can be
scaled out without touching the quota first.

Because the quota covers CPU, memory and ephemeral storage, every pod in these namespaces
must set requests and limits for all three (all manifests in `k8s/` do). A pod or a
rollout's surge pod that would exceed the quota is rejected: the ReplicaSet or Job
reports `exceeded quota: compute-budget` in its events and the rollout stalls instead of
landing on the cluster.

Check usage against the budget:

```sh
kubectl -n synapsvault-production describe resourcequota compute-budget
```

To adjust a quota:

1. Recompute the peak whenever you change `replicas`, the HPA `maxReplicas`, a
   container's requests/limits, a Deployment's `maxSurge`, or add a Job/CronJob:
   sum each workload's (replicas + surge) × per-pod requests/limits, plus the
   migration Job.
2. Edit `spec.hard` in `overlays/<environment>/resourcequota.yaml` (and the arithmetic
   in its header comment), keeping it at or above that peak.
3. Deploy the environment as usual; the quota is applied with the rest of the overlay.
   Raise the quota **before** (or in the same deploy as) a change that increases usage;
   otherwise the new pods are rejected.

### Backend topology spread

The backend Deployment declares `topologySpreadConstraints` (#164) so replicas spread
across zones (`topology.kubernetes.io/zone`) and nodes (`kubernetes.io/hostname`) with a
`maxSkew` of 1. `matchLabelKeys: [pod-template-hash]` applies the skew within one
ReplicaSet, so a rollout's surge pod is spread against the pods of its own revision.

Both constraints use `whenUnsatisfiable: ScheduleAnyway`. The scheduler prefers the
most even layout but never leaves a pod `Pending` because of the spread, so:

- **multiple zones**: with 2 replicas, the second replica lands in a different zone from
  the first whenever a node in another zone has capacity;
- **only one zone** (or zone labels missing): every node is in the same domain, so the
  zone constraint is satisfied trivially and pods still spread across nodes; on a
  single-node cluster all replicas schedule on that node.

Render and inspect the constraints:

```sh
kubectl kustomize overlays/production \
  | yq 'select(.kind == "Deployment" and .metadata.name == "backend") | .spec.template.spec.topologySpreadConstraints'
```

Check where replicas actually landed and which zone each node is in:

```sh
kubectl -n synapsvault-production get pods -l app=backend -o wide
kubectl get nodes -L topology.kubernetes.io/zone
```

To require zone spread instead (pods stay `Pending` rather than share a zone), switch the
zone constraint to `whenUnsatisfiable: DoNotSchedule` and add `minDomains`. Only do this on
clusters with at least that many zones and capacity in each.

## 5. Roll back a deployment

Every `kubectl apply` of a changed pod template creates a new ReplicaSet, giving you a revision history to roll back through.

View the rollout history:

```sh
kubectl rollout history deployment/<name> -n synapsvault
```

Roll back to the previous revision:

```sh
kubectl rollout undo deployment/<name> -n synapsvault
```

Roll back to a specific revision:

```sh
kubectl rollout undo deployment/<name> --to-revision=<n> -n synapsvault
```

Confirm the rollback completed:

```sh
kubectl rollout status deployment/<name> -n synapsvault
```

## 6. Autoscaling (HPA)

The `HorizontalPodAutoscaler` in `k8s/` scales the deployment based on CPU utilization. Key fields:

- **`scaleTargetRef`** — points at the deployment to scale.
- **`minReplicas`** — the floor; the deployment never scales below this.
- **`maxReplicas`** — the ceiling; the deployment never scales above this.
- **`metrics`** — typically `type: Resource`, `resource.name: cpu`, with a `target.averageUtilization` percentage (e.g. `70`).

The HPA requires the [metrics-server](https://github.com/kubernetes-sigs/metrics-server) to be installed in the cluster; without it, the HPA cannot read utilization and will not scale. Verify metrics are available:

```sh
kubectl top pods -n synapsvault
kubectl get hpa -n synapsvault
```

To change scaling behavior, edit the HPA (or its manifest in `k8s/`) and re-apply:

```sh
kubectl edit hpa <name> -n synapsvault
```

### Connection pooling for the HPA-scaled backend

Each backend replica opens its own database connection pool. With the HPA scaling up to 10 replicas, the total number of connections is `replicas × pool size per replica`, which can exhaust Postgres/Supabase connection limits. Keep the total well under the database's limit by pooling connections and capping the per-replica pool size.

**Option A — use Supabase's built-in pooler (recommended).** Supabase exposes a PgBouncer-based pooler on port `6543` (transaction mode) alongside the direct connection on `5432`. Point the backend's `DATABASE_URL` at the pooler so all replicas share a small number of upstream connections:

```
postgresql://postgres.<project-ref>:<password>@aws-0-<region>.pooler.supabase.com:6543/postgres
```

Use the pooler host/port (`...pooler.supabase.com:6543`) in the `DATABASE_URL` key of `backend-secret`. Keep the direct `:5432` URL only for the `migrate` initContainer, which needs a session-mode connection for `drizzle-kit migrate`.

**Option B — deploy PgBouncer in the cluster.** If you are not on Supabase (or want pooling inside the cluster), deploy PgBouncer as its own `Deployment`/`Service` in the `synapsvault` namespace and point `DATABASE_URL` at `pgbouncer.synapsvault.svc.cluster.local:6432`. Run it in `transaction` pooling mode and size `default_pool_size` to the database's connection budget (e.g. `default_pool_size = 20` for a 60-connection limit).

**Set the pool size per replica.** Regardless of which option you use, cap the backend's own pool so `maxReplicas × pool size` stays within the database limit. Set `DATABASE_POOL_MAX` in `k8s/configmap.yaml` (non-secret, so it is easy to tune) and reference it from the backend container's `env`:

```yaml
# k8s/configmap.yaml
data:
  DATABASE_POOL_MAX: "5"
```

```yaml
# k8s/backend-deployment.yaml (container env)
- name: DATABASE_POOL_MAX
  valueFrom:
    configMapKeyRef:
      name: backend-config
      key: DATABASE_POOL_MAX
```

With `maxReplicas: 10` and `DATABASE_POOL_MAX: "5"`, the backend opens at most 50 connections — comfortably within a typical Supabase/Postgres limit. When raising `maxReplicas`, lower `DATABASE_POOL_MAX` accordingly (or rely on the pooler to multiplex).

## 7. Probes

The deployments configure separate startup, liveness, and readiness probes so Kubernetes can distinguish between slow container startup, process deadlocks, and temporary downstream dependency outages:

- **`startupProbe`** — gates liveness and readiness checks until the container finishes booting (`/health/live`, up to `failureThreshold: 12` × `periodSeconds: 5` = 60 seconds).
- **`livenessProbe`** — restarts the container only if the process itself is unresponsive (`/health/live`), avoiding cascading restarts when Postgres or Soroban RPC is transiently degraded.
- **`readinessProbe`** — removes the pod from Service endpoints until downstream dependencies are ready to serve traffic (`/health/ready`).

Each probe sets:

- **`httpGet.path` / `httpGet.port`** — the endpoint and port to probe.
- **`initialDelaySeconds`** — how long to wait before the first probe.
- **`periodSeconds`** — how often to probe.
- **`timeoutSeconds`** — how long to wait for a response.
- **`failureThreshold` / `successThreshold`** — how many consecutive failures/successes trigger a state change.

### Frontend probes and routing

The frontend container serves a dedicated health endpoint at `/healthz` that is handled independently of the SPA fallback, so a missing asset can never masquerade as a healthy response. The frontend `Deployment` uses `/healthz` for its startup, liveness, and readiness probes.

nginx routing separates static asset requests from navigation fallback:

- Requests under `/assets/` (and other static files) are served directly. A missing JavaScript or CSS file returns **404** instead of the SPA shell.
- Any other path (e.g. `/dashboard`, `/leases/123`) falls back to `index.html` so client-side routes still work on a hard refresh or deep link.

At startup the container validates the required runtime configuration (`APP_API_URL` and `APP_NETWORK`) before rendering `config.js`. If a value is missing or invalid, the container exits with a clear field-level error (e.g. `APP_API_URL: must be a valid URL`) and the pod goes into `CrashLoopBackOff`; check `kubectl logs <pod> -n synapsvault` for the offending field. Relative API URLs (e.g. `/api`) remain supported.

Inspect probe behavior:

```sh
kubectl describe pod <pod> -n synapsvault
```

Look at the `Startup`/`Liveness`/`Readiness` sections and the `Events` at the bottom for probe failures.

Verify the frontend routing and health endpoint from inside a frontend pod:

```sh
POD=$(kubectl get pod -n synapsvault -l app=frontend -o jsonpath='{.items[0].metadata.name}')

# Health endpoint returns the explicit health body
kubectl exec -n synapsvault "$POD" -- curl -fsS http://localhost/healthz

# A missing static asset returns 404, not index.html
kubectl exec -n synapsvault "$POD" -- curl -s -o /dev/null -w '%{http_code}\n' http://localhost/assets/missing.js

# A client-side route still serves the SPA shell
kubectl exec -n synapsvault "$POD" -- curl -fsS http://localhost/dashboard | head -n 5
```

## 8. Emergency Key Rotation (Contract Admin & Backend Signing Key)

If the backend signing key (`BACKEND_SECRET_KEY` / `STELLAR_SECRET_KEY`) or the contract admin key is suspected of compromise, execute the following rotation procedure immediately:

1. **Generate and fund a replacement keypair** on a clean workstation:
   ```sh
   node scripts/01-generate-keypairs.js
   ```
   Fund the new public key (`GNEW_ADMIN...`) on the target network.

2. **Rotate on-chain contract authority**:
   - If the deployed contract exposes an admin transfer entrypoint (`set_admin` / `rotate_admin`), invoke it signed by the current admin (or recovery multisig) to assign `GNEW_ADMIN...`:
     ```sh
     stellar contract invoke \
       --id "$STELLAR_CONTRACT_ACCESS_LEASE" \
       --source current-admin \
       --network testnet \
       -- set_admin --new_admin GNEW_ADMIN...
     ```
   - If the compromised key was the sole `init(admin)` authority on an immutable contract without an in-place transfer entrypoint, deploy fresh contract instances initialized with `ADMIN_PUBLIC_KEY=GNEW_ADMIN...`:
     ```sh
     STELLAR_SECRET_KEY=SNEW_DEPLOYER... \
     ADMIN_PUBLIC_KEY=GNEW_ADMIN... \
     npm run deploy:contracts -- --network testnet
     ```

3. **Update `backend-secret` and `backend-config` in Kubernetes**:
   ```sh
   kubectl create secret generic backend-secret \
     --namespace synapsvault \
     --from-env-file=./secrets.env \
     --dry-run=client -o yaml | kubectl apply -f -
   ```
   If new contract IDs were deployed, update `k8s/configmap.yaml` (or run `npm run rollback:contracts` against the new `contract-ids.env`) and apply.

4. **Roll out the backend and revoke the old key**:
   ```sh
   kubectl rollout restart deployment/backend -n synapsvault
   kubectl rollout status deployment/backend -n synapsvault
   ```
   Decommission the compromised Stellar account (or set its master weight to `0` via a `set_options` operation) so it can no longer sign transactions.

## 9. Node-drain drill (staging)

Before changing scheduling constraints, disruption budgets, or node pools in production, rehearse a node drain in staging and observe availability and rescheduling. The repeatable drill — including expected PodDisruptionBudget behavior, recovery timing, and cleanup steps — is documented in [`docs/runbooks/kubernetes-node-drain-drill.md`](runbooks/kubernetes-node-drain-drill.md).

## Troubleshooting

- **Pods stuck in `Pending`** — check node capacity and scheduling constraints (`kubectl describe pod <pod> -n synapsvault`).
- **`CrashLoopBackOff`** — inspect logs (`kubectl logs <pod> -n synapsvault --previous`) and confirm `backend-secret` exists with all required keys.
- **`ImagePullBackOff`** — verify the image tags pinned in `k8s/kustomization.yaml` exist in the registry and that the cluster can pull from `ghcr.io`.
- **Ingress has no address** — confirm an ingress controller is installed and running.
- **TLS certificate not issued** — check the `Certificate`/`Order` resources and cert-manager logs.
- **HPA not scaling** — confirm metrics-server is installed and `kubectl top pods` returns data.
- **Database connection errors under load** — check the total connection count against the database limit; use the pooler and lower `DATABASE_POOL_MAX` (see [Connection pooling](#connection-pooling-for-the-hpa-scaled-backend)).
- **Certificate not issued** — check `kubectl get certificate,order,challenge -n synapsvault` and `kubectl describe certificate <name> -n synapsvault`. Confirm the `ClusterIssuer` is `READY` and that the domain resolves to the ingress.
- **Pods in `CrashLoopBackOff`** — inspect logs (`kubectl logs <pod> -n synapsvault`) and confirm `backend-secret` exists with all required keys.
- **`ImagePullBackOff`** — verify the image tags and that the cluster can pull from `ghcr.io`.
- **Ingress returns 404/502** — confirm the ingress controller is running and the `Ingress` host matches your DNS.
- **Pods stuck in `Pending`** — check node capacity and scheduling constraints with `kubectl describe pod <pod> -n synapsvault`; look for insufficient CPU/memory or unsatisfied node selectors/taints.
- **Pods in `ImagePullBackOff`/`ErrImagePull`** — confirm the image tag exists in `ghcr.io/synapsvault/deploy/*` and that the cluster can pull from GHCR (image pull secret if the packages are private).
- **`CrashLoopBackOff`** — inspect `kubectl logs <pod> -n synapsvault --previous` and the initContainer logs (the `migrate` container runs first).
- **Ingress returns 404/502** — verify the ingress controller is running, the `Ingress` host matches your DNS, and the backend/frontend Services have ready endpoints (`kubectl get endpoints -n synapsvault`).
- **TLS certificate not issued** — check the `Certificate`/`Order`/`Challenge` resources and cert-manager logs; ensure the `ClusterIssuer` is valid and DNS points at the ingress.
- **HPA shows `<unknown>` targets** — metrics-server is missing or not ready; install it and re-check with `kubectl top pods -n synapsvault`.
- **Pods stuck in `Pending`** — check node capacity and scheduling constraints (`kubectl describe pod <pod> -n synapsvault`), and confirm the cluster has enough CPU/memory for the requested resources.
- **Pods in `ImagePullBackOff` / `ErrImagePull`** — verify the image tag/digest you pinned actually exists in `ghcr.io/synapsvault/deploy/*` and that the cluster can pull from GHCR (image pull secret if the packages are private).
- **`CrashLoopBackOff`** — inspect `kubectl logs <pod> -n synapsvault --previous` and confirm the `backend-secret` keys are present and valid.
- **Ingress has no address** — confirm an ingress controller is installed and running (`kubectl get pods -n ingress-nginx`).
- **TLS certificate not issued** — check the `Certificate`/`Order`/`Challenge` resources and the cert-manager logs; confirm the `ClusterIssuer` is ready.
- **HPA shows `<unknown>` targets** — metrics-server is missing or not ready; see section 6.
