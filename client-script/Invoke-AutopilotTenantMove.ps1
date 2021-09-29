<#
.Synopsis
    Gathers and sends the machines Autopilot hardware ID to an Azure Storage account.
.DESCRIPTION
    This uses a stripped down version of the Get-WindowsAutopilotInfo.ps1 script as a function Get-AutopilotHash.
    It saves it as a csv in C:\Windows\Temp and send to a storage account using azcopy.exe. Then after confirmation
    the Azure Functions were successful, a device wipe will happen.
.EXAMPLE
    .\Invoke-AutopilotTenantMove.ps1
.NOTES
#>

# Ensure the log destination exists
if (!(Test-Path -Path "C:\Users\Public\Documents\IntuneDetectionLogs")) {
    New-Item -Path "C:\Users\Public\Documents" -Name "IntuneDetectionLogs" -ItemType Directory | Out-Null
}

# Create the Write-LogEntry function
function Write-LogEntry {
    param(
        [parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$Value,

        [parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]$FileName = "AutopilotTenantMove.log"
    )
    # Determine log file location
    $LogFilePath = Join-Path -Path "C:\Users\Public\Documents" -ChildPath "IntuneDetectionLogs\$($FileName)"

    # Add value to log file
    try {
        Out-File -InputObject $Value -Append -NoClobber -Encoding Default -FilePath $LogFilePath -ErrorAction Stop
    }
    catch [System.Exception] {
        Write-Warning -Message "Unable to append log entry to $FileName file"
        exit 1
    }
}

# Create the function to gather the hardware hash
function Get-AutopilotHash {
	param(
		[Parameter(Mandatory=$False)] [String] $OutputFile = "", 
		[Parameter(Mandatory=$False)] [String] $GroupTag = ""
	)

	# Get the common properties.
	$serial = (Get-CimInstance -Class Win32_BIOS).SerialNumber

	# Get the hash (if available)
	$devDetail = (Get-CimInstance -Namespace root/cimv2/mdm/dmmap -Class MDM_DevDetail_Ext01 -Filter "InstanceID='Ext' AND ParentID='./DevDetail'")
	if (!($devDetail)) {
		"Failed to gather hardware hash"
	}
    else {
        $hash = $devDetail.DeviceHardwareData
    }

	# Getting the PKID is generally problematic for anyone other than OEMs, so let's skip it here
	$product = ""
	$c = New-Object psobject -Property @{
		"Device Serial Number" = $serial
		"Windows Product ID" = $product
		"Hardware Hash" = $hash
	}
	
	if ($GroupTag -ne "") {
		Add-Member -InputObject $c -NotePropertyName "Group Tag" -NotePropertyValue $GroupTag
	}

	# Write the object to the pipeline or array
	if ($OutputFile -eq "") {
		$c
	}
	else {
		$computers += $c
		Write-Host "Gathered details for device with serial number: $serial"
	}

	if ($OutputFile -ne "") {
		if ($GroupTag -ne "") {
			$computers | Select-Object "Device Serial Number", "Windows Product ID", "Hardware Hash", "Group Tag" | ConvertTo-CSV -NoTypeInformation | ForEach-Object {$_ -replace '"',''} | Out-File $OutputFile
		}
		else {
			$computers | Select-Object "Device Serial Number", "Windows Product ID", "Hardware Hash" | ConvertTo-CSV -NoTypeInformation | ForEach-Object {$_ -replace '"',''} | Out-File $OutputFile
		}
	}
}

# Function to silently reset Windows
function Reset-OperatingSystem {
    $namespaceName = "root\cimv2\mdm\dmmap"
    $className = "MDM_RemoteWipe"
    $methodName = "doWipeMethod"

    $session = New-CimSession

    $params = New-Object Microsoft.Management.Infrastructure.CimMethodParametersCollection
    $param = [Microsoft.Management.Infrastructure.CimMethodParameter]::Create("param", "", "String", "In")
    $params.Add($param)

    try {
        $instance = Get-CimInstance -Namespace $namespaceName -ClassName $className -Filter "ParentID='./Vendor/MSFT' and InstanceID='RemoteWipe'"
        $session.InvokeMethod($namespaceName, $instance, $methodName, $params)
    }
    catch [Exception] {
        write-host $_ | out-string
        exit 1
    }
}

# Function to capture output from azcopy.exe
Function Start-Command {
    Param(
        [Parameter (Mandatory=$true)]
        [string]$Command,
        [Parameter (Mandatory=$false)]
        [string]$Arguments,
        [Parameter (Mandatory=$false)]
        [switch]$Wait = $false
    )

    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = $Command
    $pinfo.RedirectStandardError = $true
    $pinfo.RedirectStandardOutput = $true
    $pinfo.CreateNoWindow = $true
    $pinfo.UseShellExecute = $false
    $pinfo.Arguments = $Arguments
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $pinfo
    $p.Start() | Out-Null
    if ($Wait) {
        $p.WaitForExit()
    }
    [pscustomobject]@{
        stdout = $p.StandardOutput.ReadToEnd()
        stderr = $p.StandardError.ReadToEnd()
        ExitCode = $p.ExitCode
    }
}

# if azcopy.exe not found exit the script
if (!(Test-Path -Path "$PSScriptRoot\azcopy.exe")) {
    Write-LogEntry -Value "$(Get-Date -format g): azcopy.exe not found in script root"
    exit 1
}

Write-LogEntry -Value "$(Get-Date -format g): azcopy.exe found in script root"

# Get the device's serial number to upload as the .csv name
$sn = Get-CimInstance Win32_BIOS | Select-Object SerialNumber -ExpandProperty SerialNumber
$fileName = "$sn.csv"
$outputPath = Join-Path $env:windir "temp"
$outputFile = Join-Path $outputPath $fileName

Write-LogEntry -Value "$(Get-Date -format g): Gathering HWID for $env:computername with serial number $sn"

Get-AutopilotHash -OutputFile $outputFile

if (!(Test-Path -Path $outputFile)) {
    Write-LogEntry -Value "$(Get-Date -format g): Failed to create $outputFile"
    exit 1
}
else {
    Write-LogEntry -Value "$(Get-Date -format g): Successfully created $outputFile"
}

Write-LogEntry -Value "$(Get-Date -format g): Attempting to send $fileName to Azure Storage using azcopy.exe"

$blobUri = ''

$result = Start-Command -Command "`"$PSScriptRoot\azcopy.exe`"" -Arguments "cp $outputFile $blobUri" -Wait
if ($result.stdout.Contains("Number of Transfers Completed: 1")) {
    Write-LogEntry -Value "$(Get-Date -format g): Number of Transfers Completed: 1"
    Write-LogEntry -Value "$(Get-Date -format g): Deleting $outputFile"
    Remove-Item $outputFile -Force
}
else {
    Write-LogEntry -Value "$(Get-Date -format g): Failed to send to Azure Storage using azcopy.exe"
    Write-LogEntry -Value "$(Get-Date -format g): $($result.stdout)"
    Write-LogEntry -Value "$(Get-Date -format g): $($result.stderr)"
    exit 1
}

Write-LogEntry -Value "$(Get-Date -format g): Sending $($env:computername) to Azure Function 1"

# Invoke Azure Function.
$body = @{
    Name = "$env:COMPUTERNAME"
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
else {
    Write-host "Sucess"
}

Reset-OperatingSystem