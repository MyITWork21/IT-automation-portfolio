# ============================================
# CONTOSO - ADP BUSINESS UNIT SYNC
# Version: 1.4
# Report email: it-automation@contoso.com
# ============================================

$LiveMode = $true
$ReportEmail = "it-automation@contoso.com"
$FromEmail = "it-automation@contoso.com"
$ITSupportEmail = "it-support@contoso.com"

$ADPCreds = Get-AutomationPSCredential -Name "HR-API-Credential"
$MSCreds = Get-AutomationPSCredential -Name "Graph-App-Credential"
$TenantId = Get-AutomationVariable -Name "Tenant-ID"
$ADPCert = Get-AutomationCertificate -Name "HR-API-Certificate"

$ADPClientId = $ADPCreds.UserName
$ADPClientSecret = $ADPCreds.GetNetworkCredential().Password
$ClientId = $MSCreds.UserName
$ClientSecret = $MSCreds.GetNetworkCredential().Password

# Load known business units from Azure variable
$KnownBUraw = Get-AutomationVariable -Name "Known-BusinessUnits"
$KnownBusinessUnits = $KnownBUraw -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ }
Write-Output "Known business units loaded: $($KnownBusinessUnits.Count)"

function Get-BusinessUnit { param($WorkAssignments)
    $ActiveAssignment = $WorkAssignments | Where-Object {
        $_.assignmentStatus.statusCode.codeValue -eq "A"
    } | Select-Object -First 1

    if ($null -eq $ActiveAssignment) { return "" }

    $BURaw = $ActiveAssignment.homeOrganizationalUnits | Where-Object {
        $_.typeCode.codeValue -eq "Business Unit"
    } | Select-Object -First 1

    if ($null -eq $BURaw) { return "" }

    $Name = ""
    if ($BURaw.nameCode.shortName -and $BURaw.nameCode.shortName -ne "Business Unit") {
        $Name = $BURaw.nameCode.shortName
    } elseif ($BURaw.nameCode.longName) {
        $Name = $BURaw.nameCode.longName
    }

    # Add Contoso prefix if missing
    if ($Name -and -not $Name.StartsWith("Contoso")) {
        $Name = "Contoso $Name"
    }

    return $Name
}

Write-Output "============================================"
Write-Output " CONTOSO - BUSINESS UNIT SYNC"
Write-Output " Mode: $(if ($LiveMode) { 'LIVE - MAKING CHANGES' } else { 'REPORT ONLY - NO CHANGES' })"
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

$ActiveWorkers = $AllWorkers | Where-Object { $_.workerStatus.statusCode.codeValue -eq "Active" }
Write-Output "Total ADP records: $($AllWorkers.Count)"
Write-Output "Active employees: $($ActiveWorkers.Count)"

$ADPEmailSet = @{}
foreach ($Worker in $ActiveWorkers) {
    $Email = $Worker.businessCommunication.emails | Where-Object { $_.emailUri -like "*@contoso.com" } | Select-Object -First 1 -ExpandProperty emailUri
    if ($Email) { $ADPEmailSet[$Email.ToLower()] = $true }
}

Write-Output "Connecting to Microsoft..."
$MSBody = @{ Grant_Type = "client_credentials"; Scope = "https://graph.microsoft.com/.default"; Client_Id = $ClientId; Client_Secret = $ClientSecret }
$MSToken = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Method POST -Body $MSBody
$MSHeaders = @{ Authorization = "Bearer $($MSToken.access_token)" }

$AllMSUsers = @()
$Uri = "https://graph.microsoft.com/v1.0/users?`$select=displayName,officeLocation,mail,accountEnabled,usageLocation&`$top=100"
do {
    $Result = Invoke-RestMethod -Uri $Uri -Headers $MSHeaders
    $AllMSUsers += $Result.value
    $Uri = $Result.'@odata.nextLink'
} while ($Uri)
Write-Output "Microsoft users pulled: $($AllMSUsers.Count)"

Write-Output "Comparing ADP vs Microsoft..."
$Report = @()
$ManualItems = @()
$NewBusinessUnits = @()
$Matched = 0
$Mismatches = 0
$Skipped = 0

foreach ($Worker in $ActiveWorkers) {
    $WorkEmail = $Worker.businessCommunication.emails | Where-Object { $_.emailUri -like "*@contoso.com" } | Select-Object -First 1 -ExpandProperty emailUri
    $ADPName = $Worker.person.legalName.formattedName

    if ($null -eq $WorkEmail -or $WorkEmail -eq "") { $Skipped++; continue }

    $ADPBusinessUnit = Get-BusinessUnit $Worker.workAssignments

    $MSUser = $AllMSUsers | Where-Object {
        $_.mail -eq $WorkEmail -and
        $_.accountEnabled -eq $true -and
        $_.usageLocation -eq "US"
    } | Select-Object -First 1

    if ($null -eq $MSUser) { $Skipped++; continue }
    if (-not $ADPEmailSet.ContainsKey($MSUser.mail.ToLower())) { $Skipped++; continue }

    $MSOfficeLocation = [string]$MSUser.officeLocation

    if (-not $ADPBusinessUnit) {
        $ManualItems += [PSCustomObject]@{
            Name = $MSUser.displayName
            Email = $MSUser.mail
            Issue = "No Business Unit found in ADP — current Microsoft value: '$MSOfficeLocation'"
        }
        continue
    }

    # Check if new — not in Azure variable list and not already flagged this run
    if ($ADPBusinessUnit -notin $KnownBusinessUnits -and $ADPBusinessUnit -notin $NewBusinessUnits) {
        $NewBusinessUnits += $ADPBusinessUnit
        Write-Output " NEW BUSINESS UNIT DETECTED: $ADPBusinessUnit"
    }

    if ($ADPBusinessUnit -ne $MSOfficeLocation) {
        $Mismatches++
        $Report += [PSCustomObject]@{
            Name = $MSUser.displayName
            Email = $MSUser.mail
            ADP_Value = $ADPBusinessUnit
            MS_Value = $MSOfficeLocation
            Action = if ($LiveMode) { "Updated" } else { "Would update" }
        }

        if ($LiveMode) {
            try {
                $Body = @{ officeLocation = $ADPBusinessUnit } | ConvertTo-Json
                Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$($MSUser.mail)" -Method PATCH -Headers $MSHeaders -Body $Body -ContentType "application/json"
                Write-Output " UPDATED: $($MSUser.mail) → $ADPBusinessUnit"
            } catch {
                Write-Output " FAILED: $($MSUser.mail) — $_"
                $ManualItems += [PSCustomObject]@{
                    Name = $MSUser.displayName
                    Email = $MSUser.mail
                    Issue = "Update failed: $_"
                }
            }
        }
    } else {
        $Matched++
    }
}

# Save any new business units back to Azure variable
if ($NewBusinessUnits.Count -gt 0) {
    $AllKnown = ($KnownBusinessUnits + $NewBusinessUnits) | Select-Object -Unique
    try {
        Set-AutomationVariable -Name "Known-BusinessUnits" -Value ($AllKnown -join ",")
        Write-Output "Updated Known-BusinessUnits — total known: $($AllKnown.Count)"
        Write-Output "Current list: $($AllKnown -join ', ')"
    } catch {
        Write-Output "FAILED to update Known-BusinessUnits: $_"
    }

    $NewBURows = $NewBusinessUnits | ForEach-Object { "<tr><td>$_</td></tr>" }
    $Subject = "New Business Unit(s) Detected in ADP — $(Get-Date -Format 'yyyy-MM-dd')"
    $Body = "
<h2>New Business Unit(s) Detected</h2>
<p>The following new business unit(s) have been detected in ADP for the first time.</p>
<table border='1' cellpadding='5' style='border-collapse:collapse'>
<tr style='background:#cce5ff'><th>Business Unit</th></tr>
$($NewBURows -join '')
</table>
<br>
<p><strong>Detected:</strong> $(Get-Date)</p>
<br>
<p>Please review and create the following resources as needed:</p>
<ul>
<li>Distribution list</li>
<li>Microsoft Teams channel</li>
<li>SharePoint site</li>
<li>Any other resources needed for this location</li>
</ul>
<p>Microsoft 365 user profiles have already been updated automatically. You will not receive this alert again for these business units.</p>"

    $Message = @{
        message = @{
            subject = $Subject
            body = @{ contentType = "HTML"; content = $Body }
            toRecipients = @(@{ emailAddress = @{ address = $ITSupportEmail } })
        }
    } | ConvertTo-Json -Depth 10

    try {
        Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$FromEmail/sendMail" -Method POST -Headers $MSHeaders -Body $Message -ContentType "application/json"
        Write-Output "New BU alert sent for: $($NewBusinessUnits -join ', ')"
    } catch {
        Write-Output "Failed to send new BU alert: $_"
    }
}

Write-Output "============================================"
Write-Output " BUSINESS UNIT SYNC COMPLETE"
Write-Output " Matched: $Matched"
Write-Output " Mismatches: $Mismatches"
Write-Output " New Business Units: $($NewBusinessUnits.Count)"
Write-Output " Manual Review: $($ManualItems.Count)"
Write-Output " Skipped: $Skipped"
Write-Output " Mode: $(if ($LiveMode) { 'LIVE - changes were made' } else { 'REPORT ONLY - nothing changed' })"
Write-Output "============================================"

$EmailRows = $Report | ForEach-Object {
    "<tr><td>$($_.Name)</td><td>$($_.Email)</td><td>$($_.ADP_Value)</td><td>$($_.MS_Value)</td><td>$($_.Action)</td></tr>"
}

$ManualRows = $ManualItems | ForEach-Object {
    "<tr><td>$($_.Name)</td><td>$($_.Email)</td><td>$($_.Issue)</td></tr>"
}

$EmailHTML = "
<h2>ADP Business Unit Sync Report</h2>
<p><strong>Run time:</strong> $(Get-Date)</p>
<p><strong>Mode:</strong> $(if ($LiveMode) { '<span style=color:red>LIVE - Changes were made</span>' } else { '<span style=color:green>REPORT ONLY - Nothing was changed</span>' })</p>
<hr>
<h3>Summary</h3>
<table border='1' cellpadding='5' style='border-collapse:collapse'>
<tr><td><strong>Matched</strong></td><td>$Matched</td></tr>
<tr><td><strong>Mismatches found</strong></td><td>$Mismatches</td></tr>
<tr><td><strong>New business units detected</strong></td><td>$($NewBusinessUnits.Count)</td></tr>
<tr><td><strong>Manual review needed</strong></td><td>$($ManualItems.Count)</td></tr>
<tr><td><strong>Skipped</strong></td><td>$Skipped</td></tr>
</table>
$(if ($NewBusinessUnits.Count -gt 0) { "
<br>
<h3>🆕 New Business Units Detected</h3>
<table border='1' cellpadding='5' style='border-collapse:collapse'>
<tr style='background:#cce5ff'><th>Business Unit</th></tr>
$($NewBusinessUnits | ForEach-Object { "<tr><td>$_</td></tr>" })
</table>" })
$(if ($Report.Count -gt 0) { "
<br>
<h3>✅ Business Unit Changes</h3>
<table border='1' cellpadding='5' style='border-collapse:collapse'>
<tr style='background:#d4edda'><th>Name</th><th>Email</th><th>ADP Says</th><th>Microsoft Says</th><th>Action</th></tr>
$($EmailRows -join '')
</table>" })
$(if ($ManualItems.Count -gt 0) { "
<br>
<h3>⚠️ Manual Review Needed</h3>
<table border='1' cellpadding='5' style='border-collapse:collapse'>
<tr style='background:#fff3cd'><th>Name</th><th>Email</th><th>Issue</th></tr>
$($ManualRows -join '')
</table>" })"

$EmailMessage = @{
    message = @{
        subject = "ADP Business Unit Sync Report - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        body = @{ contentType = "HTML"; content = $EmailHTML }
        toRecipients = @(@{ emailAddress = @{ address = $ReportEmail } })
    }
} | ConvertTo-Json -Depth 10

try {
    Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$FromEmail/sendMail" -Method POST -Headers $MSHeaders -Body $EmailMessage -ContentType "application/json"
    Write-Output "Report emailed to $ReportEmail"
} catch {
    Write-Output "Email failed: $_"
}
