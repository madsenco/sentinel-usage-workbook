[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$')]
    [string] $TenantId,
    [string] $AccountName,
    [Parameter(Mandatory)]
    [ValidatePattern('^/subscriptions/[0-9a-f-]+/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$')]
    [string] $WorkspaceResourceId,
    [ValidatePattern('^([a-z0-9]+)?$')]
    [string] $Region,
    [ValidatePattern('^[A-Z]{3}$')]
    [string] $Currency = 'USD',
    [string] $OutputDirectory = (Join-Path $PSScriptRoot 'generated')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AzureContext.ps1')

function Invoke-WorkspaceAz {
    param([string[]] $Arguments)
    $result = Invoke-SentinelAz -TenantId $TenantId -AccountName $AccountName -Arguments $Arguments
    return ($result | ConvertFrom-Json)
}

$workspace = Invoke-WorkspaceAz -Arguments @('rest', '--method', 'get', '--url',
    "https://management.azure.com${WorkspaceResourceId}?api-version=2022-10-01", '-o', 'json')
if (-not $Region) { $Region = $workspace.location }
if ($Region -ne $workspace.location) {
    throw "Pricing region '$Region' must match the workspace region '$($workspace.location)'."
}
if (-not $workspace.properties.features.unifiedSentinelBillingOnly) {
    throw 'This workbook models simplified Sentinel billing only. Verify/migrate classic billing before using these rates.'
}
$onboarding = Invoke-WorkspaceAz -Arguments @('rest', '--method', 'get', '--url',
    "https://management.azure.com${WorkspaceResourceId}/providers/Microsoft.SecurityInsights/onboardingStates?api-version=2024-03-01", '-o', 'json')
if (@($onboarding.value).Count -eq 0) { throw 'Microsoft Sentinel is not enabled on this workspace.' }
$tableUrl = "https://management.azure.com${WorkspaceResourceId}/tables?api-version=2022-10-01"
$tableItems = @()
do {
    if (([uri]$tableUrl).Host -ne 'management.azure.com' -or ([uri]$tableUrl).Scheme -ne 'https') {
        throw 'Unexpected workspace table pagination endpoint.'
    }
    $tables = Invoke-WorkspaceAz -Arguments @('rest', '--method', 'get', '--url', $tableUrl, '-o', 'json')
    $tableItems += @($tables.value)
    $tableUrl = $tables.nextLink
} while ($tableUrl)
$excludedTables = @($tableItems | Where-Object { $_.properties.plan -ne 'Analytics' } | ForEach-Object { $_.name })
$currentTier = switch ($workspace.properties.sku.name) {
    'PerGB2018' { 0 }
    'CapacityReservation' { [int]$workspace.properties.sku.capacityReservationLevel }
    default { throw "Unsupported workspace SKU: $($workspace.properties.sku.name)" }
}

$filter = "serviceName eq 'Sentinel' and armRegionName eq '$Region' and priceType eq 'Consumption'"
$url = 'https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&currencyCode=' +
    $Currency + '&$filter=' + [uri]::EscapeDataString($filter)
$sourceUrl = $url
$meters = @()
do {
    if (([uri]$url).Host -ne 'prices.azure.com' -or ([uri]$url).Scheme -ne 'https') {
        throw 'Unexpected retail price pagination endpoint.'
    }
    $page = Invoke-RestMethod -Uri $url
    $meters += @($page.Items | Where-Object {
        $_.isPrimaryMeterRegion -and $_.productName -eq 'Sentinel' -and
        [datetime]$_.effectiveStartDate -le [datetime]::UtcNow -and (
            ($_.skuName -eq 'Pay-as-you-go' -and $_.meterName -eq 'Pay-as-you-go Analysis' -and $_.unitOfMeasure -eq '1 GB') -or
            ($_.skuName -match '^\d+ GB Commitment Tier$' -and $_.meterName -match ' Capacity Reservation$' -and $_.unitOfMeasure -eq '1/Day')
        )
    })
    $url = $page.NextPageLink
} while ($url)
$meters = @($meters | Group-Object skuName | ForEach-Object {
    $sorted = @($_.Group | Sort-Object { [datetime]$_.effectiveStartDate } -Descending)
    $latestDate = [datetime]$sorted[0].effectiveStartDate
    $latest = @($sorted | Where-Object { [datetime]$_.effectiveStartDate -eq $latestDate })
    if ($latest.Count -ne 1) { throw "Ambiguous latest price for $($_.Name). Refusing to guess a meter." }
    $latest[0]
})
if (@($meters | Where-Object { $_.skuName -eq 'Pay-as-you-go' }).Count -ne 1) {
    throw 'Expected exactly one simplified PAYG retail meter. Refusing to guess a rate.'
}
if (@($meters | Where-Object { $_.skuName -match 'Commitment Tier' }).Count -eq 0) {
    throw 'No commitment-tier retail meters were returned.'
}
if (@($meters | Group-Object skuName | Where-Object Count -ne 1).Count -gt 0) {
    throw 'Duplicate retail meters returned. Review the API response instead of guessing which rate applies.'
}
$prices = @($meters | ForEach-Object {
    $tier = if ($_.skuName -eq 'Pay-as-you-go') { 0 } else { [int]($_.skuName -split ' ')[0] }
    if ($_.currencyCode -ne $Currency -or $_.armRegionName -ne $Region -or
        $_.retailPrice -le 0 -or $_.tierMinimumUnits -ne 0) {
        throw "Unexpected rate/currency/quantity threshold for $($_.skuName)."
    }
    [ordered]@{
        tierGB = $tier
        dailyPrice = if ($tier -eq 0) { 0.0 } else { $_.retailPrice }
        ratePerGB = if ($tier -eq 0) { $_.retailPrice } else { $_.retailPrice / $tier }
        meterId = $_.meterId
        effectiveStartDate = $_.effectiveStartDate
    }
} | Sort-Object { $_.tierGB })
if ($currentTier -notin @($prices | ForEach-Object { $_.tierGB })) {
    throw "Current tier $currentTier is missing from the retail rate card."
}
$culture = [cultureinfo]::InvariantCulture
$priceRows = ($prices | ForEach-Object {
    '{0}, {1}, {2}' -f $_.tierGB, ([double]$_.dailyPrice).ToString('R', $culture),
        ([double]$_.ratePerGB).ToString('R', $culture)
}) -join ",`n"
$common = Get-Content (Join-Path $PSScriptRoot 'queries\common.kql') -Raw
$common = $common.Replace('__EXCLUDED_TABLES__', (ConvertTo-Json -InputObject $excludedTables -Compress)).
    Replace('__PRICE_ROWS__', $priceRows)
$model = Get-Content (Join-Path $PSScriptRoot 'queries\model.kql') -Raw
$fetchedAt = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

function New-Dropdown {
    param([string] $Name, [string] $Label, [object[]] $Options, [string] $Value, [switch] $MultiSelect)
    $parameter = [ordered]@{
        id = $Name; version = 'KqlParameterItem/1.0'; name = $Name; label = $Label
        type = 2; isRequired = $true; value = $Value
        jsonData = ConvertTo-Json -InputObject $Options -Compress
        typeSettings = @{ additionalResourceOptions = @(); showDefault = $false }
    }
    if ($MultiSelect) {
        $parameter.multiSelect = $true
        $parameter.quote = ''
        $parameter.delimiter = ','
        $parameter.value = @($Value)
    }
    return $parameter
}

function New-QueryItem {
    param([string] $Name, [string] $Title, [string] $QueryFile, [string] $Visualization = 'table', [switch] $IncludeModel)
    $query = $common + "`n"
    if ($IncludeModel) { $query += $model + "`n" }
    $query += Get-Content (Join-Path $PSScriptRoot "queries\$QueryFile.kql") -Raw
    $numericColumns = @{
        summary = @('CompleteUTCDays', 'DaysWithUsage', 'HoursWithUsage', 'AnalyticsGB', 'OtherBillableGB', 'NonBillableGB', 'AvgAnalyticsGBPerDay', 'P95AnalyticsGBPerDay', 'PeakAnalyticsGBPerDay', 'ScenarioGBPerDay')
        tiers = @('MonthlyWhatIfCost', 'MonthlyCommitmentPrice', 'MonthlySavingsVsPAYG', 'RatePerGB', 'DailyPrice', 'PeriodCost', 'SavingsVsPAYG', 'SavingsVsPAYGPercent', 'CommitmentUtilizationPercent', 'UnusedGB', 'OverageGB', 'DaysOverTier')
        'baseline-comparison' = @('MonthlyWhatIfCost', 'MonthlyBaselineCost', 'MonthlySavingsVsBaseline', 'SavingsVsBaselinePercent')
        'daily-volume' = @('AnalyticsGB', 'OtherBillableGB', 'NonBillableGB', 'ScenarioAnalyticsGB')
        'daily-cost' = @('EstimatedCost')
        tables = @('BillableGB', 'BillableSharePercent', 'NonBillableGB', 'AverageBillableGBPerDay', 'AnalyticsPAYGEstimate', 'PotentialPAYGSavingAt20PercentReduction', 'DaysReporting')
        'table-trends' = @('BillableGB')
        solutions = @('AnalyticsGB', 'OtherBillableGB', 'NonBillableGB')
        weekday = @('AverageAnalyticsGB', 'PeakAnalyticsGB', 'Days', 'DaysWithUsage')
        peaks = @('AnalyticsGB', 'RatioToPeriodAverage', 'OtherBillableGB', 'NonBillableGB', 'ReportedHours')
        freshness = @('HoursSinceLastUsage', 'DaysReporting', 'BillableGB')
    }
    if (-not $numericColumns.ContainsKey($Name)) { throw "Missing numeric formatting definition for $Name." }
    $numberFormat = @{
        unit = 0
        options = @{
            style = 'decimal'; useGrouping = $true
            minimumSignificantDigits = 3; maximumSignificantDigits = 3
        }
    }
    $formatters = @($numericColumns[$Name] | ForEach-Object {
        @{ columnMatch = $_; formatter = 1; numberFormat = $numberFormat }
    })
    return [ordered]@{
        type = 3; name = $Name
        content = [ordered]@{
            version = 'KqlItem/1.0'; title = $Title; query = $query
            size = 0; queryType = 0; resourceType = 'microsoft.operationalinsights/workspaces'
            crossComponentResources = @($WorkspaceResourceId)
            timeContext = @{ durationMs = 7948800000 }
            visualization = $Visualization
            gridSettings = @{ formatters = $formatters }
            chartSettings = @{ ySettings = @{ numberFormatSettings = $numberFormat } }
        }
    }
}

$dayOptions = @(7, 14, 30, 60, 90 | ForEach-Object { [ordered]@{ value = "$_"; label = "$_ complete UTC days" } })
$growthOptions = @(-75, -50, -25, 0, 10, 25, 50, 100, 200 | ForEach-Object {
    [ordered]@{ value = "$_"; label = "$_% volume change" }
})
$tierOptions = @($prices | ForEach-Object {
    [ordered]@{ value = "$($_.tierGB)"; label = if ($_.tierGB -eq 0) { 'Pay-as-you-go' } else { "$($_.tierGB) GB/day" } }
})
$intro = @"
# Sentinel - Usage and commitment tier what-if
**Workspace:** $($workspace.name) | **Region:** $($workspace.location) | **Currency:** $Currency

**Retail rate snapshot:** $fetchedAt. Simplified Sentinel rates include Log Analytics ingestion; do not add its ingestion price again. Refresh the generated workbook to update rates, workspace defaults and legacy table-plan exclusions.

Only complete UTC days are analysed; today's partial data is excluded. Usage quantities are MB / 1000 = decimal GB. Each tier is charged **daily fixed price + max(0, daily Analytics GB - tier GB) x effective tier GB rate**. Unused daily commitment is not carried forward. The 30-day projection repeats the selected period's daily pattern; it is not an invoice or a calendar-month forecast.

**Important:** Missing Usage days are assumed zero and flagged as incomplete. Even a day with some records may be incomplete: inspect reported hours and retention. No data suppresses costs and the lowest-cost flag. Usage can arrive late. Rates are list prices, not your negotiated invoice rates. Benefits/trials, eligible Microsoft 365 grants, table-specific exemptions not reflected in IsBillable, discounts/pre-purchase plans, tax, retention/archive, Basic/Auxiliary/lake processing and queries, automation and other services are not modelled. Verify eligible chargeable Analytics volume and tier availability before acting. Commitment decreases/PAYG changes are subject to the 31-day commitment period.

The baseline dropdown accepts **multiple comparison tiers** (initially the workspace's tier at generation time). Each selected tier is compared separately in the monthly baseline comparison table and included in the daily cost chart. Volume change scales Analytics ingestion for the what-if model; observed table charts remain unchanged. No workbook control modifies Azure configuration.

Numeric table cells and chart values use **three significant digits**, not three decimal places. Display formatting does not round the underlying queries, prices or cost calculations.
"@
$items = @(
    @{ type = 1; name = 'introduction'; content = @{ json = $intro } }
    @{
        type = 9; name = 'parameters'
        content = @{
            version = 'KqlParameterItem/1.0'; style = 'pills'
            parameters = @(
                (New-Dropdown 'LookbackDays' 'Analysis window' $dayOptions '30')
                (New-Dropdown 'GrowthPercent' 'What-if Analytics volume change' $growthOptions '0')
                (New-Dropdown 'CurrentTier' 'Comparison baseline tiers' $tierOptions "$currentTier" -MultiSelect)
            )
        }
    }
    (New-QueryItem 'summary' 'Volume and data coverage (GB)' 'summary')
    @{ type = 1; name = 'monthly-price-guidance'; content = @{ json = "## Monthly commitment-tier what-if ($Currency, 30-day month)`n**MonthlyWhatIfCost** is the projected total ingestion charge, including daily overage and your selected volume change. **MonthlyCommitmentPrice** is the fixed tier charge (daily price x 30), excluding overage; PAYG has no fixed commitment. Monthly savings compare projected totals. These monthly prices always use 30 days, regardless of the analysis window. The main table keeps one row per tier; the next table compares every tier against each selected baseline separately. PeriodCost and period savings remain available on the right for the selected analysis window. Negative savings mean higher cost. Without usage data, only the published fixed commitment price is shown." } }
    (New-QueryItem 'tiers' "Monthly prices for every commitment tier - $Currency / 30-day month" 'tiers' -IncludeModel)
    (New-QueryItem 'baseline-comparison' "Monthly savings against each selected baseline - $Currency / 30-day month" 'baseline-comparison' -IncludeModel)
    (New-QueryItem 'daily-volume' 'Daily observed ingestion and what-if Analytics volume (GB)' 'daily-volume' 'timechart')
    (New-QueryItem 'daily-cost' "Daily cost - PAYG, selected baselines and lowest-period-cost tier ($Currency)" 'daily-cost' 'timechart' -IncludeModel)
    @{ type = 1; name = 'table-guidance'; content = @{ json = "## Ingestion drivers`nTable costs use PAYG Analytics rates for attribution, not allocated commitment charges. The 20% reduction column is potential PAYG impact only; reducing volume may not reduce a fixed commitment bill. Validate detection, investigation and compliance requirements before filtering security data." } }
    (New-QueryItem 'tables' "Largest 25 tables - volume, share and PAYG attribution ($Currency)" 'tables')
    (New-QueryItem 'table-trends' 'Daily billable GB - top 10 tables' 'table-trends' 'timechart')
    (New-QueryItem 'solutions' 'Ingestion by solution (GB)' 'solutions' 'barchart')
    (New-QueryItem 'weekday' 'Weekday profile - Analytics GB' 'weekday')
    (New-QueryItem 'peaks' 'Peak days and simple volume spike signals' 'peaks')
    @{ type = 1; name = 'freshness-guidance'; content = @{ json = "## Usage reporting freshness`nThis is Usage-aggregation freshness, not a connector health check or event ingestion-latency measurement. Today's data is intentionally excluded. Tables with no Usage records anywhere in the selected window cannot appear here; check connector health separately." } }
    (New-QueryItem 'freshness' 'Table Usage reporting gaps' 'freshness')
)
$workbook = [ordered]@{
    version = 'Notebook/1.0'; items = $items; isLocked = $false
    fallbackResourceIds = @($WorkspaceResourceId)
    '$schema' = 'https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json'
}
$snapshot = [ordered]@{
    fetchedAtUTC = $fetchedAt; region = $Region; currency = $Currency
    workspaceResourceId = $WorkspaceResourceId; workspaceCustomerId = $workspace.properties.customerId
    currentTierGB = $currentTier; workspaceRetentionDays = $workspace.properties.retentionInDays
    excludedLegacyTables = $excludedTables; sourceUrl = $sourceUrl; prices = $prices
}
New-Item -ItemType Directory -Path $OutputDirectory -Force -WhatIf:$false -Confirm:$false | Out-Null
$workbook | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $OutputDirectory 'sentinel-usage.workbook') -Encoding utf8 -WhatIf:$false -Confirm:$false
$snapshot | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $OutputDirectory 'pricing-snapshot.json') -Encoding utf8 -WhatIf:$false -Confirm:$false
Write-Host "Generated workbook with $($prices.Count) pricing options, scoped to $($workspace.name). Rates: $Currency, $fetchedAt."
