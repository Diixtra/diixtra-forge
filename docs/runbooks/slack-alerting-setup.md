# Slack Alerting Setup

One-time manual steps to connect GitOps-managed alert rules to Slack.

**Architecture**: PrometheusRule CRDs in Git → Alloy syncs to Grafana Cloud →
Grafana Cloud evaluates rules → Slack notification via webhook.

## 1. Create a Slack App and Incoming Webhook

1. Go to [api.slack.com/apps](https://api.slack.com/apps) and click **Create New App**
2. Choose **From scratch**, name it `Forge Alerts`, select your workspace
3. Under **Features → Incoming Webhooks**, toggle **Activate Incoming Webhooks** on
4. Click **Add New Webhook to Workspace**
5. Select the `#forge-alerts` channel and click **Allow**
6. Copy the webhook URL (looks like `https://hooks.slack.com/services/T.../B.../xxx`)

## 2. Configure Grafana Cloud Contact Point

1. Log in to [grafana.com](https://grafana.com) → your Grafana Cloud instance
2. Navigate to **Alerting → Contact points**
3. Click **Add contact point**
4. Name: `Slack #forge-alerts`
5. Integration: **Slack**
6. Webhook URL: paste the URL from step 1
7. Channel: `#forge-alerts`
8. Title: `[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}`
9. Click **Test** to verify, then **Save**

## 3. Configure Notification Policy (Severity Routing)

1. Navigate to **Alerting → Notification policies**
2. Edit the **Default policy** to use the `Slack #forge-alerts` contact point
3. Add a **nested policy** for critical alerts:
   - Matching labels: `severity = critical`
   - Contact point: `Slack #forge-alerts`
   - Group by: `alertname` (etcd alerts lack a `namespace` label, so avoid grouping by it)
   - Group wait: `30s` (send quickly)
   - Group interval: `5m`
   - Repeat interval: `4h`
4. Add a **nested policy** for warning alerts:
   - Matching labels: `severity = warning`
   - Contact point: `Slack #forge-alerts`
   - Group by: `alertname`
   - Group wait: `1m`
   - Group interval: `10m`
   - Repeat interval: `12h`

## 4. Verify End-to-End

After Flux deploys the PrometheusRule CRDs and Alloy syncs them:

1. Check Alloy logs for successful rule sync:
   ```bash
   kubectl logs -n monitoring -l app.kubernetes.io/name=grafana-alloy --tail=20 | grep mimir
   ```

2. Verify rules appear in Grafana Cloud:
   - Navigate to **Alerting → Alert rules**
   - You should see rule groups: `etcd`, `control-plane-restarts`, `node-health`,
     `pod-health`, `resource-pressure`

3. Check etcd metrics are flowing:
   ```bash
   # On the control plane node, verify Alloy can reach etcd metrics
   kubectl logs -n monitoring -l app.kubernetes.io/name=grafana-alloy --tail=20 | grep etcd
   ```

## Troubleshooting

**Rules not appearing in Grafana Cloud:**
- Check Alloy has the `grafana-alloy-prometheusrule-reader` ClusterRoleBinding
- Verify `mimir.rules.kubernetes` logs: `kubectl logs -n monitoring -l app.kubernetes.io/name=grafana-alloy | grep -i "rules\|mimir"`
- Confirm the Mimir ruler URL is correct in `cluster-vars`

**etcd metrics missing:**
- Verify Alloy DaemonSet has `hostNetwork: true`: `kubectl get ds -n monitoring grafana-alloy -o jsonpath='{.spec.template.spec.hostNetwork}'`
- Check the control plane node's Alloy pod: `kubectl logs -n monitoring <alloy-pod-on-control-plane> | grep etcd`
- Verify etcd exposes metrics: `curl -s http://127.0.0.1:2381/metrics | head` (from the control plane node)
