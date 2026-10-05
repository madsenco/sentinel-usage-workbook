[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$tenant = '00000000-0000-0000-0000-000000000001'
$workspaceId = '/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/example-rg/providers/Microsoft.OperationalInsights/workspaces/example-workspace'
$workbookId = '/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/example-rg/providers/Microsoft.Insights/workbooks/00000000-0000-0000-0000-000000000003'
$temp = Join-Path ([IO.Path]::GetTempPath()) "sentinel-workbook-tests-$([guid]::NewGuid())"
if (Get-Variable SentinelWorkbookOfflineTestState -Scope Global -ErrorAction SilentlyContinue) {
    throw 'An offline fixture test is already active in this PowerShell process.'
}
$global:SentinelWorkbookOfflineTestState = @{
    scenario = 'normal'; priceRequests = 0; created = $false
    requestedCurrency = 'EUR'; parameters = $null
}

function Assert-Test {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock] $Action, [string] $Expected)
    $caught = $false
    try { & $Action | Out-Null }
    catch {
        $caught = $true
        Assert-Test ($_.Exception.Message -like "*$Expected*") "Unexpected failure: $($_.Exception.Message)"
    }
    Assert-Test $caught "Expected failure containing '$Expected'."
}

function az {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
    if ($arguments[0] -eq 'account' -and $arguments[1] -eq 'show') {
        $activeTenant = if ($global:SentinelWorkbookOfflineTestState.scenario -eq 'wrong-tenant') { '00000000-0000-0000-0000-000000000099' } else { $tenant }
        return (@{
            tenantId = $activeTenant; environmentName = 'AzureCloud'
            user = @{ name = 'operator@example.org' }
        } | ConvertTo-Json -Depth 5)
    }
    if ($arguments[0] -eq 'account' -and $arguments[1] -eq 'get-access-token') {
        return 'offline-test-only'
    }
    if ($arguments[0] -eq 'rest') {
        $url = $arguments[[array]::IndexOf($arguments, '--url') + 1]
        if ($url -like '*/onboardingStates?*') {
            return (@{ value = @(@{ name = 'default' }) } | ConvertTo-Json -Depth 5)
        }
        if ($url -like '*/tables?*') {
            return (@{
                value = @(@{ name = 'BasicTable'; properties = @{ plan = 'Basic' } })
                nextLink = $null
            } | ConvertTo-Json -Depth 5)
        }
        return (@{
            name = 'example-workspace'; location = 'westeurope'
            properties = @{
                customerId = '00000000-0000-0000-0000-000000000004'
                retentionInDays = 30
                features = @{ unifiedSentinelBillingOnly = $true }
                sku = @{ name = 'PerGB2018' }
            }
        } | ConvertTo-Json -Depth 8)
    }
    if ($arguments[0] -eq 'deployment' -and $arguments[1] -eq 'group') {
        $parameterArgument = $arguments[[array]::IndexOf($arguments, '--parameters') + 1]
        $global:SentinelWorkbookOfflineTestState.parameters = Get-Content $parameterArgument.Substring(1) -Raw | ConvertFrom-Json
        if ($arguments[2] -eq 'what-if') {
            $type = if ($global:SentinelWorkbookOfflineTestState.scenario -eq 'unsafe-preview') { 'Delete' } else { 'Create' }
            return (@{
                status = 'Succeeded'
                changes = @(@{ changeType = $type; resourceId = $workbookId })
            } | ConvertTo-Json -Depth 8)
        }
        if ($arguments[2] -eq 'create') {
            $global:SentinelWorkbookOfflineTestState.created = $true
            return (@{
                properties = @{
                    provisioningState = 'Succeeded'
                    outputs = @{
                        workbookId = @{ value = $workbookId }
                        portalUrl = @{ value = "https://portal.azure.com/#resource$workbookId/workbook" }
                    }
                }
            } | ConvertTo-Json -Depth 8)
        }
    }
    throw "Unexpected mocked Azure operation: $($arguments -join ' ')"
}

function New-FixtureMeter {
    param([int] $Tier, [double] $Price, [string] $EffectiveDate = '2025-01-01T00:00:00Z')
    return @{
        isPrimaryMeterRegion = $true; productName = 'Sentinel'
        serviceName = 'Sentinel'; armRegionName = 'westeurope'
        currencyCode = if ($global:SentinelWorkbookOfflineTestState.scenario -eq 'wrong-currency') { 'USD' } else { $global:SentinelWorkbookOfflineTestState.requestedCurrency }
        skuName = if ($Tier -eq 0) { 'Pay-as-you-go' } else { "$Tier GB Commitment Tier" }
        meterName = if ($Tier -eq 0) { 'Pay-as-you-go Analysis' } else { "$Tier GB Commitment Tier Capacity Reservation" }
        unitOfMeasure = if ($Tier -eq 0) { '1 GB' } else { '1/Day' }
        retailPrice = $Price; tierMinimumUnits = 0; effectiveStartDate = $EffectiveDate
        meterId = "fixture-$Tier-$EffectiveDate"
    }
}

function Invoke-RestMethod {
    param([string] $Uri, [hashtable] $Headers)
    if ($Uri -like 'https://management.azure.com/*') {
        Assert-Test ($Uri -like '*canFetchContent=true') 'Saved workbook request must explicitly fetch content.'
        $content = $global:SentinelWorkbookOfflineTestState.parameters.parameters.workbookContent.value
        if ($global:SentinelWorkbookOfflineTestState.scenario -eq 'readback-mismatch') { $content = @{ version = 'wrong' } }
        return @{ properties = @{ serializedData = $content | ConvertTo-Json -Depth 40 -Compress } }
    }
    Assert-Test ($Uri -like 'https://prices.azure.com/*') 'Unexpected HTTP destination.'
    $global:SentinelWorkbookOfflineTestState.priceRequests++
    if ($Uri -notlike '*cursor=2*') {
        Assert-Test ($Uri -like '*api-version=2023-01-01-preview*') 'Expected current retail API version.'
        Assert-Test ($Uri -match 'currencyCode=([A-Z]{3})') 'Expected requested currency in API URL.'
        $global:SentinelWorkbookOfflineTestState.requestedCurrency = $Matches[1]
        $decoded = [uri]::UnescapeDataString($Uri)
        Assert-Test ($decoded -like "*armRegionName eq 'westeurope'*") 'Expected requested region in retail filter.'
        return @{
            Items = @((New-FixtureMeter 0 10), (New-FixtureMeter 100 500 '2020-01-01T00:00:00Z'))
            NextPageLink = 'https://prices.azure.com/api/retail/prices?cursor=2'
        }
    }
    $items = @((New-FixtureMeter 100 600), (New-FixtureMeter 100 999 '2099-01-01T00:00:00Z'))
    if ($global:SentinelWorkbookOfflineTestState.scenario -eq 'ambiguous') { $items += New-FixtureMeter 100 650 }
    return @{ Items = $items; NextPageLink = $null }
}

try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    $generateArgs = @{
        TenantId = $tenant; WorkspaceResourceId = $workspaceId
        Region = 'westeurope'; Currency = 'EUR'; OutputDirectory = $temp
    }
    & (Join-Path $root 'New-SentinelUsageWorkbook.ps1') @generateArgs
    Assert-Test ($global:SentinelWorkbookOfflineTestState.priceRequests -eq 2) 'Retail pagination must fetch both pages.'
    $snapshot = Get-Content (Join-Path $temp 'pricing-snapshot.json') -Raw | ConvertFrom-Json
    Assert-Test ($snapshot.currency -eq 'EUR' -and $snapshot.region -eq 'westeurope') 'Regional currency snapshot mismatch.'
    Assert-Test (($snapshot.prices | Where-Object tierGB -eq 100).dailyPrice -eq 600) 'Must select the latest effective price, excluding future prices.'
    Assert-Test ('BasicTable' -in $snapshot.excludedLegacyTables) 'Basic plan must be excluded from legacy-schema modelling.'
    & (Join-Path $root 'Test-SentinelUsageWorkbook.ps1') -OutputDirectory $temp
    $workbook = Get-Content (Join-Path $temp 'sentinel-usage.workbook') -Raw | ConvertFrom-Json
    $tiers = $workbook.items | Where-Object name -eq 'tiers'
    Assert-Test ($tiers.content.query -match 'MonthlyWhatIfCost' -and $tiers.content.query -match 'MonthlyCommitmentPrice') 'Expected monthly columns.'
    Assert-Test (@($workbook.items | Where-Object name -eq 'baseline-comparison').Count -eq 1) 'Expected multi-baseline comparison table.'
    Write-Host 'PASS offline generation, pagination, latest effective rates, currency, controls and all panel definitions.'

    $wrongRegionArgs = $generateArgs.Clone()
    $wrongRegionArgs.Region = 'eastus'
    Assert-Throws { & (Join-Path $root 'New-SentinelUsageWorkbook.ps1') @wrongRegionArgs } 'must match the workspace region'
    foreach ($case in @(
        @{ scenario = 'wrong-tenant'; error = 'tenant/account' },
        @{ scenario = 'wrong-currency'; error = 'Unexpected rate/currency' },
        @{ scenario = 'ambiguous'; error = 'Ambiguous latest price' }
    )) {
        $global:SentinelWorkbookOfflineTestState.scenario = $case.scenario
        Assert-Throws { & (Join-Path $root 'New-SentinelUsageWorkbook.ps1') @generateArgs } $case.error
    }
    $global:SentinelWorkbookOfflineTestState.scenario = 'normal'
    $wrongAccountArgs = $generateArgs.Clone()
    $wrongAccountArgs.AccountName = 'different@example.org'
    Assert-Throws { & (Join-Path $root 'New-SentinelUsageWorkbook.ps1') @wrongAccountArgs } 'tenant/account'
    Write-Host 'PASS mismatched tenant/account/region/currency and ambiguous-price guards.'

    & (Join-Path $root 'Deploy-SentinelUsageWorkbook.ps1') @generateArgs -Preview
    Assert-Test (-not $global:SentinelWorkbookOfflineTestState.created) 'Preview must not deploy.'
    $freshWhatIfArgs = $generateArgs.Clone()
    $freshWhatIfArgs.OutputDirectory = Join-Path $temp 'fresh-what-if'
    & (Join-Path $root 'Deploy-SentinelUsageWorkbook.ps1') @freshWhatIfArgs -WhatIf
    Assert-Test (-not $global:SentinelWorkbookOfflineTestState.created) 'PowerShell WhatIf must not deploy.'
    Assert-Test (Test-Path (Join-Path $freshWhatIfArgs.OutputDirectory 'deployment-parameters.json')) 'WhatIf must generate fresh local parameters even on first use.'
    $global:SentinelWorkbookOfflineTestState.scenario = 'unsafe-preview'
    Assert-Throws { & (Join-Path $root 'Deploy-SentinelUsageWorkbook.ps1') @generateArgs -Confirm:$false } 'Unexpected deployment change'
    Assert-Test (-not $global:SentinelWorkbookOfflineTestState.created) 'Unsafe what-if must block deployment.'
    $global:SentinelWorkbookOfflineTestState.scenario = 'normal'
    & (Join-Path $root 'Deploy-SentinelUsageWorkbook.ps1') @generateArgs -Confirm:$false
    Assert-Test $global:SentinelWorkbookOfflineTestState.created 'Approved mocked deployment must execute.'
    $global:SentinelWorkbookOfflineTestState.scenario = 'readback-mismatch'
    Assert-Throws { & (Join-Path $root 'Deploy-SentinelUsageWorkbook.ps1') @generateArgs -Confirm:$false } 'differs from the generated'
    Write-Host 'PASS preview, approval, workbook-only changes, parameter serialization and readback verification.'

    $parseFailures = @()
    foreach ($file in Get-ChildItem $root -Filter '*.ps1' -Recurse) {
        $tokens = $null
        $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        $parseFailures += @($parseErrors)
    }
    Assert-Test ($parseFailures.Count -eq 0) "PowerShell syntax errors: $parseFailures"
    Write-Host 'PASS all PowerShell source parses.'
} finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force
    }
    Remove-Variable SentinelWorkbookOfflineTestState -Scope Global
}
