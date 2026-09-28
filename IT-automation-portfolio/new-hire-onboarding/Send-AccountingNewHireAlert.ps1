# ============================================
# CONTOSO - NEW HIRE NOTIFICATIONS
# Version: 1.8
# ============================================

$LiveMode = $true
$SendToHires = $true
$FromEmail = "accounting@contoso.com"
$AccountingEmail = "accounting@contoso.com"
$LookbackDays = 7

$ExpenseInviteEntityA = Get-AutomationVariable -Name "ExpenseApp-Invite-EntityA"
$ExpenseInviteEntityB = Get-AutomationVariable -Name "ExpenseApp-Invite-EntityB"
$ExpenseInviteEntityC = Get-AutomationVariable -Name "ExpenseApp-Invite-EntityC"
$ADPLink = "https://workforcenow.adp.com"
$LogicAppURL = Get-AutomationVariable -Name "LogicApp-ExpenseInvite-URL"

$ADPCreds = Get-AutomationPSCredential -Name "HR-API-Credential"
$MSCreds = Get-AutomationPSCredential -Name "Graph-App-Credential"
$TenantId = Get-AutomationVariable -Name "Tenant-ID"
$ADPCert = Get-AutomationCertificate -Name "HR-API-Certificate"

$ADPClientId = $ADPCreds.UserName
$ADPClientSecret = $ADPCreds.GetNetworkCredential().Password
$ClientId = $MSCreds.UserName
$ClientSecret = $MSCreds.GetNetworkCredential().Password

Write-Output "============================================"
Write-Output " CONTOSO - NEW HIRE NOTIFICATIONS"
Write-Output " Mode: $(if ($LiveMode) { 'LIVE - SENDING EMAILS' } else { 'REPORT ONLY - NO EMAILS' })"
Write-Output " Lookback: $LookbackDays days"
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
Write-Output "Total active workers: $($ActiveWorkers.Count)"

$CutoffDate = (Get-Date).AddDays(-$LookbackDays)
$NewHires = $ActiveWorkers | Where-Object {
    $ActiveAssignment = $_.workAssignments | Where-Object { $_.assignmentStatus.statusCode.codeValue -eq "A" } | Select-Object -First 1
    $ActiveAssignment -and
    $ActiveAssignment.hireDate -and
    [DateTime]::Parse($ActiveAssignment.hireDate) -ge $CutoffDate
}

Write-Output "New hires in last $LookbackDays days: $($NewHires.Count)"

Write-Output "Connecting to Microsoft..."
$MSBody = @{ Grant_Type = "client_credentials"; Scope = "https://graph.microsoft.com/.default"; Client_Id = $ClientId; Client_Secret = $ClientSecret }
$MSToken = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Method POST -Body $MSBody
$MSHeaders = @{ Authorization = "Bearer $($MSToken.access_token)" }

$AllMSUsers = @()
$Uri = "https://graph.microsoft.com/v1.0/users?`$select=displayName,jobTitle,department,officeLocation,mail,accountEnabled&`$top=100"
do {
    $Result = Invoke-RestMethod -Uri $Uri -Headers $MSHeaders
    $AllMSUsers += $Result.value
    $Uri = $Result.'@odata.nextLink'
} while ($Uri)
Write-Output "Microsoft users pulled: $($AllMSUsers.Count)"

# Build Microsoft email lookup
$MSEmailSet = @{}
foreach ($User in $AllMSUsers) {
    if ($User.mail -and $User.accountEnabled) {
        $MSEmailSet[$User.mail.ToLower()] = $User
    }
}

$Notified = @()
$Skipped = 0

foreach ($Worker in $NewHires) {
    $WorkEmail = $Worker.businessCommunication.emails | Where-Object { $_.emailUri -like "*@contoso.com" } | Select-Object -First 1 -ExpandProperty emailUri
    $ADPName = $Worker.person.legalName.formattedName

    if ($null -eq $WorkEmail -or $WorkEmail -eq "") { $Skipped++; continue }

    $MSUser = $MSEmailSet[$WorkEmail.ToLower()]
    if ($null -eq $MSUser) { $Skipped++; continue }

    $ActiveAssignment = $Worker.workAssignments | Where-Object { $_.assignmentStatus.statusCode.codeValue -eq "A" } | Select-Object -First 1
    $JobTitle = $ActiveAssignment.jobTitle
    $HireDate = $ActiveAssignment.hireDate
    $BURaw = $ActiveAssignment.homeOrganizationalUnits | Where-Object { $_.typeCode.codeValue -eq "Business Unit" } | Select-Object -First 1
    $BUName = if ($BURaw.nameCode.shortName -and $BURaw.nameCode.shortName -ne "Business Unit") { $BURaw.nameCode.shortName } elseif ($BURaw.nameCode.longName) { $BURaw.nameCode.longName } else { "N/A" }
    $ManagerName = ($ActiveAssignment.reportsTo | Select-Object -First 1).reportsToWorkerName.formattedName
    if (-not $ManagerName) { $ManagerName = "N/A" }

    # Add Contoso prefix if missing
    if ($BUName -and $BUName -ne "N/A" -and -not $BUName.StartsWith("Contoso")) {
        $BUName = "Contoso $BUName"
    }

    Write-Output " NOTIFYING: $ADPName ($WorkEmail) — Title: $JobTitle — Manager: $ManagerName"

    $Notified += [PSCustomObject]@{
        Name = $ADPName
        Email = $WorkEmail
        Title = $JobTitle
        HireDate = $HireDate
        BusinessUnit = $BUName
        Manager = $ManagerName
    }
}

Write-Output "============================================"
Write-Output " NEW HIRE CHECK COMPLETE"
Write-Output " New hires detected: $($NewHires.Count)"
Write-Output " Will notify: $($Notified.Count)"
Write-Output " Skipped: $Skipped"
Write-Output "============================================"

if ($Notified.Count -gt 0 -and $LiveMode) {

    $HireRows = $Notified | ForEach-Object {
        $NameEncoded = [Uri]::EscapeDataString($_.Name)
        $EmailEncoded = [Uri]::EscapeDataString($_.Email)
        $ExpenseInviteEntityAEnc = [Uri]::EscapeDataString($ExpenseInviteEntityA)
        $ExpenseInviteEntityBEnc = [Uri]::EscapeDataString($ExpenseInviteEntityB)
        $ExpenseInviteEntityCEnc = [Uri]::EscapeDataString($ExpenseInviteEntityC)

        $ButtonEntityA = "$LogicAppURL&email=$EmailEncoded&name=$NameEncoded&entity=Entity+A&invite_link=$ExpenseInviteEntityAEnc"
        $ButtonEntityB = "$LogicAppURL&email=$EmailEncoded&name=$NameEncoded&entity=Entity+B&invite_link=$ExpenseInviteEntityBEnc"
        $ButtonEntityC = "$LogicAppURL&email=$EmailEncoded&name=$NameEncoded&entity=Entity+C&invite_link=$ExpenseInviteEntityCEnc"

        "
<tr>
<td colspan='2' style='background:#1a5276;color:white;padding:8px'><strong>$($_.Name)</strong> — $($_.Email)</td>
</tr>
<tr><td><strong>Job Title</strong></td><td>$($_.Title)</td></tr>
<tr><td><strong>Hire Date</strong></td><td>$($_.HireDate)</td></tr>
<tr><td><strong>Business Unit</strong></td><td>$($_.BusinessUnit)</td></tr>
<tr><td><strong>Manager</strong></td><td>$($_.Manager)</td></tr>
<tr><td><strong>Expense App Invite</strong></td><td>
<a href='$ButtonEntityA' style='background:#2ecc71;color:white;padding:6px 14px;text-decoration:none;border-radius:4px;font-weight:bold;margin-right:6px'>Entity A</a>
<a href='$ButtonEntityB' style='background:#2980b9;color:white;padding:6px 14px;text-decoration:none;border-radius:4px;font-weight:bold;margin-right:6px'>Entity B</a>
<a href='$ButtonEntityC' style='background:#8e44ad;color:white;padding:6px 14px;text-decoration:none;border-radius:4px;font-weight:bold'>Entity C</a>
</td></tr>
<tr><td colspan='2'>&nbsp;</td></tr>"
    }

    $AccountingBody = "
<h2>New Hire Expense App Invites — Week of $(Get-Date -Format 'MMM dd, yyyy')</h2>
<p>The following new hire(s) have been added to Microsoft 365 this week. Please click the correct the expense app button for each employee to send their invite.</p>
<p style='background:#fff3cd;padding:8px;border-left:4px solid #ffc107;'><strong>Important:</strong> Each button sends a expense app invite directly to the employee. Please click once only and verify in your Sent Items to confirm it was delivered before clicking again.</p>
<hr>
<table border='1' cellpadding='8' style='border-collapse:collapse;width:100%'>
$($HireRows -join '')
</table>
<br>
<p style='color:#888;font-size:12px'>This email was generated automatically by the Contoso ADP Sync system.</p>"

    $AccountingMessage = @{
        message = @{
            subject = "New Hire Alert — $($Notified.Count) employee(s) — $(Get-Date -Format 'yyyy-MM-dd')"
            body = @{ contentType = "HTML"; content = $AccountingBody }
            toRecipients = @(@{ emailAddress = @{ address = $AccountingEmail } })
        }
    } | ConvertTo-Json -Depth 10

    try {
        Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$FromEmail/sendMail" -Method POST -Headers $MSHeaders -Body $AccountingMessage -ContentType "application/json"
        Write-Output "Notification sent to $AccountingEmail — $($Notified.Count) new hire(s)"
    } catch {
        Write-Output "Failed to send notification: $_"
    }

} elseif ($Notified.Count -gt 0 -and -not $LiveMode) {
    Write-Output "REPORT ONLY — would have notified about:"
    $Notified | ForEach-Object {
        Write-Output " $($_.Name) | $($_.Email) | $($_.Title) | Manager: $($_.Manager) | $($_.BusinessUnit) | Hired: $($_.HireDate)"
    }
} else {
    Write-Output "No new hires detected this run."
}
