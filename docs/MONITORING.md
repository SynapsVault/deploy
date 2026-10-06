# Monitoring Setup Guide

This guide walks through deploying the observability stack for the application: **Prometheus** (metrics collection), **Grafana** (dashboards), and **Alertmanager** (alert routing). It also covers wiring the backend metrics endpoint so Prometheus can scrape it.

All configuration referenced here lives in the [`monitoring/`](../monitoring) directory.

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
- [Troubleshooting](#troubleshooting)

## Overview

The monitoring stack consists of:

| Component | Purpose | Config file |
| --- | --- | --- |
| Prometheus | Scrapes and stores metrics | [`monitoring/prometheus.yml`](../monitoring/prometheus.yml) |
| Alert rules | Defines alerting conditions | [`monitoring/alert-rules.yml`](../monitoring/alert-rules.yml) |
| Alertmanager | Routes alerts to notification channels | [`monitoring/alertmanager.yml`](../monitoring/alertmanager.yml) |
| Grafana | Visualizes metrics via dashboards | [`monitoring/grafana/`](../monitoring/grafana) |
| Docker Compose | Local/all-in-one deployment | [`monitoring/docker-compose.yml`](../monitoring/docker-compose.yml) |

> Adjust the paths above if your repository layout differs. The steps below assume the `monitoring/` directory at the repository root.

## Prerequisites

- Docker and Docker Compose (for the self-hosted option), **or** accounts with a managed Prometheus/Grafana provider.
- Network access from Prometheus to the backend metrics endpoint.
- SMTP credentials (for email alerts) and/or a Slack incoming webhook URL (for Slack alerts).

## 1. Wire the backend metrics endpoint

Prometheus scrapes metrics over HTTP. The backend must expose a metrics endpoint (commonly `/metrics`) in the Prometheus exposition format.

1. Ensure the backend exposes the metrics endpoint. Confirm it responds:

   ```bash
   curl -s http://localhost:8080/metrics | head
   ```

   You should see lines such as `# HELP ...` and `# TYPE ...` followed by metric samples.

2. Point Prometheus at the endpoint. In [`monitoring/prometheus.yml`](../monitoring/prometheus.yml), the scrape target is defined under `scrape_configs`. Update the target to match your backend host and port:

   ```yaml
   scrape_configs:
     - job_name: "backend"
       metrics_path: /metrics
       static_configs:
         - targets: ["backend:8080"]   # host:port of the backend metrics endpoint
   ```

   - If Prometheus runs in Docker Compose on the same network, use the service name (e.g. `backend:8080`).
   - If Prometheus runs outside the backend's network, use a reachable host/IP (e.g. `host.docker.internal:8080` on Docker Desktop, or the backend's public address).

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

The repository ships a Compose file at [`monitoring/docker-compose.yml`](../monitoring/docker-compose.yml) that starts Prometheus, Alertmanager, and Grafana together.

1. Review and adjust the Compose file and the referenced config files:
   - [`monitoring/prometheus.yml`](../monitoring/prometheus.yml) — scrape targets and rule file references.
   - [`monitoring/alert-rules.yml`](../monitoring/alert-rules.yml) — alerting rules.
   - [`monitoring/alertmanager.yml`](../monitoring/alertmanager.yml) — notification routing.

2. Start the stack:

   ```bash
   cd monitoring
   docker compose up -d
   ```

3. Confirm the containers are running:

   ```bash
   docker compose ps
   ```

4. Access the UIs:
   - Prometheus: <http://localhost:9090>
   - Alertmanager: <http://localhost:9093>
   - Grafana: <http://localhost:3000> (default credentials `admin` / `admin` — change on first login)

5. To stop the stack:

   ```bash
   docker compose down
   ```

### Option B: Managed services

If you prefer managed infrastructure, use a hosted Prometheus (e.g. Grafana Cloud, Amazon Managed Service for Prometheus, Google Managed Prometheus) and a hosted Grafana.

1. **Prometheus / metrics backend**
   - Create the managed Prometheus instance and note its remote-write endpoint and credentials.
   - Configure your backend (or a local Prometheus agent) to remote-write metrics to the managed endpoint. If you run a local Prometheus agent, reuse [`monitoring/prometheus.yml`](../monitoring/prometheus.yml) for scrape configs and add a `remote_write` block:

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
     docker compose restart prometheus
     ```

3. Verify the rules loaded: go to **Prometheus → Status → Rules** and confirm the rules from `alert-rules.yml` appear.

## 5. Configure Alertmanager notification channels

Alertmanager routing and receivers are configured in [`monitoring/alertmanager.yml`](../monitoring/alertmanager.yml). The examples below show how to add email and Slack receivers. Replace placeholders with your real values and **do not commit secrets** — use environment variable substitution or a secrets manager.

### Email

Add an email receiver and route alerts to it:

```yaml
global:
  smtp_smarthost: "smtp.example.com:587"
  smtp_from: "alerts@example.com"
  smtp_auth_username: "alerts@example.com"
  smtp_auth_password: "<smtp-password>"   # use a secret, not a literal
  smtp_require_tls: true

route:
  receiver: "email"
  group_by: ["alertname"]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

receivers:
  - name: "email"
    email_configs:
      - to: "oncall@example.com"
        send_resolved: true
```

### Slack

Add a Slack receiver using an incoming webhook URL:

```yaml
receivers:
  - name: "slack"
    slack_configs:
      - api_url: "https://hooks.slack.com/services/<T...>/<B...>/<secret>"
        channel: "#alerts"
        send_resolved: true
        title: "{{ .CommonLabels.alertname }}"
        text: "{{ range .Alerts }}{{ .Annotations.summary }}\n{{ end }}"
```

To route different severities to different channels, use multiple routes:

```yaml
route:
  receiver: "slack"
  group_by: ["alertname"]
  routes:
    - matchers:
        - severity = "critical"
      receiver: "slack"
      continue: false
    - matchers:
        - severity = "warning"
      receiver: "email"
```

After editing, reload Alertmanager:

```bash
curl -X POST http://localhost:9093/-/reload
```

or restart the container:

```bash
docker compose restart alertmanager
```

## 6. Verify the setup

1. **Metrics scraping** — In Prometheus, go to **Status → Targets** and confirm the `backend` target is `UP`.
2. **Rules** — In Prometheus, go to **Status → Rules** and confirm the alert rules are loaded.
3. **Alerts** — In Alertmanager (<http://localhost:9093>), confirm it is reachable and shows any firing alerts.
4. **Notifications** — Trigger a test alert (or use Alertmanager's built-in test) and confirm it arrives in the configured email/Slack channel.
5. **Dashboard** — Open the imported Grafana dashboard and confirm panels show live data.

## Troubleshooting

- **Target is `DOWN`**: verify the metrics endpoint is reachable from the Prometheus container (`docker compose exec prometheus wget -qO- http://backend:8080/metrics`). Check host/port and network configuration.
- **No data in Grafana**: confirm the data source URL is correct and that Prometheus has scraped data (**Prometheus → Graph**, query `up`).
- **Rules not loading**: check the `rule_files` path and that the file is mounted into the container. Inspect Prometheus logs: `docker compose logs prometheus`.
- **Alerts not delivered**: check Alertmanager logs (`docker compose logs alertmanager`) and confirm the receiver config, webhook URL, and SMTP credentials are correct.
- **Config errors**: validate configs before reloading:
  - Prometheus: `promtool check config monitoring/prometheus.yml`
  - Alertmanager: `amtool check-config monitoring/alertmanager.yml`