function Invoke-SentinelAz {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $TenantId,
        [string] $AccountName,
        [Parameter(Mandatory)][string[]] $Arguments
    )

    $contextJson = & az account show -o json
    if ($LASTEXITCODE -ne 0) {
        throw "Azure context unavailable. Run az login --tenant $TenantId --allow-no-subscriptions."
    }
    $context = $contextJson | ConvertFrom-Json
    if ($context.tenantId -ne $TenantId -or ($AccountName -and $context.user.name -ne $AccountName)) {
        throw 'Azure tenant/account does not match the requested identity. No operation was performed.'
    }
    $cloudName = if ($context.environmentName) { $context.environmentName } else { $context.cloudName }
    if ($cloudName -ne 'AzureCloud') {
        throw 'Only Azure public cloud endpoints are supported.'
    }
    $result = & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: $($Arguments[0]) $($Arguments[1])."
    }
    return $result
}
