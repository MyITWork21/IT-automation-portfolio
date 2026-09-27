# ============================================
# CONTOSO - ADP TO MICROSOFT SYNC
# Version: 2.0
# Report email: it-automation@contoso.com
# ============================================

$LiveMode = $false
$ReportEmail = "it-automation@contoso.com"
$FromEmail = "it-automation@contoso.com"

$ADPCreds = Get-AutomationPSCredential -Name "HR-API-Credential"
$MSCreds = Get-AutomationPSCredential -Name "Graph-App-Credential"
$TenantId = Get-AutomationVariable -Name "Tenant-ID"
$ADPCert = Get-AutomationCertificate -Name "HR-API-Certificate"

$ADPClientId = $ADPCreds.UserName
$ADPClientSecret = $ADPCreds.GetNetworkCredential().Password
$ClientId = $MSCreds.UserName
$ClientSecret = $MSCreds.GetNetworkCredential().Password

function Get-ActiveAssignment { param($WorkAssignments)
    return $WorkAssignments | Where-Object {
        $_.assignmentStatus.statusCode.codeValue -eq "A"
    } | Select-Object -First 1
}

function Get-CleanTitle { param($Raw)
    if ($null -eq $Raw -or $Raw -eq "") { return "" }
    return ($Raw -replace '^[A-Z]+\s*-\s*', '').Trim()
}

function Get-CleanDept { param($Raw)
    if ($null -eq $Raw -or $Raw -eq "") { return "" }
    return ($Raw -replace '^.*\d+\s+', '').Trim()
}

Write-Output "============================================"
Write-Output " CONTOSO - ADP TO MICROSOFT SYNC"
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

$DuplicateEmails = $ActiveWorkers | ForEach-Object {
    $_.businessCommunication.emails | Where-Object { $_.emailUri -like "*@contoso.com" } | Select-Object -First 1 -ExpandProperty emailUri
} | Where-Object { $_ } | Group-Object | Where-Object { $_.Count -gt 1 } | Select-Object -ExpandProperty Name

Write-Output "Connecting to Microsoft..."
$MSBody = @{ Grant_Type = "client_credentials"; Scope = "https://graph.microsoft.com/.default"; Client_Id = $ClientId; Client_Secret = $ClientSecret }
$MSToken = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Method POST -Body $MSBody
$MSHeaders = @{ Authorization = "Bearer $($MSToken.access_token)" }

$AllMSUsers = @()
$Uri = "https://graph.microsoft.com/v1.0/users?`$select=displayName,jobTitle,department,officeLocation,mail,accountEnabled,usageLocation&`$top=100"
do {
    $Result = Invoke-RestMethod -Uri $Uri -Headers $MSHeaders
    $AllMSUsers += $Result.value
    $Uri = $Result.'@odata.nextLink'
} while ($Uri)
Write-Output "Microsoft users pulled: $($AllMSUsers.Count)"

Write-Output "Comparing ADP vs Microsoft..."
$Report = @()
$ManualItems = @()
$Matched = 0
$Mismatches = 0
$Skipped = 0

foreach ($Worker in $ActiveWorkers) {
    $WorkEmail = $Worker.businessCommunication.emails | Where-Object { $_.emailUri -like "*@contoso.com" } | Select-Object -First 1 -ExpandProperty emailUri
    $ADPName = $Worker.person.legalName.formattedName

    if ($null -eq $WorkEmail -or $WorkEmail -eq "") { $Skipped++; continue }

    if ($DuplicateEmails -contains $WorkEmail) {
        $ManualItems += [PSCustomObject]@{ Name = $ADPName; Email = $WorkEmail; Issue = "Duplicate email in ADP" }
        continue
    }

    $ActiveAssignment = Get-ActiveAssignment $Worker.workAssignments
    if ($null -eq $ActiveAssignment) { $Skipped++; continue }

    $ADPTitle = Get-CleanTitle $ActiveAssignment.jobTitle
    $ADPDept = Get-CleanDept ($ActiveAssignment.homeOrganizationalUnits | Where-Object { $_.typeCode.codeValue -ne "Business Unit" } | Select-Object -First 1).nameCode.longName

    $MSUser = $AllMSUsers | Where-Object { $_.mail -eq $WorkEmail -and $_.accountEnabled -eq $true } | Select-Object -First 1

    if ($null -eq $MSUser) {
        $ManualItems += [PSCustomObject]@{
            Name = $ADPName
            Email = $WorkEmail
            Issue = "Active in ADP but no Microsoft account found"
        }
        continue
    }

    if (-not $ADPEmailSet.ContainsKey($MSUser.mail.ToLower())) { $Skipped++; continue }
    if ($MSUser.usageLocation -ne "US") { $Skipped++; continue }

    $UpdateBody = @{}
    $HasMismatch = $false

    $MSTitle = [string]$MSUser.jobTitle
    if ($ADPTitle -and $ADPTitle -ne $MSTitle) {
        $HasMismatch = $true
        $Mismatches++
        $UpdateBody["jobTitle"] = $ADPTitle
        $Report += [PSCustomObject]@{
            Name = $MSUser.displayName
            Email = $MSUser.mail
            Field = "Job Title"
            ADP_Value = $ADPTitle
            MS_Value = $MSTitle
            Action = if ($LiveMode) { "Updated" } else { "Would update" }
        }
    }

    $MSDept = [string]$MSUser.department
    if ($ADPDept -and $ADPDept -ne $MSDept) {
        $HasMismatch = $true
        $Mismatches++
        $UpdateBody["department"] = $ADPDept
        $Report += [PSCustomObject]@{
            Name = $MSUser.displayName
            Email = $MSUser.mail
            Field = "Department"
            ADP_Value = $ADPDept
            MS_Value = $MSDept
            Action = if ($LiveMode) { "Updated" } else { "Would update" }
        }
    }

    if ($LiveMode -and $UpdateBody.Count -gt 0) {
        try {
            Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$($MSUser.mail)" -Method PATCH -Headers $MSHeaders -Body ($UpdateBody | ConvertTo-Json) -ContentType "application/json"
            Write-Output " UPDATED: $($MSUser.mail)"
        } catch {
            Write-Output " FAILED: $($MSUser.mail) — $_"
            $ManualItems += [PSCustomObject]@{
                Name = $MSUser.displayName
                Email = $MSUser.mail
                Issue = "Update failed: $_"
            }
        }
    }

    if (-not $HasMismatch) { $Matched++ }
}

Write-Output "============================================"
Write-Output " SYNC COMPLETE"
Write-Output " Matched: $Matched"
Write-Output " Mismatches: $Mismatches"
Write-Output " Manual Review: $($ManualItems.Count)"
Write-Output " Skipped: $Skipped"
Write-Output " Mode: $(if ($LiveMode) { 'LIVE - changes were made' } else { 'REPORT ONLY - nothing changed' })"
Write-Output "============================================"

$EmailRows = $Report | ForEach-Object {
    "<tr><td>$($_.Name)</td><td>$($_.Email)</td><td>$($_.Field)</td><td>$($_.ADP_Value)</td><td>$($_.MS_Value)</td><td>$($_.Action)</td></tr>"
}

$ManualRows = $ManualItems | ForEach-Object {
    "<tr><td>$($_.Name)</td><td>$($_.Email)</td><td>$($_.Issue)</td></tr>"
}

$EmailHTML = "
<h2>ADP to Microsoft Sync Report</h2>
<p><strong>Run time:</strong> $(Get-Date)</p>
<p><strong>Mode:</strong> $(if ($LiveMode) { '<span style=color:red>LIVE - Changes were made</span>' } else { '<span style=color:green>REPORT ONLY - Nothing was changed</span>' })</p>
<hr>
<h3>Summary</h3>
<table border='1' cellpadding='5' style='border-collapse:collapse'>
<tr><td><strong>Matched</strong></td><td>$Matched</td></tr>
<tr><td><strong>Mismatches found</strong></td><td>$Mismatches</td></tr>
<tr><td><strong>Manual review needed</strong></td><td>$($ManualItems.Count)</td></tr>
<tr><td><strong>Skipped</strong></td><td>$Skipped</td></tr>
</table>
<br>
<h3>Details</h3>
<table border='1' cellpadding='5' style='border-collapse:collapse'>
<tr style='background:#f0f0f0'><th>Name</th><th>Email</th><th>Field</th><th>ADP Says</th><th>Microsoft Says</th><th>Action</th></tr>
$($EmailRows -join '')
</table>
$(if ($ManualItems.Count -gt 0) { "
<br>
<h3>⚠️ Manual Review Needed</h3>
<table border='1' cellpadding='5' style='border-collapse:collapse'>
<tr style='background:#fff3cd'><th>Name</th><th>Email</th><th>Issue</th></tr>
$($ManualRows -join '')
</table>" })"

$EmailMessage = @{
    message = @{
        subject = "ADP Sync Report - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
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
