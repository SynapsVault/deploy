# Kubernetes Deployment

This guide covers deploying the application to a production Kubernetes cluster using the manifests in [`k8s/`](../k8s/).

## Prerequisites

Before deploying, ensure you have the following available:

- **kubectl** — the Kubernetes CLI, matching (or within one minor version of) your cluster. Verify with `kubectl version --client`.
- **kustomize** — used to build the manifests. `kubectl` ships with `kustomize` built in (`kubectl kustomize`), but a standalone `kustomize` binary is also supported. Verify with `kustomize version`.
- **A Kubernetes cluster** — with a valid `kubectl` context configured. Confirm with `kubectl config current-context` and `kubectl cluster-info`.
- **An ingress controller** — e.g. [ingress-nginx](https://kubernetes.github.io/ingress-nginx/). The `Ingress` resource in `k8s/` assumes an ingress controller is installed and watching `Ingress` resources.
- **cert-manager** — for automatic TLS certificate issuance. Install it and configure a `ClusterIssuer` (e.g. Let's Encrypt) before applying the ingress. See the [cert-manager docs](https://cert-manager.io/docs/).

## 1. Create the secrets

The deployment expects application secrets to exist in the target namespace before the workloads are applied. Create them out-of-band so they are never committed to the repository.

Create the namespace first (if it does not already exist):

```sh
kubectl create namespace <namespace>
```

Create the application secret from literal values:

```sh
kubectl create secret generic app-secrets \
  --namespace <namespace> \
  --from-literal=DATABASE_URL='postgres://user:pass@host:5432/db' \
  --from-literal=SECRET_KEY='<random-secret>' \
  --from-literal=OTHER_SECRET='<value>'
```

Alternatively, create the secret from an env file (recommended so values are not left in shell history):

```sh
kubectl create secret generic app-secrets \
  --namespace <namespace> \
  --from-env-file=./secrets.env
```

If you need to update an existing secret:

```sh
kubectl create secret generic app-secrets \
  --namespace <namespace> \
  --from-env-file=./secrets.env \
  --dry-run=client -o yaml | kubectl apply -f -
```

> **Note:** After rotating secrets, restart the workloads so the new values are picked up:
> `kubectl rollout restart deployment/<name> -n <namespace>`.

## 2. Apply the manifests

Build and apply everything under `k8s/` with kustomize:

```sh
kubectl apply -k k8s/
```

To preview what will be applied without changing the cluster:

```sh
kubectl kustomize k8s/
```

To target a specific overlay (if one exists):

```sh
kubectl apply -k k8s/overlays/production
```

## 3. Verify the rollout

Watch the rollout status of each deployment:

```sh
kubectl rollout status deployment/<name> -n <namespace>
```

Inspect the resulting resources:

```sh
kubectl get all -n <namespace>
kubectl get ingress -n <namespace>
kubectl get pods -n <namespace> -o wide
```

Check that pods are `Running` and `Ready`, and that the ingress has an address assigned. If a pod is not becoming ready, inspect it:

```sh
kubectl describe pod <pod> -n <namespace>
kubectl logs <pod> -n <namespace>
```

## 4. Scale

Scale a deployment manually:

```sh
kubectl scale deployment/<name> --replicas=5 -n <namespace>
```

> **Note:** If a HorizontalPodAutoscaler (HPA) manages the deployment, manual scaling will be overridden by the HPA. Adjust the HPA's `minReplicas`/`maxReplicas` instead (see below).

## 5. Roll back a deployment

Every `kubectl apply` of a changed pod template creates a new ReplicaSet, giving you a revision history to roll back through.

View the rollout history:

```sh
kubectl rollout history deployment/<name> -n <namespace>
```

Roll back to the previous revision:

```sh
kubectl rollout undo deployment/<name> -n <namespace>
```

Roll back to a specific revision:

```sh
kubectl rollout undo deployment/<name> --to-revision=<n> -n <namespace>
```

Confirm the rollback completed:

```sh
kubectl rollout status deployment/<name> -n <namespace>
```

## 6. Autoscaling (HPA)

The `HorizontalPodAutoscaler` in `k8s/` scales the deployment based on CPU utilization. Key fields:

- **`scaleTargetRef`** — points at the deployment to scale.
- **`minReplicas`** — the floor; the deployment never scales below this.
- **`maxReplicas`** — the ceiling; the deployment never scales above this.
- **`metrics`** — typically `type: Resource`, `resource.name: cpu`, with a `target.averageUtilization` percentage (e.g. `70`).

The HPA requires the [metrics-server](https://github.com/kubernetes-sigs/metrics-server) to be installed in the cluster; without it, the HPA cannot read utilization and will not scale. Verify metrics are available:

```sh
kubectl top pods -n <namespace>
kubectl get hpa -n <namespace>
```

To change scaling behavior, edit the HPA (or its manifest in `k8s/`) and re-apply:

```sh
kubectl edit hpa <name> -n <namespace>
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
kubectl describe pod <pod> -n <namespace>
```

Look at the `Liveness`/`Readiness` sections and the `Events` at the bottom for probe failures.

## Troubleshooting

- **Pods stuck in `Pending`** — check node capacity and scheduling events: `kubectl describe pod <pod> -n <namespace>`.
- **Pods in `CrashLoopBackOff`** — check logs: `kubectl logs <pod> -n <namespace> --previous`.
- **Ingress has no address** — confirm an ingress controller is installed and running.
- **TLS certificate not issued** — check cert-manager: `kubectl describe certificate -n <namespace>` and `kubectl describe certificaterequest -n <namespace>`.
- **HPA shows `<unknown>` targets** — metrics-server is missing or not ready.