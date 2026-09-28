# ============================================
# CONTOSO - TERMINATION DETECTION
# Version: 1.6
# Alerts: IT-Support + HR
# ============================================

$LiveMode = $true
$FromEmail = "it-admin@contoso.com"
$ITSupportEmail = "it-support@contoso.com"
$HREmail = "hr@contoso.com"

# Accounts that should never be processed regardless of ADP status
$Exceptions = @("service.account@contoso.com")

$LicensesToRemove = @(
"<LICENSE_SKU_ID_1>",
"<LICENSE_SKU_ID_2>"
)

$LicenseNames = @{
    "<LICENSE_SKU_ID_1>" = "Microsoft 365 license"
    "<LICENSE_SKU_ID_2>" = "Microsoft Teams license"
}

$ADPCreds = Get-AutomationPSCredential -Name "HR-API-Credential"
$MSCreds = Get-AutomationPSCredential -Name "Graph-App-Credential"
$TenantId = Get-AutomationVariable -Name "Tenant-ID"
$ADPCert = Get-AutomationCertificate -Name "HR-API-Certificate"

$ADPClientId = $ADPCreds.UserName
$ADPClientSecret = $ADPCreds.GetNetworkCredential().Password
$ClientId = $MSCreds.UserName
$ClientSecret = $MSCreds.GetNetworkCredential().Password

Write-Output "============================================"
Write-Output " CONTOSO - TERMINATION DETECTION"
Write-Output " Mode: $(if ($LiveMode) { 'LIVE - WILL DISABLE ACCOUNTS' } else { 'REPORT ONLY - NO CHANGES' })"
Write-Output " Run time: $(Get-Date)"
Write-Output "============================================"

Write-Output "Connecting to ADP..."
try {
    $CertBytes = $ADPCert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx)
    $Cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($CertBytes, "", 20)
    Write-Output "Certificate loaded successfully"
} catch {
    Write-Output "Certificate error: $_"
    throw
}

$Credentials = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${ADPClientId}:${ADPClientSecret}"))
try {
    $ADPToken = Invoke-RestMethod -Uri "https://accounts.adp.com/auth/oauth/v2/token" -Method POST -Body @{ grant_type = "client_credentials" } -Certificate $Cert -Headers @{ Authorization = "Basic $Credentials" }
    $ADPHeaders = @{ Authorization = "Bearer $($ADPToken.access_token)" }
    Write-Output "Connected to ADP!"
} catch {
    Write-Output "ADP connection error: $_"
    throw
}

Write-Output "Downloading ADP records..."
$AllWorkers = @()
$Skip = 0
do {
    $Result = Invoke-RestMethod -Uri "https://api.adp.com/hr/v2/worker-demographics?`$top=50&`$skip=$Skip" -Headers $ADPHeaders -Certificate $Cert
    if ($null -eq $Result.workers -or $Result.workers.Count -eq 0) { break }
    $AllWorkers += $Result.workers
    $Skip += $Result.workers.Count
    Write-Output " $($AllWorkers.Count) records..."
} while ($Result.workers.Count -gt 0)

# Build ADP email set from ALL workers
$ADPEmailSet = @{}
foreach ($Worker in $AllWorkers) {
    $Email = $Worker.businessCommunication.emails | Where-Object { $_.emailUri -like "*@contoso.com" } | Select-Object -First 1 -ExpandProperty emailUri
    if ($Email) { $ADPEmailSet[$Email.ToLower()] = $true }
}

# Only look at terminations from the last 30 days
$CutoffDate = (Get-Date).AddDays(-30)
$TerminatedWorkers = $AllWorkers | Where-Object {
    $_.workerStatus.statusCode.codeValue -ne "Active" -and (
    $_.workAssignments | Where-Object {
        $_.assignmentStatus.effectiveDate -and
        [DateTime]::Parse($_.assignmentStatus.effectiveDate) -ge $CutoffDate
    }
    )
}
Write-Output "Recent terminations in ADP (last 30 days): $($TerminatedWorkers.Count)"

Write-Output "Connecting to Microsoft..."
$MSBody = @{ Grant_Type = "client_credentials"; Scope = "https://graph.microsoft.com/.default"; Client_Id = $ClientId; Client_Secret = $ClientSecret }
$MSToken = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Method POST -Body $MSBody
$MSHeaders = @{ Authorization = "Bearer $($MSToken.access_token)" }

$AllMSUsers = @()
$Uri = "https://graph.microsoft.com/v1.0/users?`$select=displayName,jobTitle,department,mail,accountEnabled&`$top=100"
do {
    $Result = Invoke-RestMethod -Uri $Uri -Headers $MSHeaders
    $AllMSUsers += $Result.value
    $Uri = $Result.'@odata.nextLink'
} while ($Uri)
Write-Output "Microsoft users pulled: $($AllMSUsers.Count)"

Write-Output "Checking for active Microsoft accounts that are terminated in ADP..."
$Terminated = @()

foreach ($Worker in $TerminatedWorkers) {
    $WorkEmail = $Worker.businessCommunication.emails | Where-Object { $_.emailUri -like "*@contoso.com" } | Select-Object -First 1 -ExpandProperty emailUri
    if ($null -eq $WorkEmail) { continue }

    # Skip exception list
    if ($Exceptions -contains $WorkEmail.ToLower()) {
        Write-Output " SKIPPED — Exception list: $WorkEmail"
        continue
    }

    # Email match only — account must still be enabled in Microsoft
    $MSUser = $AllMSUsers | Where-Object { $_.mail -eq $WorkEmail -and $_.accountEnabled -eq $true } | Select-Object -First 1
    if ($null -eq $MSUser) { continue }

    # Only process if this account exists in ADP
    if (-not $ADPEmailSet.ContainsKey($MSUser.mail.ToLower())) { continue }

    $ADPName = $Worker.person.legalName.formattedName
    Write-Output " TERMINATION DETECTED: $ADPName ($WorkEmail)"

    $UserLicenseIds = @()
    $UserLicenseNames = @()
    try {
        $LicenseResult = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$WorkEmail/licenseDetails" -Headers $MSHeaders
        $UserLicenseIds = $LicenseResult.value | Select-Object -ExpandProperty skuId
        $UserLicenseNames = $UserLicenseIds | Where-Object { $LicenseNames.ContainsKey($_) } | ForEach-Object { $LicenseNames[$_] }
    } catch {
        Write-Output " Could not get licenses for $WorkEmail"
    }

    $UserGroups = @()
    $UserGroupNames = @()
    try {
        $GroupResult = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$WorkEmail/memberOf" -Headers $MSHeaders
        $UserGroups = $GroupResult.value | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' }
        $UserGroupNames = $UserGroups | Select-Object -ExpandProperty displayName
    } catch {
        Write-Output " Could not get groups for $WorkEmail"
    }

    $LicensesFound = $UserLicenseIds | Where-Object { $LicensesToRemove -contains $_ }
    $ActionsTaken = @()

    if ($LiveMode) {
        try {
            Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$WorkEmail" -Method PATCH -Headers $MSHeaders -Body (@{ accountEnabled = $false } | ConvertTo-Json) -ContentType "application/json"
            $ActionsTaken += "Account disabled"
            Write-Output " DISABLED: $WorkEmail"
        } catch {
            $ActionsTaken += "Failed to disable account"
        }

        try {
            Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$WorkEmail/revokeSignInSessions" -Method POST -Headers $MSHeaders
            $ActionsTaken += "All sessions revoked"
        } catch {
            $ActionsTaken += "Failed to revoke sessions"
        }

        if ($LicensesFound.Count -gt 0) {
            $RemoveLicenseBody = @{ addLicenses = @(); removeLicenses = $LicensesFound } | ConvertTo-Json -Depth 5
            try {
                Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$WorkEmail/assignLicense" -Method POST -Headers $MSHeaders -Body $RemoveLicenseBody -ContentType "application/json"
                $ActionsTaken += "Licenses removed: $($UserLicenseNames -join ', ')"
            } catch {
                $ActionsTaken += "Failed to remove licenses"
            }
        } else {
            $ActionsTaken += "No matching licenses found"
        }

        $GroupsRemoved = @()
        $GroupsFailed = @()
        foreach ($Group in $UserGroups) {
            try {
                Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups/$($Group.id)/members/$WorkEmail/`$ref" -Method DELETE -Headers $MSHeaders
                $GroupsRemoved += $Group.displayName
            } catch {
                $GroupsFailed += $Group.displayName
            }
        }
        if ($GroupsRemoved.Count -gt 0) { $ActionsTaken += "Removed from $($GroupsRemoved.Count) groups" }
        if ($GroupsFailed.Count -gt 0) { $ActionsTaken += "Failed to remove from: $($GroupsFailed -join ', ')" }
    } else {
        $ActionsTaken += "REPORT ONLY - no changes made"
    }

    $Terminated += [PSCustomObject]@{
        Name = $ADPName
        Email = $WorkEmail
        Title = $MSUser.jobTitle
        Dept = $MSUser.department
        Licenses = if ($UserLicenseNames.Count -gt 0) { $UserLicenseNames -join ", " } else { "None" }
        Groups = if ($UserGroupNames.Count -gt 0) { $UserGroupNames -join ", " } else { "None" }
        ActionsTaken = $ActionsTaken -join " | "
    }
}

Write-Output "============================================"
Write-Output " TERMINATION CHECK COMPLETE"
Write-Output " Terminated accounts found: $($Terminated.Count)"
Write-Output " Mode: $(if ($LiveMode) { 'LIVE - accounts processed' } else { 'REPORT ONLY - nothing changed' })"
Write-Output "============================================"

if ($Terminated.Count -gt 0) {
    $TermRows = $Terminated | ForEach-Object {
        "
<tr style='background:#f9f9f9'>
<td colspan='2' style='background:#333;color:white;padding:8px'><strong>$($_.Name)</strong> — $($_.Email)</td>
</tr>
<tr><td><strong>Job Title</strong></td><td>$($_.Title)</td></tr>
<tr><td><strong>Department</strong></td><td>$($_.Dept)</td></tr>
<tr><td><strong>Licenses</strong></td><td>$($_.Licenses)</td></tr>
<tr><td><strong>Groups</strong></td><td>$($_.Groups)</td></tr>
<tr><td><strong>Actions</strong></td><td>$($_.ActionsTaken)</td></tr>
<tr><td colspan='2'>&nbsp;</td></tr>"
    }

    $Body = "
<h2>Termination Detection Report</h2>
<p><strong>Run time:</strong> $(Get-Date)</p>
<p><strong>Mode:</strong> $(if ($LiveMode) { '<span style=color:red>LIVE - Actions were taken</span>' } else { '<span style=color:orange>REPORT ONLY - No changes made</span>' })</p>
<p><strong>Terminations detected this run: $($Terminated.Count)</strong></p>
<hr>
<table border='1' cellpadding='6' style='border-collapse:collapse;width:100%'>
$($TermRows -join '')
</table>
<br>
<p>$(if ($LiveMode) { 'All actions completed automatically. Please verify and remove any remaining access if needed.' } else { '<strong>REPORT ONLY — No changes were made.</strong> Set $LiveMode to $true to enable automatic processing.' })</p>"

    $Message = @{
        message = @{
            subject = "Termination Alert — $($Terminated.Count) employee(s) detected — $(Get-Date -Format 'yyyy-MM-dd')"
            body = @{ contentType = "HTML"; content = $Body }
            toRecipients = @(
            @{ emailAddress = @{ address = $ITSupportEmail } }
            @{ emailAddress = @{ address = $HREmail } }
            )
        }
    } | ConvertTo-Json -Depth 10

    try {
        Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$FromEmail/sendMail" -Method POST -Headers $MSHeaders -Body $Message -ContentType "application/json"
        Write-Output "Digest alert sent — $($Terminated.Count) termination(s)"
    } catch {
        Write-Output "Failed to send digest alert: $_"
    }
} else {
    Write-Output "No new terminations detected this run."
}
