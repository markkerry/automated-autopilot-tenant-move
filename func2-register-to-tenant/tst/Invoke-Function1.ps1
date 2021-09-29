$serialNumber = (Get-CimInstance Win32_BIOS).SerialNumber

$body = @{
    Name = "$serialNumber"
}

$uri = ""

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