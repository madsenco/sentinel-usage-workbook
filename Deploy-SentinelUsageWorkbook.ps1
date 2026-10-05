[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
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
    [ValidatePattern('^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$')]
    [string] $WorkbookName,
    [switch] $Preview,
    [switch] $ValidateQueries,
    [string] $OutputDirectory = (Join-Path $PSScriptRoot 'generated')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AzureContext.ps1')
& (Join-Path $PSScriptRoot 'New-SentinelUsageWorkbook.ps1') `
    -TenantId $TenantId -AccountName $AccountName -WorkspaceResourceId $WorkspaceResourceId `
    -Region $Region -Currency $Currency -OutputDirectory $outputDirectory
if (-not $?) { throw 'Workbook generation failed.' }
& (Join-Path $PSScriptRoot 'Test-SentinelUsageWorkbook.ps1') `
    -TenantId $TenantId -AccountName $AccountName -OutputDirectory $outputDirectory -Live:$ValidateQueries
if (-not $?) { throw 'Workbook validation failed.' }

$workbook = Get-Content (Join-Path $outputDirectory 'sentinel-usage.workbook') -Raw | ConvertFrom-Json
$snapshot = Get-Content (Join-Path $outputDirectory 'pricing-snapshot.json') -Raw | ConvertFrom-Json
$parameters = @{
    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters = @{
        location = @{ value = $snapshot.region }
        workbookContent = @{ value = $workbook }
    }
}
if ($WorkbookName) { $parameters.parameters.workbookName = @{ value = $WorkbookName } }
$parameterPath = Join-Path $outputDirectory 'deployment-parameters.json'
$parameters | ConvertTo-Json -Depth 40 | Set-Content $parameterPath -Encoding utf8 -WhatIf:$false -Confirm:$false
$segments = $WorkspaceResourceId -split '/'
$subscriptionId = $segments[2]
$resourceGroup = $segments[4]
$templatePath = Join-Path $PSScriptRoot 'main.bicep'
$arguments = @(
    '--subscription', $subscriptionId, '--resource-group', $resourceGroup,
    '--template-file', $templatePath, '--parameters', "@$parameterPath"
)
$previewJson = Invoke-SentinelAz -TenantId $TenantId -AccountName $AccountName -Arguments (
    @('deployment', 'group', 'what-if', '--no-pretty-print', '-o', 'json') + $arguments
)
$previewResult = $previewJson | ConvertFrom-Json
if ($previewResult.status -ne 'Succeeded') { throw 'Deployment preview did not succeed.' }
$changes = @($previewResult.changes | Where-Object { $_.changeType -notin @('Ignore', 'NoChange') })
foreach ($change in $changes) {
    if ($change.resourceId -notmatch '/providers/Microsoft\.Insights/workbooks/[0-9a-f-]+$' -or
        $change.changeType -notin @('Create', 'Modify')) {
        throw "Unexpected deployment change: $($change.changeType) $($change.resourceId)."
    }
}
if ($changes.Count -gt 1) { throw 'Expected at most one workbook change.' }
$changes | Select-Object changeType, resourceId | Format-Table -AutoSize | Out-Host
Write-Host "Prices fetched at $($snapshot.fetchedAtUTC): $($snapshot.region), $($snapshot.currency)."
if ($Preview) { return }
if (-not $PSCmdlet.ShouldProcess($WorkspaceResourceId, 'Create or update the shared Sentinel usage workbook')) {
    return
}
$deploymentJson = Invoke-SentinelAz -TenantId $TenantId -AccountName $AccountName -Arguments (
    @('deployment', 'group', 'create', '--name', 'sentinel-usage-workbook', '-o', 'json') + $arguments
)
$deployment = $deploymentJson | ConvertFrom-Json
if ($deployment.properties.provisioningState -ne 'Succeeded') { throw 'Workbook deployment did not succeed.' }
$workbookId = $deployment.properties.outputs.workbookId.value
$token = Invoke-SentinelAz -TenantId $TenantId -AccountName $AccountName -Arguments @(
    'account', 'get-access-token', '--resource', 'https://management.azure.com',
    '--query', 'accessToken', '-o', 'tsv'
)
$saved = Invoke-RestMethod -Uri "https://management.azure.com${workbookId}?api-version=2023-06-01&canFetchContent=true" `
    -Headers @{ Authorization = "Bearer $token" }
if (-not $saved.properties.serializedData) {
    throw 'Workbook readback did not return serialized content. Verify deployment in the portal.'
}
$remote = $saved.properties.serializedData | ConvertFrom-Json
if (($remote | ConvertTo-Json -Depth 40 -Compress) -cne ($workbook | ConvertTo-Json -Depth 40 -Compress)) {
    throw 'Deployed workbook content differs from the generated workbook.'
}
Write-Host "Verified saved workbook: $($deployment.properties.outputs.portalUrl.value)"
