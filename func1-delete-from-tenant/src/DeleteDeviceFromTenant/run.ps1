using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

# functions
function Get-AuthHeader {
    param (
        [Parameter(mandatory = $true)]
        [string]$TenantId,
        [Parameter(mandatory = $true)]
        [string]$ClientId,
        [Parameter(mandatory = $true)]
        [string]$ClientSecret,
        [Parameter(mandatory = $true)]
        [string]$ResourceUrl
    )
    $body = @{
        resource      = $ResourceUrl
        client_id     = $ClientId
        client_secret = $ClientSecret
        grant_type    = "client_credentials"
        scope         = "openid"
    }
    try {
        $response = Invoke-RestMethod -Method post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/token" -Body $body -ErrorAction Stop
        $headers = @{ "Authorization" = "Bearer $($response.access_token)" }
        return $headers
    }
    catch {
        Write-Error $_.Exception
        # exit
    }
}

function Invoke-GraphCall {
    [cmdletbinding()]
    param (
        [parameter(Mandatory = $false)]
        [ValidateSet('Get', 'Post', 'Delete')]
        [string]$Method = 'Get',

        [parameter(Mandatory = $false)]
        [hashtable]$Headers = $script:authHeader,

        [parameter(Mandatory = $true)]
        [string]$Uri,

        [parameter(Mandatory = $false)]
        [string]$ContentType = 'Application/Json',

        [parameter(Mandatory = $false)]
        [hashtable]$Body
    )
    try {
        $params = @{
            Method      = $Method
            Headers     = $Headers
            Uri         = $Uri
            ContentType = $ContentType
        }
        if ($Body) {
            $params.Body = $Body | ConvertTo-Json -Depth 20
        }
        $query = Invoke-RestMethod @params
        return $query
    }
    catch {
        Write-Warning $_.Exception.Message
        # exit
    }
}

# Write to the Azure Functions log stream.
Write-Host "PowerShell HTTP trigger function processed a request."

# Interact with query parameters or the body of the request.
# GET is Query.Name. POST is Body.Name
if ($Request.Method -eq "GET") {
    $deviceName = $Request.Query.Name
}
elseif ($Request.Method -eq "POST") {
    $deviceName = $Request.Body.Name
}

if ([string]::IsNullOrEmpty($deviceName)) {
    # Fail with invalid $deviceName in request
    # Return bad request status code
    Write-Host "No name in the request body"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body = "No name in the request body"
    })
    exit
}

Write-Host "Received device $deviceName from request body"
Write-Host "Authenticating with MS Graph and Azure AD"

# authentication
$params = @{
    TenantId     = $env:TENANT_ID
    ClientId     = $env:CLIENT_ID
    ClientSecret = $env:CLIENT_SECRET
    ResourceUrl  = "https://graph.microsoft.com"
}
$script:authHeader = Get-AuthHeader @params

Write-Host "Retrieving Intune managed device record/s..."

$graphUri = "https://graph.microsoft.com/Beta/deviceManagement/managedDevices?`$filter=deviceName eq '$($deviceName)'"
$query = Invoke-GraphCall -Uri $graphUri

# Delete each intune managed device.
if ($query.'@odata.count' -ne 0) {
    if ($query.'@odata.count' -eq 1) {
        foreach ($device in $query.value) {
            Write-Host "  Deleting Intune Managed Device..."
            Write-Host "    Device Name: $($device.deviceName)"
            Write-Host "    Intune Device ID: $($device.Id)"
            Write-Host "    Azure Device ID: $($device.azureADDeviceId)"
            Write-Host "    Serial Number: $($device.serialNumber)"
        
            $graphUri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($device.Id)"
            Invoke-GraphCall -Uri $graphUri -Method Delete
            Start-Sleep -Seconds 10
        }
    }
    else {
        Write-Host "Too many device discovered with the same name"
    }
}

# Delete Autopilot device
Write-Host "Retrieving Autopilot device registration..."

# delete Autopilot registered device
$graphUri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$($device.serialNumber)')"
$query = Invoke-GraphCall -Uri $graphUri

if ($query.'@odata.count' -eq 1) {
    Write-Host "  Deleting Autopilot Registration..."
    Write-Host "    SerialNumber: $($query.value.serialNumber)"
    Write-Host "    Model: $($query.value.model)"
    Write-Host "    Id: $($query.value.id)"
    Write-Host "    ManagedDeviceId: $($query.value.managedDeviceId)"

    $graphUri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities/$($query.value.Id)"
    Invoke-GraphCall -Uri $graphUri -Method Delete
    Start-Sleep -Seconds 5

    # Sync the Autopilot service
    Write-Host "Synchronising the Autopilot registration service"
    $graphUri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotSettings/sync"
    $query = Invoke-GraphCall -Uri $graphUri -Method Post

    Start-Sleep -Seconds 5

    $csv = "$($query.value.serialNumber).csv"
}
else {
    Write-Host "Device with serial number $($device.serialNumber) not found as being registered in tenant"
    $csv = "$($device.serialNumber).csv"
}

Write-Host "Passing serial number csv to next func: $csv"

$body = @{
    Name = $csv
}

$uri = ""

$params = @{
    Method = "POST"
    Body = ($body | ConvertTo-Json)
    Uri = $uri
    ContentType = "application/json"
    ErrorAction = "Stop"
}

try {
    $invokeFunc = Invoke-RestMethod @params
}
catch {
    Write-Warning $_.Exception.Message
    # exit
}

if (!($invokeFunc -eq "Success")) {
    Write-host "Func 2 Failed"
}
else {
    Write-host "Func 2 Success"
}

# Return success status code
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body = "Success"
})