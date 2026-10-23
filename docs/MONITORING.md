# Monitoring on Kubernetes

The monitoring stack (Prometheus, Alertmanager, Grafana) is deployed to
Kubernetes with the [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
Helm chart. The manifests in `monitoring/` provide the pieces that are specific
to this project:

- `monitoring/servicemonitors.yaml` — `ServiceMonitor` resources so Prometheus
discovers the backend and frontend targets via Kubernetes service discovery
(instead of the static docker-compose targets in `prometheus.yml`).
- `monitoring/prometheusrule.yaml` — the alert rules from
`monitoring/alert-rules.yml` loaded as a `PrometheusRule` custom resource.

## Prerequisites

- A Kubernetes cluster with `kubectl` configured
- [Helm 3](https://helm.sh/docs/intro/install/)
All configuration referenced here lives in the [`monitoring/`](../monitoring) directory.

> **Monitoring is optional.** The monitoring services in the root [`docker-compose.yml`](../docker-compose.yml) are gated behind the `monitoring` Compose profile. A plain `docker compose up` starts only the application services; add `--profile monitoring` to also start Prometheus, Grafana, and Alertmanager.

## Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [1. Wire the backend metrics endpoint](#1-wire-the-backend-metrics-endpoint)
- [2. Deploy Prometheus and Grafana](#2-deploy-prometheus-and-grafana)
  - [Option A: Docker Compose](#option-a-docker-compose)
  - [Option B: Managed services](#option-b-managed-services)
- [3. Import the Grafana dashboard](#3-import-the-grafana-dashboard)
- [4. Load the alert rules](#4-load-the-alert-rules)
- [5. Configure Alertmanager notification channels](#5-configure-alertmanager-notification-channels)
  - [Email](#email)
  - [Slack](#slack)
- [6. Verify the setup](#6-verify-the-setup)
- [Runbooks](#runbooks)
- [Required metrics](#required-metrics)
- [Troubleshooting](#troubleshooting)

## Overview

The monitoring stack consists of:

| Component | Purpose | Config file |
| --- | --- | --- |
| Prometheus | Scrapes and stores metrics | [`monitoring/prometheus.yml`](../monitoring/prometheus.yml) |
| Alert rules | Defines alerting conditions | [`monitoring/alert-rules.yml`](../monitoring/alert-rules.yml) |
| Alertmanager | Routes alerts to notification channels | [`monitoring/alertmanager.yml`](../monitoring/alertmanager.yml) |
| Grafana | Visualizes metrics via dashboards | [`monitoring/grafana/`](../monitoring/grafana) |
| Docker Compose | Local/all-in-one deployment | [`docker-compose.yml`](../docker-compose.yml) |

> Adjust the paths above if your repository layout differs. The steps below assume the `monitoring/` directory at the repository root.

## Prerequisites

- Docker and Docker Compose (for the self-hosted option), **or** accounts with a managed Prometheus/Grafana provider.
- Network access from Prometheus to the backend metrics endpoint.
- SMTP credentials (for email alerts) and/or a Slack incoming webhook URL (for Slack alerts).

## 1. Wire the backend metrics endpoint

Prometheus scrapes metrics over HTTP. The backend must expose a metrics endpoint (commonly `/metrics`) in the Prometheus exposition format.

1. Ensure the backend exposes the metrics endpoint. Confirm it responds:

   ```bash
   curl -s http://localhost:3000/metrics | head
   ```

   You should see lines such as `# HELP ...` and `# TYPE ...` followed by metric samples.

2. Point Prometheus at the endpoint. In [`monitoring/prometheus.yml`](../monitoring/prometheus.yml), the scrape target is defined under `scrape_configs`. Update the target to match your backend host and port:

   ```yaml
   scrape_configs:
     - job_name: "backend"
       metrics_path: /metrics
       static_configs:
         - targets: ["backend:3000"]   # host:port of the backend metrics endpoint
   ```

   - If Prometheus runs in Docker Compose on the same network, use the service name (e.g. `backend:3000`).
   - If Prometheus runs outside the backend's network, use a reachable host/IP (e.g. `host.docker.internal:3000` on Docker Desktop, or the backend's public address).

3. If the metrics endpoint requires authentication, add credentials to the scrape config:

   ```yaml
   scrape_configs:
     - job_name: "backend"
       metrics_path: /metrics
       scheme: https
       basic_auth:
         username: metrics
         password_file: /etc/prometheus/metrics_password
       static_configs:
         - targets: ["backend.example.com:443"]
   ```

   Mount the password file into the Prometheus container and keep it out of version control.

## 2. Deploy Prometheus and Grafana

### Option A: Docker Compose

The repository ships a Compose file at [`docker-compose.yml`](../docker-compose.yml) that starts Prometheus, Alertmanager, and Grafana together through the `monitoring` profile.

> **Compose profiles:** The monitoring services in the root [`docker-compose.yml`](../docker-compose.yml) are assigned to the `monitoring` profile. They are **not** started by a plain `docker compose up`. To include them, pass the profile explicitly:
>
> ```bash
> docker compose --profile monitoring up -d
> ```
>
> To start only the application services (the default, faster for local dev), omit the flag:
>
> ```bash
> docker compose up -d
> ```

1. Review and adjust the Compose file and the referenced config files:
   - [`monitoring/prometheus.yml`](../monitoring/prometheus.yml) — scrape targets and rule file references.
   - [`monitoring/alert-rules.yml`](../monitoring/alert-rules.yml) — alerting rules.
   - [`monitoring/alertmanager.yml`](../monitoring/alertmanager.yml) — notification routing.

2. Start the stack. From the repository root, include the `monitoring` profile:

   ```bash
   docker compose --profile monitoring up -d
   ```

   Alternatively, start the standalone monitoring Compose file:

   ```bash
   cd monitoring
   docker compose up -d
   ```

3. Confirm the containers are running:

   ```bash
   docker compose --profile monitoring ps
   ```

4. Access the UIs:
   - Prometheus: <http://localhost:9090>
   - Alertmanager: <http://localhost:9093>
   - Grafana: <http://localhost:3000> (default credentials `admin` / `admin` — change on first login)

5. To stop the stack:

   ```bash
   docker compose --profile monitoring down
   ```

### Option B: Managed services

If you prefer managed infrastructure, use a hosted Prometheus (e.g. Grafana Cloud, Amazon Managed Service for Prometheus, Google Managed Prometheus) and a hosted Grafana.

## Install kube-prometheus-stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set grafana.adminPassword="$GRAFANA_ADMIN_PASSWORD"
```

Wait for the operator and Prometheus to become ready:

```bash
kubectl -n monitoring rollout status deploy/monitoring-kube-prometheus-operator
kubectl -n monitoring rollout status statefulset/prometheus-monitoring-kube-prometheus-prometheus
```

## Apply the project monitoring resources
     ```yaml
     remote_write:
       - url: https://<managed-prometheus-endpoint>/api/v1/write
         basic_auth:
           username: <user-id>
           password: <api-key>
     ```

2. **Grafana**
   - Create the hosted Grafana instance.
   - Add a data source pointing at the managed Prometheus instance (see [step 3](#3-import-the-grafana-dashboard)).

3. **Alerting**
   - Managed Prometheus services typically support alert rules and Alertmanager-compatible routing. Load the rules from [`monitoring/alert-rules.yml`](../monitoring/alert-rules.yml) into the managed rule store, and configure notification channels in the provider's UI (see [step 5](#5-configure-alertmanager-notification-channels)).

## 3. Import the Grafana dashboard

1. Log in to Grafana.
2. Add the Prometheus data source:
   - Go to **Connections → Data sources → Add data source → Prometheus**.
   - Set the URL to your Prometheus instance (e.g. `http://prometheus:9090` when running in Compose, or the managed endpoint URL).
   - Click **Save & test** and confirm the connection succeeds.
3. Import the dashboard:
   - Go to **Dashboards → New → Import**.
   - Upload the dashboard JSON from [`monitoring/grafana/`](../monitoring/grafana) (or paste its contents).
   - Select the Prometheus data source created above.
   - Click **Import**.
4. The dashboard should now render panels populated by the backend metrics.

> If the dashboard JSON references a data source by name, ensure the name matches the one you created, or update the variable when importing.

## 4. Load the alert rules

Alert rules are defined in [`monitoring/alert-rules.yml`](../monitoring/alert-rules.yml).

1. Ensure Prometheus references the rule file. In [`monitoring/prometheus.yml`](../monitoring/prometheus.yml):

   ```yaml
   rule_files:
     - /etc/prometheus/alert-rules.yml
   ```

   Confirm the Compose file mounts `alert-rules.yml` to that path inside the Prometheus container.

2. Reload Prometheus to pick up rule changes:
   - Via the UI: **Status → Configuration → Reload** (requires `--web.enable-lifecycle`), or
   - Via the API:

     ```bash
     curl -X POST http://localhost:9090/-/reload
     ```

   - Or restart the container:

     ```bash
     docker compose --profile monitoring restart prometheus
     ```

3. Verify the rules loaded: go to **Prometheus → Status → Rules** and confirm the rules from `alert-rules.yml` appear.

## 5. Configure Alertmanager notification channels

Alertmanager routing and receivers are configured in [`monitoring/alertmanager.yml`](../monitoring/alertmanager.yml). The examples below show how to add email and Slack receivers. Replace placeholders with your real credentials and keep secrets out of version control.
Alertmanager routing and receivers are configured in [`monitoring/alertmanager.yml`](../monitoring/alertmanager.yml). The examples below show how to add email and Slack receivers. Replace placeholders with your own values and keep secrets out of version control.

### Email

```yaml
receivers:
  - name: email
    email_configs:
      - to: oncall@example.com
        from: alerts@example.com
        smarthost: smtp.example.com:587
        auth_username: alerts@example.com
        auth_password_file: /etc/alertmanager/smtp_password
      - to: alerts@example.com
        from: alertmanager@example.com
        smarthost: smtp.example.com:587
        auth_username: alertmanager@example.com
        auth_password_file: /etc/alertmanager/smtp_password
        auth_password: <smtp-password>
        require_tls: true
```

### Slack

```yaml
receivers:
  - name: slack
    slack_configs:
      - api_url_file: /etc/alertmanager/slack_webhook_url
        channel: '#alerts'
        send_resolved: true
```

Mount the referenced secret files into the Alertmanager container and keep them out of version control.

## 6. Verify the setup

1. Confirm Prometheus targets are up: **Prometheus → Status → Targets**.
2. Confirm rules are loaded: **Prometheus → Status → Rules**.
3. Trigger a test alert (e.g. temporarily lower a threshold) and confirm it reaches Alertmanager and the configured notification channel.
4. Confirm the alert resolves and a resolved notification is delivered (if `send_resolved` is enabled).

## Runbooks

Every alert in [`monitoring/alert-rules.yml`](../monitoring/alert-rules.yml) links to an operational runbook via its `runbook_url` annotation. Runbooks live in [`docs/runbooks/`](./runbooks) — see the [runbook index](./runbooks/README.md) for the full list.

When you add or rename an alert, add a matching runbook under `docs/runbooks/` and point the alert's `runbook_url` at it.

## Troubleshooting

- **No metrics in Prometheus:** check the scrape target, network reachability, and that the backend `/metrics` endpoint responds.
- **Rules not loading:** validate the YAML and confirm the rule file is mounted at the path in `rule_files`.
- **Alerts not delivered:** check Alertmanager logs and confirm receiver credentials/secret files are correct.
- **Dashboard empty:** confirm the Grafana data source points at the correct Prometheus instance.
        channel: "#alerts"
        send_resolved: true
```

Route alerts to the receivers in the `route` block, then reload Alertmanager:

```bash
kubectl apply -f monitoring/servicemonitors.yaml
kubectl apply -f monitoring/prometheusrule.yaml
```

## Verify

- Prometheus targets: port-forward the Prometheus service and open
  **Status → Targets**; the `backend` and `frontend` jobs should be `UP`.

  ```bash
  kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090
  ```

- Alert rules: open **Status → Rules** and confirm the project alert group is
  loaded.
- Grafana: port-forward the Grafana service and log in with the admin password.

  ```bash
  kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
  ```
## 6. Verify the setup

1. Confirm Prometheus is scraping the backend: **Prometheus → Status → Targets** should show the `backend` job as `UP`.
2. Confirm the required metrics are present (see [Required metrics](#required-metrics)).
3. Trigger a test alert (e.g. stop the backend) and confirm it reaches your notification channel.

## Required metrics

The alert rules in [`monitoring/alert-rules.yml`](../monitoring/alert-rules.yml) depend on the backend exporting the following metric families. If any of these are missing from the `/metrics` output, the corresponding alerts will silently never fire.

| Metric family | Used for |
| --- | --- |
| `db_connection_pool_*` | Database connection pool saturation and exhaustion alerts |
| `stellar_rpc_*` | Stellar RPC latency, error rate, and availability alerts |
| `soroban_rpc_*` | Soroban RPC latency, error rate, and availability alerts |

Verify each family is exported before relying on the alerts:

```bash
curl -s http://localhost:3000/metrics \
  | grep -E '^(db_connection_pool_|stellar_rpc_|soroban_rpc_)' \
  | awk -F'{' '{print $1}' | awk '{print $1}' | sort -u
```

If a family is absent, the backend is missing instrumentation for it. Open an issue in the backend repository (`SynapsVault/backend`) to add the missing metrics. The alert rules include `absent()` checks that fire when a required metric family is not exported, so missing instrumentation surfaces as an alert rather than failing silently.

## Troubleshooting

- **Targets show `DOWN`**: check the scrape target host/port and that the backend is reachable from Prometheus.
- **No metrics in Grafana**: confirm the data source URL and that the dashboard uses the correct data source.
- **Alerts never fire**: verify the required metrics are exported (see [Required metrics](#required-metrics)) and that the rule file is loaded.
- **Reload fails**: ensure Prometheus was started with `--web.enable-lifecycle`.
      - api_url: https://hooks.slack.com/services/<workspace>/<channel>/<token>
        channel: '#alerts'
        send_resolved: true
```

Route alerts to the receivers under `route:` and reload Alertmanager (or restart the container with `docker compose --profile monitoring restart alertmanager`).

## 6. Verify the setup

1. Confirm Prometheus targets are up: **Prometheus → Status → Targets**.
2. Confirm rules are loaded: **Prometheus → Status → Rules**.
3. Confirm Grafana renders the dashboard panels with live data.
4. Trigger a test alert (e.g. temporarily lower a threshold in `alert-rules.yml`) and confirm it reaches the configured receiver.

## Notes

- The `ServiceMonitor` resources select the backend and frontend `Service`s by
  their labels; keep those labels in sync with `k8s/` manifests.
- The `PrometheusRule` mirrors `monitoring/alert-rules.yml`. When you change the
  alert rules, update both files (or regenerate the `PrometheusRule` from the
  YAML) so Kubernetes and docker-compose stay consistent.
- **Monitoring containers not started:** they are behind the `monitoring` profile. Start them with `docker compose --profile monitoring up -d`.
- **Prometheus target down:** verify the backend metrics endpoint is reachable from the Prometheus container and the scrape target host/port is correct.
- **No alerts delivered:** check Alertmanager logs (`docker compose --profile monitoring logs alertmanager`) and confirm receiver credentials and routing are correct.
- **Grafana shows no data:** confirm the Prometheus data source URL and that the dashboard queries match your metric names.
