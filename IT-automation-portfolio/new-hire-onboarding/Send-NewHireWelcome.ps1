# ============================================
# CONTOSO - NEW HIRE ACCESS CHECKLIST
# Version: 3.3
# ============================================

$LiveMode = $true
$TestMode = $true
$TestEmail = "it-admin@contoso.com"
$FromEmail = "it-automation@contoso.com"
$ITEmail = "it-support@contoso.com"
$LookbackDays = 4
$PDFUrl = Get-AutomationVariable -Name "NewHireGuide-PDF-URL"

function Get-StateFromOfficeLocation { param($OfficeLocation)
    if (-not $OfficeLocation) { return "Unknown" }
    $States = @("New York", "Texas", "California", "Florida")
    foreach ($State in $States) {
        if ($OfficeLocation -like "*$State*") { return $State }
    }
    return "Unknown"
}

function Get-EmailAddress { param($Address)
    if ($TestMode) { return $TestEmail }
    return $Address
}

$MSCreds = Get-AutomationPSCredential -Name "Graph-App-Credential"
$TenantId = Get-AutomationVariable -Name "Tenant-ID"
$ClientId = $MSCreds.UserName
$ClientSecret = $MSCreds.GetNetworkCredential().Password

Write-Output "============================================"
Write-Output " CONTOSO - NEW HIRE ACCESS CHECKLIST"
Write-Output " Mode: $(if ($LiveMode) { 'LIVE' } else { 'REPORT ONLY' }) | Test: $TestMode"
Write-Output " Lookback: $LookbackDays days"
Write-Output " Run time: $(Get-Date)"
Write-Output "============================================"

# Load PDF
Write-Output "Loading IT Guide PDF..."
$PDFBase64 = ""
try {
    $PDFBytes = (Invoke-WebRequest -Uri $PDFUrl -UseBasicParsing).Content
    $PDFBase64 = [Convert]::ToBase64String($PDFBytes)
    Write-Output "PDF loaded — $([Math]::Round($PDFBytes.Length/1KB, 1)) KB"
} catch {
    Write-Output "PDF load failed — emails will send without attachment: $_"
}

# Connect to Microsoft
Write-Output "Connecting to Microsoft..."
$MSBody = @{ Grant_Type = "client_credentials"; Scope = "https://graph.microsoft.com/.default"; Client_Id = $ClientId; Client_Secret = $ClientSecret }
$MSToken = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Method POST -Body $MSBody
$MSHeaders = @{ Authorization = "Bearer $($MSToken.access_token)" }

# Pull new Microsoft accounts
$CutoffDate = (Get-Date).AddDays(-$LookbackDays)
$AllMSUsers = @()
$Uri = "https://graph.microsoft.com/v1.0/users?`$select=displayName,jobTitle,department,officeLocation,mail,accountEnabled,usageLocation,createdDateTime&`$top=100"
do {
    $Result = Invoke-RestMethod -Uri $Uri -Headers $MSHeaders
    $AllMSUsers += $Result.value
    $Uri = $Result.'@odata.nextLink'
} while ($Uri)

$NewHires = $AllMSUsers | Where-Object {
    $_.accountEnabled -eq $true -and
    $_.usageLocation -eq "US" -and
    $_.mail -like "*@contoso.com" -and
    $_.jobTitle -and
    $_.createdDateTime -and
    [DateTime]::Parse($_.createdDateTime) -ge $CutoffDate -and
    $_.mail -notmatch "admin|automation|noreply|shared|test"
}
Write-Output "New hires in last $LookbackDays days: $($NewHires.Count)"

$Notified = @()

foreach ($MSUser in $NewHires) {
    $ManagerEmail = ""
    $ManagerName = "Not set — please update in Admin Center"
    try {
        $Manager = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$($MSUser.mail)/manager" -Headers $MSHeaders
        $ManagerEmail = $Manager.mail
        $ManagerName = $Manager.displayName
    } catch {}

    $State = Get-StateFromOfficeLocation $MSUser.officeLocation

    Write-Output " NEW HIRE: $($MSUser.displayName) | $($MSUser.jobTitle) | $State | Manager: $ManagerName"

    $Notified += [PSCustomObject]@{
        Name = $MSUser.displayName
        Email = $MSUser.mail
        Title = $MSUser.jobTitle
        Department = $MSUser.department
        State = $State
        ManagerName = $ManagerName
        ManagerEmail = $ManagerEmail
    }
}

Write-Output "============================================"
Write-Output " FOUND: $($Notified.Count) new hire(s)"
Write-Output "============================================"

if ($Notified.Count -eq 0 -or -not $LiveMode) {
    if ($Notified.Count -gt 0) {
        Write-Output "REPORT ONLY — would have notified:"
        $Notified | ForEach-Object { Write-Output " $($_.Name) | $($_.Title) | $($_.State)" }
    } else {
        Write-Output "No new hires detected this run."
    }
    exit
}

$ITRows = ""
$ManagerMap = @{}

foreach ($Hire in $Notified) {

    $ITRows += "
<tr><td colspan='2' style='background:#1a1a1a;color:white;padding:8px'><strong>$($Hire.Name)</strong> — $($Hire.Email)</td></tr>
<tr><td><strong>Title</strong></td><td>$($Hire.Title)</td></tr>
<tr><td><strong>Department</strong></td><td>$($Hire.Department)</td></tr>
<tr><td><strong>State</strong></td><td>$($Hire.State)</td></tr>
<tr><td><strong>Manager</strong></td><td>$($Hire.ManagerName)</td></tr>
<tr><td colspan='2' style='padding:4px'>&nbsp;</td></tr>"

    if ($Hire.ManagerEmail) {
        if (-not $ManagerMap.ContainsKey($Hire.ManagerEmail)) {
            $ManagerMap[$Hire.ManagerEmail] = @{ Name = $Hire.ManagerName; Hires = @() }
        }
        $ManagerMap[$Hire.ManagerEmail].Hires += $Hire
    }

    # Welcome email to new hire
    $FirstName = ($Hire.Name.Split(',') | Select-Object -Last 1).Trim()
    $WelcomeBody = "
<h2>Welcome to Contoso, $FirstName!</h2>
<p>Your Microsoft 365 account is ready. Attached is your IT Getting Started Guide covering everything you need for day one.</p>
<p>If you need any help contact us at <a href='mailto:it-support@contoso.com'>it-support@contoso.com</a> or find us on Microsoft Teams.</p>
<p>Welcome aboard!</p>
<p><strong>Contoso IT Team</strong></p>"

    $WelcomeMsg = @{
        message = @{
            subject = "Welcome to Contoso — Your IT Getting Started Guide"
            body = @{ contentType = "HTML"; content = $WelcomeBody }
            toRecipients = @(@{ emailAddress = @{ address = (Get-EmailAddress $Hire.Email) } })
        }
    }

    if ($PDFBase64) {
        $WelcomeMsg.message.attachments = @(@{
            "@odata.type" = "#microsoft.graph.fileAttachment"
            name = "Contoso New Hire Guide.pdf"
            contentType = "application/pdf"
            contentBytes = $PDFBase64
        })
    }

    try {
        Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$FromEmail/sendMail" -Method POST -Headers $MSHeaders -Body ($WelcomeMsg | ConvertTo-Json -Depth 10) -ContentType "application/json"
        Write-Output " Welcome email sent to $($Hire.Email)"
    } catch {
        Write-Output " Failed to send welcome email: $_"
    }
}

# IT Support digest
$ITHTML = "
<h2>New Hire IT Setup — Week of $(Get-Date -Format 'MMM dd, yyyy')</h2>
<p>$($Notified.Count) new hire(s) this week. Manager confirmation of access required before provisioning.</p>
<hr>
<table border='1' cellpadding='8' style='border-collapse:collapse;width:100%'>
$ITRows
</table>"

$ITMsg = @{
    message = @{
        subject = "New Hire IT Setup — Week of $(Get-Date -Format 'MMM dd, yyyy') — $($Notified.Count) employee(s)"
        body = @{ contentType = "HTML"; content = $ITHTML }
        toRecipients = @(@{ emailAddress = @{ address = (Get-EmailAddress $ITEmail) } })
    }
} | ConvertTo-Json -Depth 10

try {
    Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$FromEmail/sendMail" -Method POST -Headers $MSHeaders -Body $ITMsg -ContentType "application/json"
    Write-Output "IT Support email sent"
} catch { Write-Output "Failed to send IT email: $_" }

# Manager emails
foreach ($ManagerEmail in $ManagerMap.Keys) {
    $ManagerData = $ManagerMap[$ManagerEmail]
    $ManagerHires = $ManagerData.Hires

    $HireRows = ($ManagerHires | ForEach-Object {
        "
<tr><td colspan='2' style='background:#1a1a1a;color:white;padding:8px'><strong>$($_.Name)</strong> — $($_.Email)</td></tr>
<tr><td><strong>Title</strong></td><td>$($_.Title)</td></tr>
<tr><td><strong>State</strong></td><td>$($_.State)</td></tr>
<tr><td colspan='2' style='padding:8px'><p>Please reply to this email with the access and tools $($_.Name.Split(',')[1].Trim()) will need so we can match it against our records and get everything set up before their start date.</p></td></tr>
<tr><td colspan='2' style='padding:4px'>&nbsp;</td></tr>"
    }) -join ""

    $ManagerHTML = "
<h2>New Team Member(s) Starting This Week</h2>
<p>Hi $($ManagerData.Name),</p>
<p>The following new team member(s) have been added to Microsoft 365 this week.</p>
<hr>
<table border='1' cellpadding='8' style='border-collapse:collapse;width:100%'>
$HireRows
</table>
<p><strong>Contoso IT Team</strong></p>"

    $ManagerMsg = @{
        message = @{
            subject = "New Team Member(s) This Week — $($ManagerData.Name)"
            body = @{ contentType = "HTML"; content = $ManagerHTML }
            toRecipients = @(@{ emailAddress = @{ address = (Get-EmailAddress $ManagerEmail) } })
            replyTo = @(@{ emailAddress = @{ address = $ITEmail } })
        }
    } | ConvertTo-Json -Depth 10

    try {
        Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$FromEmail/sendMail" -Method POST -Headers $MSHeaders -Body $ManagerMsg -ContentType "application/json"
        Write-Output "Manager email sent to $ManagerEmail"
    } catch { Write-Output "Failed to send manager email: $_" }
}
