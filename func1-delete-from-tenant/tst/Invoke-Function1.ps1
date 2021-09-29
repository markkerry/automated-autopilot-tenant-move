$body = @{
    Name = "$env:COMPUTERNAME"
}

$uri = "http://localhost:7071/api/DeleteDeviceFromTenant"

$parameters = @{
    Method = "POST"
    Body = ($body | ConvertTo-Json)
    Uri = $uri
    ContentType = "application/json"
}

$invokeFunc = Invoke-RestMethod @parameters

if (!($invokeFunc -eq "Success")) {
    Write-host "Failed"
}


## FAIL

$parameters2 = @{
    Method = "GET"
    Uri = $uri
}

$invokeFunc2 = Invoke-RestMethod @parameters2


if (!($invokeFunc2 -eq "Success")) {
    Write-host "Failed"
}