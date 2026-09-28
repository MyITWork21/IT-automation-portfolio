<#
.SYNOPSIS
    Contoso — Dynamic Distribution List Provisioning
    Exchange Online | PowerShell 7
.DESCRIPTION
    Creates and configures all dynamic distribution lists
    across all states and US-wide departments. Filters are based on
    Office Location and Department attributes in Entra ID.
#>

Connect-ExchangeOnline -UserPrincipalName "admin@contoso.com" -ShowBanner:$false

# ─────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────

$states = @{
    NY = "Contoso New York"
    TX = "Contoso Texas"
    CA = "Contoso California"
    FL = "Contoso Florida"
    HQ = "Contoso Headquarters"
}

$stateDepts = @("Operations", "Customer Success", "Sales")

$usDepts = @(
    "Operations", "Customer Success", "Sales", "Finance",
    "HR", "Marketing", "IT"
)

# ─────────────────────────────────────────────────────────────
# HELPER
# ─────────────────────────────────────────────────────────────

function New-DDL {
    param($Name, $Alias, $Email, $Filter)
    $existing = Get-DynamicDistributionGroup -Identity $Email -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  EXISTS : $Name" -ForegroundColor Yellow
    } else {
        New-DynamicDistributionGroup -Name $Name -Alias $Alias -PrimarySmtpAddress $Email -RecipientFilter $Filter | Out-Null
        Write-Host "  CREATED: $Name" -ForegroundColor Green
    }
}

# ─────────────────────────────────────────────────────────────
# STATE TEAM DLs
# ─────────────────────────────────────────────────────────────

Write-Host "`n[ STATE TEAM DLs ]" -ForegroundColor Cyan

foreach ($code in $states.Keys) {
    $office = $states[$code]
    $prefix = $code.ToLower()

    New-DDL `
        -Name "$code Team" `
        -Alias "dl-$($prefix)team" `
        -Email "dl-$($prefix)team@contoso.com" `
        -Filter "(RecipientTypeDetails -eq 'UserMailbox') -and (Office -eq '$office')"
}

# ─────────────────────────────────────────────────────────────
# STATE DEPARTMENT DLs
# ─────────────────────────────────────────────────────────────

Write-Host "`n[ STATE DEPARTMENT DLs ]" -ForegroundColor Cyan

foreach ($code in $states.Keys) {
    $office = $states[$code]
    $prefix = $code.ToLower()

    foreach ($dept in $stateDepts) {
        $deptAlias = $dept.ToLower() -replace ' ', ''
        New-DDL `
            -Name "$code $dept" `
            -Alias "dl-$prefix$deptAlias" `
            -Email "dl-$prefix$deptAlias@contoso.com" `
            -Filter "(RecipientTypeDetails -eq 'UserMailbox') -and (Office -eq '$office') -and (Department -eq '$dept')"
    }
}

# ─────────────────────────────────────────────────────────────
# US-WIDE DEPARTMENT DLs
# ─────────────────────────────────────────────────────────────

Write-Host "`n[ US-WIDE DEPARTMENT DLs ]" -ForegroundColor Cyan

foreach ($dept in $usDepts) {
    $deptAlias = $dept.ToLower() -replace '[^a-z]', ''
    New-DDL `
        -Name "US $dept" `
        -Alias "dl-us$deptAlias" `
        -Email "dl-us$deptAlias@contoso.com" `
        -Filter "(RecipientTypeDetails -eq 'UserMailbox') -and (AccountDisabled -eq `$false) -and (Department -eq '$dept')"
}

# US Product and Engineering (catches both department values)
New-DDL `
    -Name "US Product" `
    -Alias "dl-usproduct" `
    -Email "dl-usproduct@contoso.com" `
    -Filter "(RecipientTypeDetails -eq 'UserMailbox') -and (AccountDisabled -eq `$false) -and ((Department -eq 'Product') -or (Department -eq 'Product & Engineering'))"

New-DDL `
    -Name "US Engineering" `
    -Alias "dl-usengineering" `
    -Email "dl-usengineering@contoso.com" `
    -Filter "(RecipientTypeDetails -eq 'UserMailbox') -and (AccountDisabled -eq `$false) -and (Department -eq 'Engineering')"

# ─────────────────────────────────────────────────────────────
# US TEAM
# ─────────────────────────────────────────────────────────────

Write-Host "`n[ US TEAM ]" -ForegroundColor Cyan

New-DDL `
    -Name "US Team" `
    -Alias "dl-usteam" `
    -Email "dl-usteam@contoso.com" `
    -Filter "(RecipientTypeDetails -eq 'UserMailbox') -and (AccountDisabled -eq `$false) -and (CountryOrRegion -eq 'United States') -and (Department -ne `$null)"

# ─────────────────────────────────────────────────────────────
# US REVENUE OPERATIONS (department + pinned members)
# ─────────────────────────────────────────────────────────────

Write-Host "`n[ US REVENUE OPERATIONS ]" -ForegroundColor Cyan

$revOpsMembers = @(
    "user1@contoso.com",
    "user2@contoso.com",
    "user3@contoso.com"
)

$revOpsFilter = "(RecipientTypeDetails -eq 'UserMailbox') -and (AccountDisabled -eq `$false) -and ((Department -eq 'Revenue Ops')" +
    ($revOpsMembers | ForEach-Object { " -or (PrimarySmtpAddress -eq '$_')" }) + ")"

New-DDL `
    -Name "US Revenue Operations" `
    -Alias "dl-usrevenueoperations" `
    -Email "dl-usrevenueoperations@contoso.com" `
    -Filter $revOpsFilter

# ─────────────────────────────────────────────────────────────
# DONE
# ─────────────────────────────────────────────────────────────

Write-Host "`nAll distribution lists provisioned." -ForegroundColor Cyan
Disconnect-ExchangeOnline -Confirm:$false
