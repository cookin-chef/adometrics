<#
.SYNOPSIS
    Generate a self-contained HTML dashboard from ADO metrics JSON reports.
.DESCRIPTION
    Reads agent-pool-health.json and ado-org-metrics.json from the output directory
    and produces a single dashboard.html with all data embedded inline.
    The resulting file requires no server and can be opened directly in any browser.
.PARAMETER OutputPath
    Directory containing the JSON report files. dashboard.html is written here too.
    Default: ./output
.EXAMPLE
    .\Generate-HtmlDashboard.ps1
    .\Generate-HtmlDashboard.ps1 -OutputPath "C:\reports\output"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = './output'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Read source JSON files

$healthJsonPath    = Join-Path $OutputPath 'agent-pool-health.json'
$inventoryJsonPath = Join-Path $OutputPath 'ado-org-metrics.json'

$healthJson    = if (Test-Path $healthJsonPath)    { Get-Content $healthJsonPath    -Raw } else { 'null' }
$inventoryJson = if (Test-Path $inventoryJsonPath) { Get-Content $inventoryJsonPath -Raw } else { 'null' }

$generatedAt = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC'

Write-Verbose "Health JSON source:    $healthJsonPath (exists: $(Test-Path $healthJsonPath))"
Write-Verbose "Inventory JSON source: $inventoryJsonPath (exists: $(Test-Path $inventoryJsonPath))"

#endregion

#region HTML template

$htmlTemplate = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ADO Metrics Dashboard</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#f0f2f5;color:#1a1a2e;min-height:100vh}
.header{background:#0a1628;color:#fff;padding:18px 24px}
.header h1{font-size:1.4rem;font-weight:600;letter-spacing:-0.3px}
.header .meta{font-size:0.8rem;color:#8892a4;margin-top:4px}
.container{max-width:1200px;margin:0 auto;padding:24px}
.section-title{font-size:1rem;font-weight:600;margin:28px 0 12px;color:#0a1628;border-left:3px solid #0078d4;padding-left:10px}
.timestamp{font-size:0.78rem;color:#888;margin-bottom:14px}

/* Summary cards */
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:12px;margin-bottom:20px}
.card{background:#fff;border-radius:8px;padding:16px 12px;box-shadow:0 1px 3px rgba(0,0,0,.08);text-align:center}
.card .val{font-size:2.2rem;font-weight:700;line-height:1}
.card .lbl{font-size:0.72rem;color:#666;margin-top:5px;text-transform:uppercase;letter-spacing:.5px}
.card.healthy .val{color:#107c10}
.card.warning .val{color:#ca5010}
.card.critical .val{color:#d13438}
.card.total .val{color:#0078d4}

/* Pool table */
.table-wrap{background:#fff;border-radius:8px;box-shadow:0 1px 3px rgba(0,0,0,.08);overflow:hidden}
table{width:100%;border-collapse:collapse}
th{background:#f7f9fc;padding:9px 14px;text-align:left;font-size:0.72rem;text-transform:uppercase;letter-spacing:.5px;color:#555;border-bottom:1px solid #e4e4e4;white-space:nowrap}
td{padding:9px 14px;border-bottom:1px solid #f0f0f0;font-size:0.88rem}
tr:last-child td{border-bottom:none}
tr:hover td{background:#f7f9fc}

/* Badges */
.badge{display:inline-block;padding:2px 9px;border-radius:11px;font-size:0.75rem;font-weight:600}
.b-healthy{background:#dff6dd;color:#107c10}
.b-warning{background:#fff4ce;color:#ca5010}
.b-critical{background:#fde7e9;color:#d13438}
.b-cloud{background:#deecf9;color:#0078d4}
.b-self{background:#e8f0e0;color:#3a7d44}

/* Inventory cards */
.inv-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:12px}
.inv-card{background:#fff;border-radius:8px;padding:16px 14px;box-shadow:0 1px 3px rgba(0,0,0,.08)}
.inv-card .icon{font-size:1.4rem;margin-bottom:6px}
.inv-card .val{font-size:1.9rem;font-weight:700;color:#0078d4;line-height:1}
.inv-card .lbl{font-size:0.72rem;color:#666;margin-top:4px}

/* Pipeline bar */
.bar-wrap{background:#fff;border-radius:8px;padding:16px;box-shadow:0 1px 3px rgba(0,0,0,.08);margin-top:14px}
.bar-wrap h3{font-size:0.82rem;font-weight:600;color:#555;margin-bottom:10px}
.bar{display:flex;height:18px;border-radius:4px;overflow:hidden;background:#e0e0e0}
.bar-ms{background:#0078d4}
.bar-self{background:#107c10}
.bar-unk{background:#8a8886}
.bar-legend{display:flex;flex-wrap:wrap;gap:14px;margin-top:9px;font-size:0.78rem;color:#555}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:4px;vertical-align:middle}

/* No-data / footer */
.no-data{color:#999;font-style:italic;padding:24px;text-align:center;background:#fff;border-radius:8px;box-shadow:0 1px 3px rgba(0,0,0,.08)}
.footer{margin-top:36px;padding-top:14px;border-top:1px solid #e0e0e0;font-size:0.73rem;color:#aaa;text-align:center}
</style>
</head>
<body>

<div class="header">
  <div style="max-width:1200px;margin:0 auto">
    <h1 id="pageTitle">Azure DevOps Metrics Dashboard</h1>
    <div class="meta" id="pageMeta">Loading&hellip;</div>
  </div>
</div>

<div class="container">
  <div id="content"></div>
  <div class="footer">Generated __GENERATED_AT__ &mdash; ADO Metrics Monitoring</div>
</div>

<script>
var H = __HEALTH_DATA__;
var I = __INVENTORY_DATA__;

function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}

function badge(state){
  var cls=state==='Critical'?'b-critical':state==='Warning'?'b-warning':'b-healthy';
  var dot=state==='Critical'?'&#128308;':state==='Warning'?'&#128993;':'&#128994;';
  return '<span class="badge '+cls+'">'+dot+' '+state+'</span>';
}

function invCard(icon,val,label){
  return '<div class="inv-card"><div class="icon">'+icon+'</div><div class="val">'+val+'</div><div class="lbl">'+esc(label)+'</div></div>';
}

function render(){
  var html='';

  // ---- Agent Pool Health ----
  html+='<div class="section-title">Agent Pool Health</div>';

  if(!H){
    html+='<div class="no-data">agent-pool-health.json not found &mdash; run the health check pipeline first.</div>';
  } else {
    var s=H.Summary;
    var org=H.Organization||'';
    if(org){
      document.getElementById('pageTitle').textContent='ADO Metrics Dashboard \u2014 '+org;
      document.getElementById('pageMeta').textContent=org;
    }
    var genUtc=H.GeneratedUtc?new Date(H.GeneratedUtc).toUTCString():'unknown';
    html+='<div class="timestamp">Last updated: '+genUtc+'</div>';

    html+='<div class="cards">';
    html+='<div class="card healthy"><div class="val">'+s.Healthy+'</div><div class="lbl">Healthy</div></div>';
    html+='<div class="card warning"><div class="val">'+s.Warning+'</div><div class="lbl">Warning</div></div>';
    html+='<div class="card critical"><div class="val">'+s.Critical+'</div><div class="lbl">Critical</div></div>';
    html+='<div class="card total"><div class="val">'+s.Total+'</div><div class="lbl">Total Pools</div></div>';
    html+='</div>';

    if(H.Pools && H.Pools.length>0){
      var pools=H.Pools.slice().sort(function(a,b){
        var o={Critical:0,Warning:1,Healthy:2};
        return (o[a.HealthState]||2)-(o[b.HealthState]||2);
      });
      html+='<div class="table-wrap"><table>';
      html+='<tr><th>Pool Name</th><th>Type</th><th>Status</th><th>Queued</th><th>Running</th><th>Oldest (min)</th></tr>';
      pools.forEach(function(p){
        var tb=p.IsHosted?'<span class="badge b-cloud">&#9729; Cloud</span>':'<span class="badge b-self">Self-Hosted</span>';
        html+='<tr><td><strong>'+esc(p.PoolName)+'</strong></td><td>'+tb+'</td><td>'+badge(p.HealthState)+'</td>';
        html+='<td>'+p.QueuedJobs+'</td><td>'+p.RunningJobs+'</td><td>'+(p.OldestQueuedMinutes||0)+'</td></tr>';
      });
      html+='</table></div>';
    } else {
      html+='<div class="no-data">No pool data available.</div>';
    }
  }

  // ---- Org Inventory ----
  html+='<div class="section-title" style="margin-top:36px">Organization Inventory</div>';

  if(!I){
    html+='<div class="no-data">ado-org-metrics.json not found &mdash; run the inventory pipeline first.</div>';
  } else {
    var m=I.Metrics;
    var invGenUtc=I.GeneratedUtc?new Date(I.GeneratedUtc).toUTCString():'unknown';
    html+='<div class="timestamp">Last updated: '+invGenUtc+'</div>';

    html+='<div class="inv-grid">';
    html+=invCard('&#128193;',m.TotalProjects,'Projects');
    html+=invCard('&#128230;',m.TotalRepos,'Repositories');
    html+=invCard('&#128101;',m.TotalUsers,'Users');
    html+=invCard('&#9881;',m.TotalPipelines,'Pipelines');
    html+=invCard('&#128269;',m.SonarQubeIntegratedPipelines,'SonarQube');
    html+='</div>';

    var tot=m.TotalPipelines;
    if(tot>0){
      var msW=Math.round((m.MicrosoftHostedPipelines/tot)*100);
      var slW=Math.round((m.SelfHostedPipelines/tot)*100);
      var ukW=100-msW-slW;
      html+='<div class="bar-wrap">';
      html+='<h3>Pipeline Hosting Distribution</h3>';
      html+='<div class="bar">';
      html+='<div class="bar-ms" style="width:'+msW+'%"></div>';
      html+='<div class="bar-self" style="width:'+slW+'%"></div>';
      html+='<div class="bar-unk" style="width:'+ukW+'%"></div>';
      html+='</div>';
      html+='<div class="bar-legend">';
      html+='<span><span class="dot" style="background:#0078d4"></span>Microsoft-Hosted: '+m.MicrosoftHostedPipelines+' ('+msW+'%)</span>';
      html+='<span><span class="dot" style="background:#107c10"></span>Self-Hosted: '+m.SelfHostedPipelines+' ('+slW+'%)</span>';
      html+='<span><span class="dot" style="background:#8a8886"></span>Unknown: '+m.UnknownPipelines+' ('+ukW+'%)</span>';
      html+='</div></div>';
    }
  }

  document.getElementById('content').innerHTML=html;
}

render();
</script>
</body>
</html>
'@

#endregion

#region Inject data and write output

$html = $htmlTemplate.Replace('__HEALTH_DATA__',    $healthJson)
$html = $html.Replace(        '__INVENTORY_DATA__', $inventoryJson)
$html = $html.Replace(        '__GENERATED_AT__',   $generatedAt)

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$outputHtmlPath = Join-Path $OutputPath 'dashboard.html'
[System.IO.File]::WriteAllText(
    (Resolve-Path $OutputPath).Path + [System.IO.Path]::DirectorySeparatorChar + 'dashboard.html',
    $html,
    [System.Text.Encoding]::UTF8
)

Write-Host "HTML dashboard saved: $outputHtmlPath"

#endregion
