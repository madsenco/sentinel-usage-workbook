[CmdletBinding()]
param(
    [switch] $Live,
    [string] $TenantId,
    [string] $AccountName,
    [string] $OutputDirectory = (Join-Path $PSScriptRoot 'generated')
)

$ErrorActionPreference = 'Stop'
$workbook = Get-Content (Join-Path $OutputDirectory 'sentinel-usage.workbook') -Raw | ConvertFrom-Json
$snapshot = Get-Content (Join-Path $OutputDirectory 'pricing-snapshot.json') -Raw | ConvertFrom-Json
$queries = @($workbook.items | Where-Object type -eq 3)

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Close {
    param([double] $Actual, [double] $Expected, [string] $Message)
    Assert-True ([math]::Abs($Actual - $Expected) -lt 0.000001) "$Message (actual $Actual; expected $Expected)"
}

function Expand-Query {
    param([string] $Query, [int] $Days = 30, [int] $Growth = 0, [string] $Tier = '0')
    return $Query.Replace('{LookbackDays}', "$Days").Replace('{GrowthPercent}', "$Growth").Replace('{CurrentTier}', "$Tier")
}

Assert-True ($workbook.version -eq 'Notebook/1.0') 'Unexpected workbook schema version.'
Assert-True ($queries.Count -eq 11) 'Expected all 11 analytical queries.'
Assert-True ($workbook.fallbackResourceIds[0] -eq $snapshot.workspaceResourceId) 'Workbook and rate snapshot workspace mismatch.'
$parameterItems = @($workbook.items | Where-Object type -eq 9)
Assert-True ($parameterItems.Count -eq 1) 'Expected one parameter panel.'
$parameters = $parameterItems[0].content.parameters
Assert-True ($parameters.Count -eq 3) 'Expected three controls.'
foreach ($parameter in $parameters) {
    $options = $parameter.jsonData | ConvertFrom-Json
    foreach ($value in @($parameter.value)) {
        Assert-True ($value -in @($options.value)) "Invalid default for $($parameter.name)."
    }
    if ($parameter.name -eq 'CurrentTier') {
        Assert-True ($parameter.multiSelect -and $parameter.isRequired -and
            $parameter.quote -eq '' -and $parameter.delimiter -eq ',') 'Baseline dropdown must require at least one tier and interpolate unquoted numeric lists.'
    }
}
foreach ($item in $queries) {
    Assert-True ($item.content.crossComponentResources[0] -eq $snapshot.workspaceResourceId) "Wrong query scope: $($item.name)"
    Assert-True ((Expand-Query $item.content.query) -notmatch '\{(LookbackDays|GrowthPercent|CurrentTier)\}|__PRICE_ROWS__|__EXCLUDED_TABLES__') "Unexpanded query: $($item.name)"
    Assert-True ($item.content.gridSettings.formatters.Count -gt 0) "Missing numeric cell formatting: $($item.name)"
    $formats = @($item.content.gridSettings.formatters.numberFormat) + @($item.content.chartSettings.ySettings.numberFormatSettings)
    foreach ($format in $formats) {
        Assert-True ($format.unit -eq 0 -and $format.options.style -eq 'decimal' -and
            $format.options.minimumSignificantDigits -eq 3 -and
            $format.options.maximumSignificantDigits -eq 3) "Expected three significant digits without unit scaling: $($item.name)"
        Assert-True (-not ($format.options.PSObject.Properties.Name -match 'FractionDigits')) "Fractional-digit limit conflicts with significant digits: $($item.name)"
    }
}
Assert-True (@($snapshot.prices | Where-Object tierGB -eq 0).Count -eq 1) 'Missing/duplicate PAYG rate.'
Assert-True (@($snapshot.prices.tierGB | Select-Object -Unique).Count -eq $snapshot.prices.Count) 'Duplicate commitment tier.'
foreach ($price in $snapshot.prices | Where-Object tierGB -gt 0) {
    Assert-Close ($price.ratePerGB * $price.tierGB) $price.dailyPrice 'Commitment effective rate mismatch.'
}
Write-Host 'PASS: workbook scope, controls, query structure and rate-card arithmetic.'

if (-not $Live) { return }

Assert-True (-not [string]::IsNullOrWhiteSpace($TenantId)) 'Live tests require an explicit TenantId.'
. (Join-Path $PSScriptRoot 'AzureContext.ps1')
$token = Invoke-SentinelAz -TenantId $TenantId -AccountName $AccountName -Arguments @(
    'account', 'get-access-token', '--resource', 'https://api.loganalytics.io', '--query', 'accessToken', '-o', 'tsv'
)
$headers = @{ Authorization = "Bearer $token" }
$endpoint = "https://api.loganalytics.azure.com/v1/workspaces/$($snapshot.workspaceCustomerId)/query"

function Invoke-LogQuery {
    param([string] $Query, [string[]] $FormattedColumns)
    $body = @{ query = $Query } | ConvertTo-Json -Compress
    $response = Invoke-RestMethod -Method Post -Uri $endpoint -Headers $headers -ContentType 'application/json' -Body $body
    if ($response.error) { throw ($response.error | ConvertTo-Json -Depth 10) }
    Assert-True ($response.tables.Count -gt 0) 'Log query returned no result table.'
    $table = $response.tables[0]
    if ($FormattedColumns) {
        $numericColumns = @($table.columns | Where-Object { $_.type -in @('real', 'long', 'int', 'decimal') } | ForEach-Object name)
        Assert-True (@(Compare-Object $numericColumns $FormattedColumns).Count -eq 0) 'Numeric result columns do not match the workbook formatters.'
    }
    foreach ($row in $table.rows) {
        $record = [ordered]@{}
        for ($i = 0; $i -lt $table.columns.Count; $i++) {
            $record[$table.columns[$i].name] = $row[$i]
        }
        [pscustomobject] $record
    }
}

foreach ($item in $queries) {
    $rows = @(Invoke-LogQuery (Expand-Query $item.content.query -Tier $snapshot.currentTierGB) -FormattedColumns $item.content.gridSettings.formatters.columnMatch)
    if ($item.name -eq 'tiers') {
        Assert-True ($rows.Count -eq $snapshot.prices.Count) 'Tier query did not return every published option.'
        $rows | Select-Object Tier, MonthlyWhatIfCost, MonthlyCommitmentPrice, MonthlySavingsVsPAYG, LowestModelledCost, Status | Format-Table -AutoSize
        foreach ($row in $rows) {
            Assert-Close $row.MonthlyCommitmentPrice ($row.DailyPrice * 30) 'Monthly fixed tier price'
            if ($null -ne $row.PeriodCost) {
                Assert-Close $row.MonthlyWhatIfCost ($row.PeriodCost / 30 * 30) 'Default monthly what-if cost'
            }
        }
    }
    if ($item.name -eq 'daily-volume') { Assert-True ($rows.Count -eq 30) 'Daily calendar must contain exactly 30 complete days.' }
    if ($item.name -eq 'baseline-comparison') {
        Assert-True ($rows.Count -eq $snapshot.prices.Count) 'Single-baseline comparison must include every tier.'
    }
    if ($item.name -eq 'summary') { $rows | Format-List }
    Write-Host "PASS live query: $($item.name) ($($rows.Count) rows)"
}

$commonTemplate = Get-Content (Join-Path $PSScriptRoot 'queries\common.kql') -Raw
$modelTemplate = Get-Content (Join-Path $PSScriptRoot 'queries\model.kql') -Raw
$tiersTemplate = Get-Content (Join-Path $PSScriptRoot 'queries\tiers.kql') -Raw
$baselineTemplate = Get-Content (Join-Path $PSScriptRoot 'queries\baseline-comparison.kql') -Raw
$commonTemplate = $commonTemplate.Replace('__EXCLUDED_TABLES__', '["BasicTable"]').
    Replace('__PRICE_ROWS__', "0, 0.0, 10.0,`n100, 600.0, 6.0")
$commonTemplate = [regex]::Replace($commonTemplate, '(?m)^    Usage\r?$', '    Fixture')

function Test-BillingCase {
    param(
        [string] $Name, [string] $FixtureRows, [int] $Growth,
        [object] $ExpectedPAYG, [object] $ExpectedCommitment,
        [double] $ExpectedOverage = 0, [double] $ExpectedUnused = 0,
        [bool] $Missing = $false, [switch] $NoPlan, [int] $Days = 2
    )
    $schema = if ($NoPlan) {
        'DayOffset:long, Quantity:real, IsBillable:bool, DataType:string'
    } else {
        'DayOffset:long, Quantity:real, IsBillable:bool, Plan:string, DataType:string'
    }
    $fixture = @"
let Fixture = datatable($schema)[$FixtureRows]
| extend StartTime = startofday(now()) + DayOffset * 1d
| extend EndTime = StartTime + 1h, TimeGenerated = StartTime;
"@
    $query = Expand-Query ($fixture + "`n" + $commonTemplate + "`n" + $modelTemplate + "`n" + $tiersTemplate) -Days $Days -Growth $Growth -Tier 100
    $rows = @(Invoke-LogQuery $query)
    Assert-True ($rows.Count -eq 2) "$Name must return both tiers."
    $payg = $rows | Where-Object Tier -eq 'Pay-as-you-go'
    $commitment = $rows | Where-Object Tier -eq '100 GB/day'
    $comparisonQuery = Expand-Query ($fixture + "`n" + $commonTemplate + "`n" + $modelTemplate + "`n" + $baselineTemplate) -Days $Days -Growth $Growth -Tier '0,100'
    $comparisons = @(Invoke-LogQuery $comparisonQuery)
    Assert-True ($comparisons.Count -eq 4) "$Name must compare both tiers against both selected baselines."
    $paygVsCommitment = $comparisons | Where-Object { $_.Tier -eq 'Pay-as-you-go' -and $_.BaselineTier -eq '100 GB/day' }
    $commitmentVsPayg = $comparisons | Where-Object { $_.Tier -eq '100 GB/day' -and $_.BaselineTier -eq 'Pay-as-you-go' }
    Assert-Close $payg.MonthlyCommitmentPrice 0 "$Name PAYG has no fixed monthly commitment"
    Assert-Close $commitment.MonthlyCommitmentPrice 18000 "$Name fixed monthly commitment is independent of analysis window"
    if ($null -eq $ExpectedPAYG) {
        Assert-True ($null -eq $payg.PeriodCost -and $null -eq $commitment.PeriodCost) "$Name must suppress costs."
        Assert-True ($null -eq $payg.MonthlyWhatIfCost -and $null -eq $commitment.MonthlyWhatIfCost -and
            $null -eq $commitment.MonthlySavingsVsPAYG) "$Name must suppress usage-based monthly projections."
        foreach ($comparison in $comparisons) {
            Assert-True ($null -eq $comparison.MonthlyWhatIfCost -and $null -eq $comparison.MonthlyBaselineCost -and
                $null -eq $comparison.MonthlySavingsVsBaseline) "$Name must suppress all usage-based baseline costs."
        }
        Assert-True (@($rows | Where-Object LowestModelledCost).Count -eq 0) "$Name must suppress the lowest-cost flag."
        Assert-True ($payg.Status -like 'NO DATA*') "$Name must show a no-data warning."
    } else {
        Assert-Close $payg.PeriodCost $ExpectedPAYG "$Name PAYG cost"
        Assert-Close $commitment.PeriodCost $ExpectedCommitment "$Name commitment cost"
        Assert-Close $payg.MonthlyWhatIfCost ($ExpectedPAYG / $Days * 30) "$Name monthly PAYG projection"
        Assert-Close $commitment.MonthlyWhatIfCost ($ExpectedCommitment / $Days * 30) "$Name monthly what-if projection"
        Assert-Close $commitment.MonthlySavingsVsPAYG (($ExpectedPAYG - $ExpectedCommitment) / $Days * 30) "$Name monthly PAYG savings"
        Assert-Close $paygVsCommitment.MonthlySavingsVsBaseline (($ExpectedCommitment - $ExpectedPAYG) / $Days * 30) "$Name savings against commitment baseline"
        Assert-Close $commitmentVsPayg.MonthlySavingsVsBaseline (($ExpectedPAYG - $ExpectedCommitment) / $Days * 30) "$Name savings against PAYG baseline"
        Assert-Close $paygVsCommitment.MonthlyBaselineCost ($ExpectedCommitment / $Days * 30) "$Name monthly commitment baseline cost"
        Assert-Close $commitmentVsPayg.MonthlyBaselineCost ($ExpectedPAYG / $Days * 30) "$Name monthly PAYG baseline cost"
        foreach ($comparison in $comparisons | Where-Object { $_.Tier -eq $_.BaselineTier }) {
            Assert-Close $comparison.MonthlySavingsVsBaseline 0 "$Name each baseline must have zero savings against itself"
        }
        Assert-Close $commitment.SavingsVsPAYG ($ExpectedPAYG - $ExpectedCommitment) "$Name savings"
        Assert-Close $commitment.OverageGB $ExpectedOverage "$Name overage"
        Assert-Close $commitment.UnusedGB $ExpectedUnused "$Name unused commitment"
        Assert-True ($commitment.CommitmentUtilizationPercent -le 100) "$Name utilization must be capped."
        if ($Missing) { Assert-True ($payg.Status -like 'INCOMPLETE*') "$Name must flag incomplete data." }
    }
    Write-Host "PASS deterministic KQL billing case: $Name"
}

Test-BillingCase 'Daily spike; Basic/free excluded' `
    '-2,50000,true,"Analytics","A", -1,150000,true,"Analytics","A", -1,1000000,true,"Basic","BasicTable", -1,2000000,false,"Analytics","FreeTable"' `
    0 2000 1500 50 50
Test-BillingCase '100 percent growth' '-2,50000,true,"Analytics","A", -1,150000,true,"Analytics","A"' 100 4000 2400 200 0
Test-BillingCase '50 percent reduction' '-2,50000,true,"Analytics","A", -1,150000,true,"Analytics","A"' -50 1000 1200 0 100
Test-BillingCase 'Exactly at tier' '-2,100000,true,"Analytics","A", -1,100000,true,"Analytics","A"' 0 2000 1200 0 0
Test-BillingCase 'Observed zero volume' '-2,0,true,"Analytics","A", -1,0,true,"Analytics","A"' 0 0 1200 0 200
Test-BillingCase 'Missing day' '-1,150000,true,"Analytics","A"' 0 1500 1500 50 100 -Missing $true
Test-BillingCase 'No data' '' 0 $null $null
Test-BillingCase 'Legacy schema table-plan exclusions' '-2,50000,true,"A", -1,150000,true,"A", -1,1000000,true,"BasicTable"' 0 2000 1500 50 50 -NoPlan
foreach ($days in @(7, 14, 30, 60, 90)) {
    $fixtureRows = (-$days..-1 | ForEach-Object { "$_,50000,true,`"Analytics`",`"A`"" }) -join ', '
    Test-BillingCase "$days-day window still projects a 30-day month" $fixtureRows 0 ($days * 500) ($days * 600) 0 ($days * 50) -Days $days
}
$selectedTiers = @($snapshot.prices | Select-Object -First 3 -ExpandProperty tierGB)
$selection = $selectedTiers -join ','
foreach ($name in @('tiers', 'baseline-comparison', 'daily-cost')) {
    $item = $queries | Where-Object name -eq $name
    $rows = @(Invoke-LogQuery (Expand-Query $item.content.query -Tier $selection) -FormattedColumns $item.content.gridSettings.formatters.columnMatch)
    switch ($name) {
        'tiers' {
            Assert-True ($rows.Count -eq $snapshot.prices.Count) 'Multiple baselines must not duplicate the main monthly price rows.'
            Assert-True (@($rows | Where-Object SelectedBaseline).Count -eq 3) 'All three selected baseline tiers must be flagged.'
        }
        'baseline-comparison' {
            Assert-True ($rows.Count -eq $snapshot.prices.Count * 3) 'All tiers must be compared against each of the three selected baselines.'
            Assert-True (@($rows.BaselineTier | Select-Object -Unique).Count -eq 3) 'Comparison table must contain three separate baselines.'
        }
        'daily-cost' {
            foreach ($tier in $selectedTiers) {
                $label = if ($tier -eq 0) { 'Pay-as-you-go' } else { "$tier GB/day" }
                Assert-True (@($rows | Where-Object Tier -eq $label).Count -eq 30) "Daily chart is missing a selected baseline: $label"
            }
        }
    }
    Write-Host "PASS multi-select live panel: $name"
}
Write-Host 'PASS: all eleven live panels, thirteen deterministic multi-baseline billing cases and three live multi-select panels.'
