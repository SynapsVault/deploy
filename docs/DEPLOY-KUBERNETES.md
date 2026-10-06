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
| `Ingress/app-api` | `https://<host>/api/*` → backend, with the `/api` prefix stripped |
| `Ingress/app-web` | `https://<host>/*` → frontend |

Before the first deploy, replace `app.example.com` in `k8s/ingress.yaml` and `ALLOWED_ORIGINS` in `k8s/configmap.yaml` with your real host.

Images are built from this repo's `backend/Dockerfile` and `frontend/Dockerfile` with the `SynapsVault/backend` and `SynapsVault/frontend` repositories as build contexts, and pushed to `ghcr.io/synapsvault/deploy/{backend,backend-migrate,frontend}`.

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

## 2. Apply the manifests

Build and apply everything under `k8s/` with kustomize:

```sh
kubectl apply -k k8s/
```

To preview what will be applied without changing the cluster:

```sh
kubectl kustomize k8s/
```

The manifests reference images by the `:latest` tag. To deploy a specific build, pin the tags first (this is what CI does):

```sh
cd k8s
kustomize edit set image \
  backend=ghcr.io/synapsvault/deploy/backend:<sha> \
  backend-migrate=ghcr.io/synapsvault/deploy/backend-migrate:<sha> \
  frontend=ghcr.io/synapsvault/deploy/frontend:<sha>
```

### Continuous deployment

The [Deploy to Kubernetes](../.github/workflows/deploy-k8s.yml) workflow runs on pushes to `main` that touch `backend/`, `frontend/` or `k8s/` (or on manual dispatch, where you can choose the app repo refs). It builds and pushes all three images tagged with the commit SHA, pins those tags, applies the kustomization and waits for both rollouts.

It needs a base64-encoded kubeconfig in the `KUBECONFIG` secret of the `production` environment (`base64 -w0 < kubeconfig`). Until that secret exists, the deploy job is skipped with a warning; images are still built and pushed.

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

## 4. Scale

Scale a deployment manually:

```sh
kubectl scale deployment/<name> --replicas=5 -n synapsvault
```

> **Note:** If a HorizontalPodAutoscaler (HPA) manages the deployment, manual scaling will be overridden by the HPA. Adjust the HPA's `minReplicas`/`maxReplicas` instead (see below).

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

## 7. Probes

The deployment configures liveness and readiness probes so Kubernetes can detect unhealthy pods and route traffic only to healthy ones:

- **`livenessProbe`** — restarts the container if the check fails repeatedly. Points at a lightweight health endpoint (e.g. `/healthz`).
- **`readinessProbe`** — removes the pod from Service endpoints until the check passes, so traffic is only sent to pods that can serve requests (e.g. `/readyz`).
- **`startupProbe`** (if configured) — gives slow-starting containers time to boot before liveness checks begin.

Each probe sets:

- **`httpGet.path` / `httpGet.port`** — the endpoint and port to probe.
- **`initialDelaySeconds`** — how long to wait before the first probe.
- **`periodSeconds`** — how often to probe.
- **`timeoutSeconds`** — how long to wait for a response.
- **`failureThreshold` / `successThreshold`** — how many consecutive failures/successes trigger a state change.

Inspect probe behavior:

```sh
kubectl describe pod <pod> -n synapsvault
```

Look at the `Liveness`/`Readiness` sections and the `Events` at the bottom for probe failures.

## Troubleshooting

- **Pods stuck in `Pending`** — check node capacity and scheduling events: `kubectl describe pod <pod> -n synapsvault`.
- **Pods in `CrashLoopBackOff`** — check logs: `kubectl logs <pod> -n synapsvault --previous`.
- **Ingress has no address** — confirm an ingress controller is installed and running.
- **TLS certificate not issued** — check cert-manager: `kubectl describe certificate -n synapsvault` and `kubectl describe certificaterequest -n synapsvault`.
- **HPA shows `<unknown>` targets** — metrics-server is missing or not ready.