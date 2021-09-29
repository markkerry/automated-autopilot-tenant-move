using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

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
# GET needs to be Query.Name. POST needs to be Body.Name
if ($Request.Method -eq "GET") {
    $csv = $Request.Query.Name
}
elseif ($Request.Method -eq "POST") {
    $csv = $Request.Body.Name
}

if ([string]::IsNullOrEmpty($csv)) {
    # Fail with invalid $deviceName in request
    Write-Host "No name in the request body"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body = "No name in the request body"
    })
    exit
}

Write-Host "Received $csv from request body"
Write-Host "Downloading $csv"

$blobUri = "http://.../$($csv)"
$sas = $env:STORAGE_SAS
$uri = $blobUri+$sas
$outputPath = "$($env:temp)\$csv"
try {
    Invoke-Webrequest -Uri $uri -OutFile $outputPath -ErrorAction Stop
    Write-Host "Downloaded $csv"
}
catch {
    Write-Host "failed to download $csv"
}

if (!(Test-Path -Path $outputPath)) {
    Write-Host "$csv does not exist in $($env:temp)"
}

$info = Import-Csv -Path $outputPath
$serialNumber = $info.'Device Serial Number' 
$hardwareIdentifier = $info.'Hardware Hash'

Write-Host "Authenticating with MS Graph and Azure AD"

# authentication
$params = @{
    TenantId     = $env:TENANT_ID
    ClientId     = $env:CLIENT_ID
    ClientSecret = $env:CLIENT_SECRET
    ResourceUrl  = "https://graph.microsoft.com"
}
$script:authHeader = Get-AuthHeader @params

Write-Host "Registering device with tenant"

# Post device to importedWindowsAutopilotDeviceIdentity
    $body = @"
{
    "@odata.type": "#microsoft.graph.importedWindowsAutopilotDeviceIdentity",
    "orderIdentifier": "",
    "serialNumber": "$serialNumber",
    "productKey": "",
    "hardwareIdentifier": "$hardwareIdentifier",
    "state": {
        "@odata.type": "microsoft.graph.importedWindowsAutopilotDeviceIdentityState",
        "deviceImportStatus": "pending",
        "deviceRegistrationId": "",
        "deviceErrorCode": 0,
        "deviceErrorName": ""
    }
}
"@
$graphUri = "https://graph.microsoft.com/beta/deviceManagement/importedWindowsAutopilotDeviceIdentities"
$query = Invoke-GraphCall -Uri $graphUri -Method Post -Body $body

try {
    Invoke-RestMethod -Uri $graphUri -Headers $script:authHeader -Method Post -Body $body -ContentType "application/json"
}
catch {
    $ex = $_.Exception
    $errorResponse = $ex.Response.GetResponseStream()
    $reader = New-Object System.IO.StreamReader($errorResponse)
    $reader.BaseStream.Position = 0
    $reader.DiscardBufferedData()
    $responseBody = $reader.ReadToEnd();

    Write-Host "Response content:`n$responseBody"
    Write-Error "Request to $Uri failed with HTTP Status $($ex.Response.StatusCode) $($ex.Response.StatusDescription)"
}

# Sync the Autopilot service
Write-Host "Synchronising the Autopilot registration service"
$graphUri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotSettings/sync"
$query = Invoke-GraphCall -Uri $graphUri -Method Post

Write-Host "Deleting $($env:temp)\$csv"
Remove-Item "$($env:temp)\$csv"

$body = "Success"

# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body = $body
})