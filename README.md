# Sentinel usage and commitment-tier workbook

An Azure Monitor workbook for Microsoft Sentinel that explains ingestion usage
and compares pay-as-you-go with every published regional commitment tier.
Self-contained PowerShell and Bicep: no external deployment repository, paid
module, Python package or custom Azure service is required.

## What it shows

- **Monthly what-if prices** for every tier: fixed commitment, projected total
  including daily overage, savings against PAYG, unused capacity and utilization.
- **Multiple comparison baseline tiers**, with a separate monthly savings table
  and daily cost chart. Baseline selection never changes your real pricing tier.
- **Growth/reduction scenarios** applied to observed billable Analytics volume.
- Largest 25 tables, ingestion share, PAYG cost attribution and indicative
  20% reduction opportunities; daily trends for the top 10 tables.
- Billable Analytics, other billable and nonbillable ingestion, average/P95/peak
  GB, solution breakdown, weekday profile, spike signals and Usage reporting gaps.
- **Three significant digits** in numeric cells and charts; calculations retain
  full precision.

Only a shared `Microsoft.Insights/workbooks` resource is created or updated.
No workspace settings, data sources, retention, pricing tiers or access grants
are changed.

## Prerequisites

- An existing Sentinel-enabled Log Analytics workspace using **simplified
  Sentinel billing**, in **Azure public cloud**.
- PowerShell 7 and [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli).
  Azure CLI's Bicep executable is required for deployment; install it with
  `az bicep install` if a build reports it missing.
- Reader access to the workspace, table configuration and Sentinel onboarding
  state. Deployment also requires permission to create/update workbooks and
  resource-group deployments, for example Contributor on the target group.
- Log query permission, for example Log Analytics Reader, to view the workbook
  or run optional live validation.
- Network access to `management.azure.com`, `prices.azure.com` and, for log
  queries, `api.loganalytics.azure.com`.

## Quick start

Clone this repository and open a PowerShell terminal in its root. Substitute
your values; no tenant, account or workspace identifiers are supplied by default.

```powershell
$tenantId = '<tenant-guid>'
$workspaceId = '/subscriptions/<subscription-guid>/resourceGroups/<resource-group>/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>'

az account show
az login --tenant $tenantId --allow-no-subscriptions

# Fetch current prices, generate the workbook, validate and preview Azure changes.
.\Deploy-SentinelUsageWorkbook.ps1 `
  -TenantId $tenantId `
  -WorkspaceResourceId $workspaceId `
  -Region swedencentral `
  -Currency USD `
  -Preview

# After reviewing the preview, deploy (PowerShell asks for confirmation).
.\Deploy-SentinelUsageWorkbook.ps1 `
  -TenantId $tenantId `
  -WorkspaceResourceId $workspaceId `
  -Region swedencentral `
  -Currency USD
```

`-Region` uses the ARM region name, such as `westeurope` or `eastus`. It defaults
to the workspace's location when omitted; a specified region must match that
location to prevent misleading estimates. `-Currency` is a three-letter code,
such as `USD`, `EUR`, `DKK` or `GBP`; the API response must match the requested
currency or generation fails. Unsupported regions/currencies fail explicitly.

Every deployment invocation **fetches fresh prices**, even after a preview. The
workbook itself uses a dated snapshot; opening it does not call the pricing API.
Run the script again to refresh prices. It follows pagination, selects primary
simplified Sentinel consumption meters and uses the latest effective version
of each SKU as of the fetch time. It never guesses rates or hardcodes discounts.

Optional parameters:

| Parameter | Purpose |
| --- | --- |
| `-AccountName` | Require a particular signed-in Azure user/principal name as well as the tenant. |
| `-ValidateQueries` | Execute all panels and deterministic KQL cases against the workspace before preview/deployment. |
| `-WorkbookName` | Supply an existing workbook GUID when adopting an earlier deployment. |
| `-Preview` | Generate and run ARM what-if without saving an Azure workbook. |
| `-WhatIf` | PowerShell's equivalent no-write guard; generation, tests and ARM preview still run. |

The default workbook GUID is deterministic per workspace. Redeploying updates
the same workbook; different workspaces can have separate workbooks in one group.
The deployment script targets the workspace's existing subscription and resource
group explicitly, checks the tenant/account before every Azure CLI operation,
rejects unexpected non-workbook changes and verifies persisted workbook content.
The verified portal link is printed after deployment.

Find it under Sentinel/Log Analytics **Workbooks > My workbooks**.

## Deploy with GitHub Copilot

Open the cloned project in VS Code with Copilot agent mode. Invoke the saved
prompt **`/deploy-sentinel-workbook`** and provide your tenant ID, workspace ID,
region and currency. If it is not listed, open
[deploy-sentinel-workbook.prompt.md](.github/prompts/deploy-sentinel-workbook.prompt.md)
and use the prompt file's Run action.

The prompt uses the same deployment script: fresh prices, tenant verification,
preview, approval and saved-content verification. It is a saved workflow, not a
separately installed skill or agent.

## Generate or import manually

To generate without an ARM deployment:

```powershell
.\New-SentinelUsageWorkbook.ps1 `
  -TenantId $tenantId `
  -WorkspaceResourceId $workspaceId `
  -Region swedencentral `
  -Currency EUR

.\Test-SentinelUsageWorkbook.ps1
```

The outputs are in `generated/`:

| File | Content |
| --- | --- |
| `sentinel-usage.workbook` | Workbook JSON scoped to your workspace; can be pasted into a new workbook's Advanced Editor. |
| `pricing-snapshot.json` | Prices, meter IDs, effective dates, fetch time, region/currency and workspace metadata. |
| `deployment-parameters.json` | Created by the deployment script and supplied to Bicep. |

**Do not commit or publish these files.** They contain environment identifiers
and are excluded by [.gitignore](.gitignore). Authentication tokens are kept only
in memory and are never embedded in the workbook or parameter files.

## Daily billing and weekend volumes

All windows end at today's UTC midnight and include complete UTC days only.
`Usage.StartTime` defines the day and `Quantity / 1000` converts MB to decimal GB.
Only billable Analytics data enters the tier model. Non-Analytics plans remain
visible but their separate charges are not estimated.

```text
scenario GB = daily billable Analytics GB * (1 + volume-change percent / 100)
PAYG daily cost = scenario GB * PAYG rate
commitment daily cost = daily tier price
                      + max(0, scenario GB - tier GB) * (daily tier price / tier GB)
monthly what-if cost = sum(daily costs) / selected days * 30
fixed monthly commitment price = daily tier price * 30
```

Low-volume weekends still incur the full daily commitment. Unused weekend
capacity cannot cover weekday overage. Costs are calculated daily **before**
averaging, and commitment utilization is capped at 100%.

Monthly columns always use a **30-day month**, regardless of the selected
7/14/30/60/90-day analysis window. They repeat the historical pattern rather than
forecasting a future calendar month's exact weekday/holiday composition. The
main price table has one row per tier; the comparison table has one row per
tier-and-selected-baseline pair. Negative savings mean higher costs.

## Important limitations

- **Estimates, not invoices.** Simplified retail rates include Log Analytics
  ingestion; do not add its ingestion price again. Classic billing is rejected.
- **E5 grants are not automatically calculated.** The model does not discover
  eligible license counts, eligible-source allowances or cross-workspace benefit
  allocation. It excludes records marked nonbillable, but that is not proof that
  the full E5 benefit is reflected. Treat estimates as before any unreflected grant.
- Trials, negotiated discounts, pre-purchase plans, exemptions not reflected in
  `IsBillable`, tax, retention/archive, Basic/Auxiliary/data-lake charges, automation
  and other services are excluded.
- Missing Usage days are assumed zero and flagged incomplete. No-data windows
  suppress usage-based cost projections, but published fixed prices remain visible.
  Late records, sparse reporting and insufficient retention can bias estimates;
  reported hours help but do not prove complete billing coverage.
- When historical Usage has no `Plan`, a generation-time table-plan snapshot
  excludes current non-Analytics tables. Refresh after plan changes; historical
  plan changes may still make this fallback imperfect.
- A published price meter does not guarantee tier eligibility for your workspace.
  Verify tiers in Sentinel Pricing, including the 50 GB option where published.
  Tier decreases/PAYG switches are subject to the 31-day commitment period.
- Table attribution is PAYG-based, not an allocation of fixed commitment fees.
  Reducing volume below commitment may not save money. Review security and
  compliance requirements before reducing logs.
- Freshness describes Usage reporting, not connector health or event latency.
  Queries scan Usage aggregations, not every raw security table.

## Tests and contribution

Offline fixture tests require only PowerShell 7: no Azure sign-in or network
access, and no generated production files.

```powershell
.\tests\Test-Offline.ps1
```

After generating for a real workspace, structural checks and optional live
validation are available:

```powershell
.\Test-SentinelUsageWorkbook.ps1
.\Test-SentinelUsageWorkbook.ps1 -Live -TenantId $tenantId
```

Live tests validate all 11 panels, numeric formatting coverage, daily spike/
overage behavior, Basic/free exclusions, growth/reduction, missing/zero data,
monthly projections across all windows, and multiple baseline selections.
HTTP and partial-query errors are surfaced, not turned into successful estimates.

Pull requests are welcome. Keep source prices/calculations at full precision,
keep generated environment data out of commits and add tests for billing changes.
CI runs the offline tests on pull requests and pushes.

## Implementation and sources

[main.bicep](main.bicep) declares only the workbook resource. A direct resource
is used because no published `Microsoft.Insights/workbooks` Bicep AVM was found
in the [official module index](https://azure.github.io/Azure-Verified-Modules/indexes/bicep/bicep-resource-modules/)
when this project was created. Deployment does not take ownership of the workspace.

- [Sentinel pricing and billing](https://learn.microsoft.com/azure/sentinel/billing)
- [Commitment-tier changes](https://learn.microsoft.com/azure/sentinel/billing-reduce-costs)
- [Usage table schema](https://learn.microsoft.com/azure/azure-monitor/reference/tables/usage)
- [Workspace usage analysis](https://learn.microsoft.com/azure/azure-monitor/logs/analyze-usage)
- [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices)

## License

[MIT](LICENSE). Community project; not an official Microsoft product.
