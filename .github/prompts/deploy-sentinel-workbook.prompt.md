---
description: Deploy or refresh the Sentinel usage workbook with current regional retail prices
agent: agent
---

Deploy the Sentinel usage and commitment-tier workbook from this repository.
Use the provided PowerShell scripts; do not invent prices or change the workspace's
pricing tier, retention, data collection, connectors or permissions.

1. Read `README.md` and `Deploy-SentinelUsageWorkbook.ps1`.
2. Collect the tenant ID, existing Sentinel workspace resource ID, Azure region
   and three-letter currency code. Ask for any missing values. Optionally collect
   an account name to enforce a specific signed-in identity. Use Azure ARM region
   names such as `swedencentral`, not display names.
3. Run `az account show` and verify the requested tenant/account. Do not continue
   in a different tenant. If sign-in is necessary, explain and request permission
   before `az login --tenant <tenant-id> --allow-no-subscriptions`. Never select an
   unrelated subscription or tenant silently.
4. Run the script in preview mode with the user's inputs:

   ```powershell
   .\Deploy-SentinelUsageWorkbook.ps1 `
     -TenantId '<tenant-id>' `
     -WorkspaceResourceId '<workspace-resource-id>' `
     -Region '<arm-region-name>' `
     -Currency '<ISO-currency-code>' `
     -Preview
   ```

   Add `-AccountName` when specified. Add `-WorkbookName '<existing-guid>'` only
   when updating a known existing workbook with a different ID convention.
   Every invocation fetches current applicable prices from the public Azure
   Retail Prices API, following pagination and selecting the latest effective
   primary meters. It verifies the region matches the workspace and rejects
   classic billing, invalid rates and ambiguous meters. Never bypass these errors.
5. Report the fetched timestamp, region, currency, available tiers and the
   workbook-only deployment changes. Explain that prices are retail ingestion
   estimates with 30-day monthly projections. E5 grants, negotiated discounts
   and non-ingestion charges are not automatically modelled.
6. Ask for approval before deployment. Once approved, rerun the same command
   without `-Preview`, adding `-Confirm:$false` only to execute that explicit
   approval noninteractively. `-ValidateQueries` additionally validates all
   panels and deterministic billing cases against the workspace; use it when the
   user authorizes log queries and has access.
7. The script verifies saved content after deployment. Return the verified portal
   link and describe the controls: analysis window, volume change, and multiple
   comparison baseline tiers.

For a pricing refresh, follow the same preview and approval flow. A stable
workspace-based GUID updates the existing workbook; generated artifacts in
`generated/` contain workspace identifiers and must remain uncommitted.
If Azure access is unavailable, run the offline tests instead and explain that
they do not prove deployment or real workspace access.
