# Quick Start Guide

Get ADO Metrics Monitoring running in **30 minutes**.

---

## Prerequisites

- Azure DevOps organization with at least one agent pool
- Permission to create pipelines and variable groups
- Git client installed locally

---

## Step 1: Prepare Repository (5 min)

- [ ] Create or select an Azure DevOps Git repository for this monitoring solution
- [ ] Clone the repository locally:
  ```bash
  git clone https://dev.azure.com/YOUR_ORG/YOUR_PROJECT/_git/YOUR_REPO
  cd YOUR_REPO
  ```
- [ ] Copy the `ado-metrics/` folder into the repository root
- [ ] Commit and push the files:
  ```bash
  git add ado-metrics/
  git commit -m "feat: add ADO metrics monitoring"
  git push origin main
  ```

---

## Step 2: Configure Organization Name (2 min)

Open each YAML file and replace `YOUR_ORG_NAME_HERE` with your actual ADO organization name (just the name, not the full URL):

- [ ] `ado-metrics/pipelines/agent-pool-health-pipeline.yml`
  ```yaml
  - name: ADO_ORGANIZATION
    value: 'myorg'   # ← replace YOUR_ORG_NAME_HERE
  ```

- [ ] `ado-metrics/pipelines/org-metrics-pipeline.yml`
  ```yaml
  - name: ADO_ORGANIZATION
    value: 'myorg'   # ← replace YOUR_ORG_NAME_HERE
  ```

- [ ] Commit and push:
  ```bash
  git add ado-metrics/pipelines/
  git commit -m "config: set ADO organization name"
  git push origin main
  ```

---

## Step 3: Create PAT Token (2 min)

- [ ] Go to **Azure DevOps → top-right avatar → Personal Access Tokens**
- [ ] Click **+ New Token**
- [ ] Name it `ado-metrics-monitoring`
- [ ] Set expiry to 90 days (calendar reminder recommended)
- [ ] Select the following scopes:

  | Scope | Access Level |
  |-------|-------------|
  | Agent Pools | Read |
  | Build | Read |
  | Code | Read |
  | Graph | Read |
  | Member Entitlement Management | Read |
  | Project and Team | Read |

- [ ] Click **Create** and copy the token immediately (it won't be shown again)

---

## Step 4: Create Variable Group (5 min)

- [ ] Go to **Pipelines → Library → + Variable group**
- [ ] Name the group exactly: **`ado-metrics-config`**
- [ ] Add the following variables:

  | Variable Name | Value | Secret? |
  |---------------|-------|---------|
  | `ADO_PAT` | *(paste your PAT token)* | ✅ Lock icon |
  | `ENABLE_METRICS_PUSH` | `false` | No |

  > **Note:** If you deploy Azure Monitor later, add `LOG_ANALYTICS_WORKSPACE_ID` and `LOG_ANALYTICS_SHARED_KEY` here. Leave them out for now.

- [ ] Click **Save**

---

## Step 5: Create Pipelines (5 min)

### Pipeline 1: Agent Pool Health

- [ ] Go to **Pipelines → New Pipeline**
- [ ] Select **Azure Repos Git**
- [ ] Select your repository
- [ ] Choose **Existing Azure Pipelines YAML file**
- [ ] Path: `/ado-metrics/pipelines/agent-pool-health-pipeline.yml`
- [ ] Click **Continue**, then **Save** (do not run yet)
- [ ] **Rename** the pipeline to `Agent Pool Health Check`

### Pipeline 2: Organization Inventory

- [ ] Repeat the above steps
- [ ] Path: `/ado-metrics/pipelines/org-metrics-pipeline.yml`
- [ ] Rename to `Organization Inventory`

---

## Step 6: Grant Permissions (3 min)

### Variable Group Access

- [ ] Go to **Pipelines → Library → `ado-metrics-config`**
- [ ] Click **Pipeline permissions** (lock icon)
- [ ] Add both pipelines you just created

### Repository Write Access (for committing reports)

- [ ] Go to **Project Settings → Repositories → YOUR_REPO → Security**
- [ ] Find the Build Service account: `PROJECT_NAME Build Service (ORG_NAME)`
- [ ] Set **Contribute** to **Allow**

### OAuth Token for Git Push

- [ ] Open each pipeline → **Edit → … → Triggers**
- [ ] Go to the **YAML** tab, click **Variables**
- [ ] *(Alternative)* In each pipeline's **Edit** view, click the 3-dot menu → **Settings**
- [ ] Enable **Allow scripts to access the OAuth token**

  > **Shortcut:** The `persistCredentials: true` checkout option in the YAML handles this automatically if the build service has Contribute access.

---

## Step 7: Test Run (5 min)

- [ ] Go to **Pipelines → Agent Pool Health Check**
- [ ] Click **Run pipeline** → **Run**
- [ ] Wait for the run to complete (should take < 2 minutes)
- [ ] Check the run logs for errors

**Verify success:**
- [ ] The run completed (green checkmark or yellow warning — red only if pools are Critical)
- [ ] Files were created in `ado-metrics/output/`:
  - `agent-pool-health.json`
  - `agent-pool-health.md`
- [ ] A commit appears in the repo history: `chore: update agent pool health metrics [skip ci]`

**Inspect the report:**
```bash
git pull origin main
cat ado-metrics/output/agent-pool-health.md
```

---

## Step 8: Create ADO Dashboard (3 min)

- [ ] Go to **Overview → Dashboards → + New dashboard**
- [ ] Name it `ADO Metrics`
- [ ] Click **Add a widget** → search for **Markdown**
- [ ] Click the pencil (edit) on the widget
- [ ] In the content field, enter:
  ```markdown
  ## Agent Pool Health
  [View Report](https://dev.azure.com/YOUR_ORG/YOUR_PROJECT/_git/YOUR_REPO?path=/ado-metrics/output/agent-pool-health.md)
  ```
- [ ] Add a second Markdown widget for the inventory report:
  ```markdown
  ## Organization Inventory
  [View Report](https://dev.azure.com/YOUR_ORG/YOUR_PROJECT/_git/YOUR_REPO?path=/ado-metrics/output/ado-org-metrics.md)
  ```
- [ ] Click **Done Editing**

> **Tip:** Some ADO dashboard extensions allow embedding file content directly. Search the Marketplace for "Wiki" or "Markdown" widgets that render linked files inline.

---

## ✅ You're Done!

The pipelines will now run automatically:
- **Agent Pool Health**: every 15 minutes
- **Organization Inventory**: every day at 10:00 UTC

---

## Optional: Enable Azure Monitor (15 min extra)

> Adds alerting, historical trends, and Grafana dashboards.

### Deploy Infrastructure

```powershell
cd ado-metrics/infrastructure

.\deploy.ps1 `
  -ResourceGroupName "rg-ado-metrics" `
  -Location          "eastus" `
  -DevOpsEmail       "devops@company.com"
```

### Add Credentials to Variable Group

After deployment completes, open `infrastructure/deployment-credentials.txt` and:

- [ ] Add `LOG_ANALYTICS_WORKSPACE_ID` to the `ado-metrics-config` variable group
- [ ] Add `LOG_ANALYTICS_SHARED_KEY` as a **secret** variable
- [ ] Change `ENABLE_METRICS_PUSH` from `false` to `true`

### Verify Data Flow

After the next pipeline run, query Log Analytics (wait 5–15 min for ingestion):

```kusto
ADOOperationalMetrics_CL
| take 10
```

### Import Grafana Dashboard

- [ ] Install the **Azure Monitor** datasource plugin in Grafana
- [ ] Configure it with your workspace ID
- [ ] **Import** → Upload `ado-metrics/dashboards/grafana/agent-pool-health-dashboard.json`

---

## Troubleshooting

### Pipeline fails with "Access denied" on git push

→ Grant the Build Service **Contribute** permission on the repository (Step 6)

### "401 Unauthorized" in pipeline logs

→ Check that `ADO_PAT` in the variable group is correct and not expired

### Reports not updating in the dashboard

→ Confirm the pipeline ran recently; check **Pipeline → Runs** for errors

### Variable group "not authorized"

→ Go to **Library → `ado-metrics-config` → Pipeline permissions** and add your pipelines

### No data in Log Analytics after enabling metrics push

→ Wait 10–15 minutes for initial ingestion; check `ENABLE_METRICS_PUSH=true` (case-sensitive)

### User count shows 0

→ Add **Graph (Read)** and **Member Entitlement Management (Read)** scopes to your PAT

---

## Next Steps

- Review alert rule thresholds in `infrastructure/alert-rules.bicep` and adjust for your environment
- Add a Teams webhook URL to the `deploy.ps1` call for Teams notifications
- Schedule a PAT rotation reminder in your calendar (every 90 days)
- Consider adding more pools or custom metrics by extending `Get-AgentPoolMetrics.ps1`
