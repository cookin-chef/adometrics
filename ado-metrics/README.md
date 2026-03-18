# ADO Metrics Monitoring

Automated Azure DevOps health and inventory monitoring. Collect metrics from ADO REST API v7.1, commit Markdown and JSON reports to Git, and optionally stream data to Azure Monitor Log Analytics for alerting and Grafana dashboards.

---

## What You Get

### Free (no Azure Monitor required)

- Agent pool health checks every 15 minutes — JSON + Markdown reports committed to Git
- Organization inventory snapshots daily — projects, repos, users, pipelines
- ADO Dashboard widgets showing live report content from Git
- Pipeline build artifacts for every run

### With Azure Monitor Log Analytics (~$5–15/month)

- Historical trends and time-series graphs
- Automated alerts (email + Teams) for critical queue conditions
- Anomaly detection on pipeline count growth
- Grafana dashboard with live panels

---

## Package Contents

```
ado-metrics/
├── lib/
│   ├── AdoAuthHelper.ps1        # PAT → Base64 auth headers
│   ├── AdoHttpHelper.ps1        # Retry logic, pagination, URL normalization
│   └── MetricsHelper.ps1        # Azure Monitor Log Analytics push (optional)
├── scripts/
│   ├── operational/
│   │   ├── Get-AgentPoolMetrics.ps1   # Pool/job metric collection functions
│   │   └── Run-AgentPoolHealth.ps1    # Orchestrator + report generator
│   └── inventory/
│       ├── Get-OrgInventoryMetrics.ps1 # Org-wide inventory functions
│       └── Run-OrgInventory.ps1        # Orchestrator + report generator
├── pipelines/
│   ├── agent-pool-health-pipeline.yml  # Runs every 15 minutes
│   └── org-metrics-pipeline.yml        # Runs daily at 10:00 UTC
├── infrastructure/
│   ├── deploy.ps1                      # One-shot Azure deployment script
│   ├── log-analytics-workspace.bicep   # Log Analytics workspace
│   ├── alert-rules.bicep               # 4 KQL-based alert rules
│   └── action-groups.bicep             # Email + Teams notification groups
├── dashboards/grafana/
│   └── agent-pool-health-dashboard.json  # Importable Grafana dashboard
├── output/
│   └── .gitkeep                        # Keeps output/ tracked in Git
├── .gitignore
├── README.md
└── QUICKSTART.md
```

---

## Quick Start (30 minutes)

See **[QUICKSTART.md](QUICKSTART.md)** for a step-by-step checklist.

---

## Detailed Setup

### 1. Repository Setup

Clone or copy this `ado-metrics/` directory into your Azure DevOps repository. The pipeline definitions expect this folder at the repo root.

```bash
git clone https://dev.azure.com/YOUR_ORG/YOUR_PROJECT/_git/YOUR_REPO
cp -r ado-metrics/ <repo-root>/
```

### 2. Configure Your Organization Name

Edit both pipeline YAML files and replace `YOUR_ORG_NAME_HERE`:

- `pipelines/agent-pool-health-pipeline.yml` — line with `value: 'YOUR_ORG_NAME_HERE'`
- `pipelines/org-metrics-pipeline.yml` — line with `value: 'YOUR_ORG_NAME_HERE'`

### 3. Create a PAT Token

Go to **Azure DevOps → User Settings → Personal Access Tokens → New Token**.

Required scopes:

| Scope | Reason |
|-------|--------|
| Agent Pools (Read) | List pools and job requests |
| Project and Team (Read) | List projects |
| Code (Read) | List repositories |
| Build (Read) | List pipelines and build definitions |
| Member Entitlement Management (Read) | Count users |
| Graph (Read) | Count users (preferred method) |

### 4. Variable Group

Create a variable group named **`ado-metrics-config`** in **Pipelines → Library**:

| Variable | Value | Secret? |
|----------|-------|---------|
| `ADO_PAT` | Your PAT token | ✅ Yes |
| `ENABLE_METRICS_PUSH` | `false` (or `true` if using Azure Monitor) | No |
| `LOG_ANALYTICS_WORKSPACE_ID` | Workspace GUID (if using Azure Monitor) | No |
| `LOG_ANALYTICS_SHARED_KEY` | Workspace shared key | ✅ Yes |

### 5. Create Pipelines

1. Go to **Pipelines → New Pipeline**
2. Select your repository
3. Choose **Existing Azure Pipelines YAML file**
4. Select `ado-metrics/pipelines/agent-pool-health-pipeline.yml`
5. Repeat for `org-metrics-pipeline.yml`

**Grant permissions:**
- Both pipelines need access to the `ado-metrics-config` variable group
- Grant the build service account **Contribute** permission on the repository

### 6. (Optional) Deploy Azure Monitor

```powershell
cd ado-metrics/infrastructure

.\deploy.ps1 `
  -ResourceGroupName "rg-ado-metrics" `
  -Location          "eastus" `
  -DevOpsEmail       "devops@company.com" `
  -TeamsWebhookUrl   "https://company.webhook.office.com/..."

# Preview without deploying:
.\deploy.ps1 ... -WhatIf
```

Then add the credentials from `deployment-credentials.txt` to the variable group and set `ENABLE_METRICS_PUSH=true`.

---

## Configuration Reference

### Health State Thresholds

| State | Condition |
|-------|-----------|
| 🔴 Critical | Oldest queued job ≥ **15 min** OR ≥ **10 jobs** in queue |
| 🟡 Warning | Oldest queued job ≥ **5 min** OR ≥ **5 jobs** in queue |
| 🟢 Healthy | All metrics below Warning thresholds |

### Pipeline Schedule

| Pipeline | Schedule | Purpose |
|----------|----------|---------|
| `agent-pool-health-pipeline.yml` | Every 15 min | Real-time health check |
| `org-metrics-pipeline.yml` | Daily 10:00 UTC | Inventory snapshot |

---

## Example Outputs

### Agent Pool Health Report (Markdown)

```markdown
# Azure DevOps Agent Pool Health Report

**Organization:** `myorg`
**Generated:** 2026-03-18 14:30:00 UTC

## Summary

| 🟢 Healthy | 🟡 Warning | 🔴 Critical | Total |
|-----------|-----------|------------|-------|
| 4 | 1 | 1 | 6 |

## Pool Status

| Pool | Type | Hosted | Queued | Running | Oldest Queued (min) | Health State |
|------|------|--------|--------|---------|---------------------|--------------|
| Production-Pool | automation | No | 12 | 4 | 18.3 | 🔴 **Critical** |
| Staging-Pool | automation | No | 6 | 2 | 8.1 | 🟡 Warning |
| Azure Pipelines | automation | Yes | 0 | 1 | 0.0 | 🟢 Healthy |
```

### Organization Inventory (Markdown)

```markdown
# Azure DevOps Organization Inventory

## Overview

| Metric | Value |
|--------|-------|
| 📁 Projects | 12 |
| 📦 Repositories | 87 |
| 👥 Users | 143 |
| ⚙️ Total Pipelines | 234 |
| ☁️ Microsoft-Hosted Pipelines | 189 |
| 🖥️ Self-Hosted Pipelines | 41 |
| 🔍 SonarQube Integrations | 18 |
```

---

## Where to See Outputs

### 1. Git Repository

Reports are committed to `ado-metrics/output/` after each pipeline run:
- `output/agent-pool-health.json` — structured JSON for automation
- `output/agent-pool-health.md` — human-readable Markdown
- `output/ado-org-metrics.json` — inventory JSON
- `output/ado-org-metrics.md` — inventory Markdown

### 2. ADO Dashboard Widgets

1. Create a new dashboard in **Azure DevOps → Overview → Dashboards**
2. Add **Markdown** widget
3. Point it to the raw file URL in your repo:
   ```
   https://dev.azure.com/YOUR_ORG/YOUR_PROJECT/_git/YOUR_REPO?path=/ado-metrics/output/agent-pool-health.md
   ```

### 3. Grafana

1. Install the **Azure Monitor** data source plugin
2. Configure a connection to your Log Analytics workspace
3. Import `dashboards/grafana/agent-pool-health-dashboard.json`
4. The dashboard auto-refreshes every 30 seconds

### 4. Build Artifacts

Each pipeline run publishes an artifact (`agent-pool-health-report` or `org-inventory-report`) containing the report files for download.

---

## Troubleshooting

### "401 Unauthorized" errors

- Verify `ADO_PAT` in the variable group is correct and not expired
- Check that the PAT has all required scopes listed in the setup section

### "No agent pools found"

- Confirm `ADO_ORGANIZATION` in the pipeline YAML matches your actual org name
- Test: `https://dev.azure.com/YOUR_ORG/_apis/distributedtask/pools?api-version=7.1` in a browser while authenticated

### Reports not committed to Git

- Verify the Build Service has **Contribute** permission on the repository
- Check the "Allow scripts to access the OAuth token" option on each pipeline

### Metrics not appearing in Log Analytics

- Log Analytics ingestion takes **5–15 minutes** after the first POST
- Run `Test-MetricsConnection` from MetricsHelper to validate credentials
- Check that `ENABLE_METRICS_PUSH=true` in the variable group

### User count returns 0

- The Graph API requires the **Graph (Read)** PAT scope
- The fallback User Entitlements API requires **Member Entitlement Management (Read)**

---

## Cost Breakdown

| Component | Cost |
|-----------|------|
| Log Analytics (< 1 GB/day) | ~$2–5/month |
| Alert rules (4 rules) | ~$0.10/month |
| Action groups | Free |
| **Total** | **~$5–15/month** |

Free tier: 5 GB/month data ingestion included with new workspaces.

---

## Security Best Practices

- Store the PAT as a **secret variable** in the ADO variable group (never in YAML)
- Store the Log Analytics shared key as a **secret variable**
- The `infrastructure/deployment-credentials.txt` file is in `.gitignore` — never commit it
- Use a dedicated service account for the pipeline PAT with minimum required scopes
- Rotate PAT tokens every 90 days; update the variable group when rotating
- Consider using Azure Key Vault-linked variable groups for additional security

---

## Success Metrics

After setup you should see:

- ✅ `agent-pool-health-pipeline` running on schedule every 15 minutes
- ✅ `output/agent-pool-health.json` updated in Git after each run
- ✅ ADO dashboard widget showing current pool health
- ✅ (If Azure Monitor enabled) `ADOOperationalMetrics_CL` table populated with data
- ✅ Zero pipeline failures unless a pool is genuinely in Critical state
