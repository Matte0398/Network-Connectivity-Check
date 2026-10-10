########################################################################################
## Description: Script to test TCP/UDP connectivity from Windows to Windows or Linux
##
## Author: Matteo Z.
########################################################################################

param (
    [Alias('T','port_type')] [ValidateSet('TCP','UDP')] [string]$Protocol,
    [Alias('L','ports_local_to_remote')] [object[]]$LocalToRemotePorts,
    [Alias('R','ports_remote_to_local')] [object[]]$RemoteToLocalPorts,
    [ValidateSet('Auto','Windows','Linux')] [string]$RemoteOS = 'Auto',
    [ValidateRange(100,60000)] [int]$Timeout = 1000,
    [string]$WorkDirectory = 'C:\temp',
    [string]$SystemListPath,
    [PSCredential]$Credential,
    [switch]$SaveCredential,
    [switch]$TrustSshHostKey,
    [switch]$UdpArrivalCheck,
    [switch]$CaptureSudo
)

if ($UdpArrivalCheck -and ($Protocol -ne 'UDP' -or $RemoteToLocalPorts.Count -gt 0)) {
    throw '-UdpArrivalCheck requires -T UDP and supports local-to-remote (-L) tests only.'
}

if ($CaptureSudo -and -not $UdpArrivalCheck) {
    throw '-CaptureSudo requires -UdpArrivalCheck.'
}


function Show-Usage {
    Write-Host @"

INFRASTRUCTURE CONNECTIVITY CHECK

Usage:
  .\$ScriptName -T <TCP|UDP> -L <ports> [options]

Ports:
  -T <TCP|UDP>            Protocol to test.
  -L <ports>              Local-to-remote ports (required), e.g. 80,443
  -R <ports>              Remote-to-local ports (optional).

Options:
  -SystemListPath <path>  File with one "hostname,ip" per line.
                          Default: <WorkDirectory>\system.txt
  -WorkDirectory <path>   Folder for system.txt and saved credentials. Default: C:\temp
  -RemoteOS <OS>          Auto, Windows or Linux. Default: Auto
  -Timeout <ms>           100 to 60000. Default: 1000
  -Credential <value>     One credential for all systems, e.g. (Get-Credential)
  -SaveCredential         Save and reuse one credential file per system.
  -TrustSshHostKey        Accept unknown SSH host keys (trusted hosts only).

UDP capture (needs Posh-SSH here, and tcpdump + timeout on the Linux target):
  -UdpArrivalCheck        Run tcpdump on the target to see if the UDP probe arrives.
                          Works with -T UDP and -L only.
  -CaptureSudo            Run tcpdump with "sudo -n" (no password prompt).

UDP capture results:
  ReplyObserved           The target sent a UDP reply back.
  PortRefused             The target sent ICMP "port unreachable".
  ArrivalOnly             The probe arrived, but the port state is unknown.
  NotObserved             The probe was not seen on the target.
  Error                   Capture failed; see the diagnostic log.

Examples:
  .\$ScriptName -T TCP -L 80,443
  .\$ScriptName -T TCP -L 5985 -R 8080 -RemoteOS Windows
  .\$ScriptName -T UDP -L 161,514 -UdpArrivalCheck

System list:    $SystemFile
Diagnostic log: $LogFile
Results CSV:    $ResultsFile
"@
}


function Write-RunLog {
    param (
        [ValidateSet('INFO','WARN','ERROR')] [string]$Level = 'INFO',
        [string]$Message
    )

    $context = if ($RemoteLabel) { $RemoteLabel } else { $LocalHostname }
    $text = $Message -replace '[\r\n]+', ' '
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] [$context] $text" |
        Add-Content -LiteralPath $LogFile -Encoding UTF8 -ErrorAction Stop
}


# Append one row to the results CSV. For reverse tests source and destination are swapped
function Add-TestResult {
    param (
        [ValidateSet('LocalToRemote','RemoteToLocal')] [string]$Direction,
        [ValidateSet('Port','Ping')] [string]$Test = 'Port',
        [Nullable[int]]$Port,
        [string]$Status,
        [string]$Details
    )

    $reverse = $Direction -eq 'RemoteToLocal'
    [pscustomobject]@{
        Timestamp           = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Direction           = $Direction
        SourceHostname      = if ($reverse) { $RemoteHostname } else { $LocalHostname }
        SourceIP            = if ($reverse) { $RemoteAddress } else { $LocalAddress }
        DestinationHostname = if ($reverse) { $LocalHostname } else { $RemoteHostname }
        DestinationIP       = if ($reverse) { $LocalAddress } else { $RemoteAddress }
        Test                = $Test
        Protocol            = if ($Test -eq 'Ping') { 'ICMP' } else { $Protocol }
        Port                = $Port
        Status              = $Status
        Details             = $Details
    } | Export-Csv -LiteralPath $ResultsFile -Delimiter ';' -NoTypeInformation -Encoding UTF8 -Append -ErrorAction Stop
}


# Record that every reverse test was skipped, with the reason
function Add-SkippedReverseResults {
    param ([string]$Reason)

    Write-RunLog -Level WARN -Message "Reverse tests skipped: $Reason"
    foreach ($port in $ValidReversePorts) {
        Add-TestResult -Direction RemoteToLocal -Port $port -Status Skipped -Details $Reason
    }
}


# Test one port. TCP succeeds if the connection opens; UDP succeeds only if a reply arrives
# This function is also sent to remote Windows computers, so it must not use outside variables
function Test-Port {
    param (
        [string]$ComputerName,
        [int]$Port,
        [string]$Protocol,
        [int]$Timeout
    )

    $client = $null
    $pending = $null

    try {
        if ($Protocol -eq 'TCP') {
            $client = New-Object System.Net.Sockets.TcpClient
            $pending = $client.BeginConnect($ComputerName, $Port, $null, $null)

            if (-not $pending.AsyncWaitHandle.WaitOne($Timeout, $false)) {
                return [pscustomobject]@{ Success = $false; Message = "TCP connection timed out after $Timeout ms." }
            }

            $client.EndConnect($pending)
        } else {
            $client = New-Object System.Net.Sockets.UdpClient
            $client.Client.ReceiveTimeout = $Timeout
            $client.Connect($ComputerName, $Port)
            $data = [System.Text.Encoding]::ASCII.GetBytes((Get-Date).ToString())
            [void]$client.Send($data, $data.Length)
            # Receive throws an error if no reply arrives before the timeout.
            $sender = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
            [void]$client.Receive([ref]$sender)
        }

        return [pscustomobject]@{ Success = $true; Message = '' }
    } catch {
        return [pscustomobject]@{ Success = $false; Message = $_.Exception.Message }
    } finally {
        if ($pending) { $pending.AsyncWaitHandle.Close() }
        if ($client) { $client.Dispose() }
    }
}


# Turn a Test-Port result into a CSV row (same logic for both directions)
function Add-PortProbeResult {
    param ([string]$Direction, [int]$Port, [bool]$Success)

    if ($Protocol -eq 'TCP') {
        if ($Success) { $status = 'Open';   $details = 'TCP connection established.' }
        else          { $status = 'Failed'; $details = 'TCP connection not established (refused, timed out or unreachable).' }
    } else {
        # With UDP a missing reply proves nothing, so it is only "Inconclusive"
        if ($Success) { $status = 'Open';         $details = 'UDP reply received.' }
        else          { $status = 'Inconclusive'; $details = 'No UDP reply received.' }
    }

    Add-TestResult -Direction $Direction -Port $Port -Status $status -Details $details
}


# Find which local IP is used to reach the remote system
function Get-LocalIpForRemoteSystem {
    param ([string]$ComputerName)

    $client = New-Object System.Net.Sockets.UdpClient

    try {
        $client.Connect($ComputerName, 65530)
        return $client.Client.LocalEndPoint.Address.IPAddressToString
    } catch {
        return $null
    } finally {
        $client.Dispose()
    }
}


# Accept "80,443" or @(80,443) and ignore anything that is not a valid port
function Convert-ToPortList {
    param ([object[]]$Ports, [string]$ParameterName)

    $validPorts = @()

    foreach ($value in (($Ports -join ',') -split ',')) {
        $value = $value.Trim()

        if ($value -eq '') { continue }

        $port = 0

        if ([int]::TryParse($value, [ref]$port) -and $port -ge 1 -and $port -le 65535) {
            $validPorts += $port
        } else {
            Write-Host -ForegroundColor Red "Invalid port '$value' in $ParameterName; ignored."
            Write-RunLog -Level WARN -Message "Invalid port '$value' in $ParameterName ignored."
        }
    }

    return $validPorts
}


# Load the Posh-SSH module; returns $false if it is not installed
function Import-PoshSSHModule {
    try {
        Import-Module Posh-SSH -ErrorAction Stop
        return $true
    } catch {
        Write-RunLog -Level ERROR -Message "Unable to import Posh-SSH: $($_.Exception.Message)"
        return $false
    }
}


# Use the credential passed to the script, a saved one, or ask the user
function Get-RemoteCredential {
    param ([string]$ComputerName)

    if ($Credential) { return $Credential }

    $safeName = $ComputerName -replace '[\\/:*?"<>|]', '_'
    $credentialPath = Join-Path $WorkDirectory "file_cred_$safeName.cred"

    if ($SaveCredential -and (Test-Path -LiteralPath $credentialPath -PathType Leaf)) {
        return Import-Clixml -LiteralPath $credentialPath
    }

    $remoteCredential = Get-Credential -Message "Enter credentials for $ComputerName"

    if ($SaveCredential) {
        # Only the same Windows user on this computer can decrypt the file
        $remoteCredential | Export-Clixml -LiteralPath $credentialPath
    }

    return $remoteCredential
}


# Open an SSH session. Unknown host keys are accepted only with -TrustSshHostKey
function New-RemoteSshSession {
    param ([string]$ComputerName, [PSCredential]$RemoteCredential)

    $options = @{
        ComputerName = $ComputerName
        Credential   = $RemoteCredential
        ErrorAction  = 'Stop'
    }

    if ($TrustSshHostKey) { $options.AcceptKey = $true }

    # Splatting (@options) passes the table above as named parameters
    return New-SSHSession @options
}


# Return the requested OS, or detect it: WinRM works = Windows, SSH "uname" says Linux = Linux
function Get-RemoteOperatingSystem {
    param ([PSCredential]$RemoteCredential)

    if ($RemoteOS -ne 'Auto') { return $RemoteOS }

    try {
        $option = New-PSSessionOption -OpenTimeout $Timeout
        $winrm = New-PSSession -ComputerName $RemoteAddress -Credential $RemoteCredential -SessionOption $option -ErrorAction Stop
        Remove-PSSession -Session $winrm
        return 'Windows'
    } catch {
        Write-RunLog -Level WARN -Message "WinRM probe failed: $($_.Exception.Message)"
    }

    $session = $null

    try {
        if (-not (Import-PoshSSHModule)) { return 'Unrecognized' }

        $session = New-RemoteSshSession -ComputerName $RemoteAddress -RemoteCredential $RemoteCredential
        $result = Invoke-SSHCommand -SSHSession $session -Command 'uname -s' -ErrorAction Stop

        if ($result.ExitStatus -eq 0 -and ($result.Output -join ' ') -match '^Linux') { return 'Linux' }
    } catch {
        Write-RunLog -Level WARN -Message "SSH probe failed: $($_.Exception.Message)"
    } finally {
        if ($session) { Remove-SSHSession -SSHSession $session | Out-Null }
    }

    return 'Unrecognized'
}


# UDP arrival check: run tcpdump on the Linux target and look for our probe
# Capture on the target while sending one UDP probe that carries a unique marker text
function Invoke-UdpArrivalCapture {
    param ($SshSession, [int]$Port)

    $marker = 'PROBE-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
    $seconds = 2 + [int][Math]::Ceiling($Timeout / 1000)
    $sudo = if ($CaptureSudo) { 'sudo -n ' } else { '' }

    # tcpdump prints packets as text (-A shows the payload); "timeout" stops it after $seconds
    $command = "${sudo}timeout $seconds tcpdump -nn -l -A -i any -c 50 'udp port $Port or icmp' 2>&1"

    $ssh = $SshSession.Session.CreateCommand($command)
    $ssh.CommandTimeout = [TimeSpan]::FromSeconds($seconds + 10)
    $udp = New-Object System.Net.Sockets.UdpClient

    try {
        $pending = $ssh.BeginExecute()
        Start-Sleep -Seconds 2   # give tcpdump time to start

        $udp.Connect($RemoteAddress, $Port)
        $data = [System.Text.Encoding]::ASCII.GetBytes($marker)
        [void]$udp.Send($data, $data.Length)

        $output = $ssh.EndExecute($pending)   # waits until tcpdump ends
    } finally {
        $udp.Dispose()
        $ssh.Dispose()
    }

    # tcpdump always prints "listening on ..." when it starts correctly
    if ($output -notmatch 'listening on') {
        Write-RunLog -Level WARN -Message "UDP capture port ${Port}: tcpdump did not start. $output"
        return [pscustomobject]@{ Status = 'Error'; Details = 'tcpdump did not start; see diagnostic log.' }
    }

    if ($output -notmatch $marker) {
        return [pscustomobject]@{ Status = 'NotObserved'; Details = 'Probe not seen on the target before the capture ended.' }
    }

    # ICMP refusal looks like "... udp port 161 unreachable"; a reply looks like "x.x.x.x.161 > ...".
    if ($output -match "udp port $Port unreachable") {
        return [pscustomobject]@{ Status = 'PortRefused'; Details = 'Probe arrived; target sent ICMP Port Unreachable (no listener or firewall rejection).' }
    }

    if ($output -match "\.$Port >") {
        return [pscustomobject]@{ Status = 'ReplyObserved'; Details = 'Probe arrived; UDP reply seen leaving the target. Delivery back here is not verified.' }
    }

    return [pscustomobject]@{ Status = 'ArrivalOnly'; Details = 'Probe arrived; no reply or refusal seen. Port state is undetermined.' }
}


# Open one SSH session to the Linux target and run the capture for each port
function Test-UdpArrival {
    $session = $null

    try {
        if ($RemoteOS -eq 'Windows' -or $RemoteAddress -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
            throw 'UDP arrival capture requires a Linux IPv4 destination.'
        }

        if (-not (Import-PoshSSHModule)) { throw 'Posh-SSH module unavailable.' }

        $RemoteCredential = Get-RemoteCredential -ComputerName $RemoteAddress

        if (-not $RemoteCredential) { throw 'No SSH credential supplied.' }

        $session = New-RemoteSshSession -ComputerName $RemoteAddress -RemoteCredential $RemoteCredential
        $os = Invoke-SSHCommand -SSHSession $session -Command 'uname -s' -ErrorAction Stop

        if (($os.Output -join ' ').Trim() -ne 'Linux') { throw 'The destination is not Linux.' }
    } catch {
        Write-RunLog -Level ERROR -Message "UDP arrival setup failed: $($_.Exception.Message)"

        foreach ($port in $ValidLocalPorts) {
            Write-Host -ForegroundColor Red "  Error - UDP/$port - capture setup failed on $RemoteLabel"
            Add-TestResult -Direction LocalToRemote -Port $port -Status Error -Details 'UDP arrival capture setup failed; see diagnostic log.'
        }
        
        if ($session) { Remove-SSHSession -SSHSession $session | Out-Null }

        return
    }

    try {
        foreach ($port in $ValidLocalPorts) {
            try {
                $outcome = Invoke-UdpArrivalCapture -SshSession $session -Port $port
            } catch {
                Write-RunLog -Level ERROR -Message "UDP arrival port ${port}: $($_.Exception.Message)"
                $outcome = [pscustomobject]@{ Status = 'Error'; Details = 'UDP arrival capture failed; see diagnostic log.' }
            }

            $color = switch ($outcome.Status) {
                'ReplyObserved' { 'DarkGreen' }
                'ArrivalOnly'   { 'Cyan' }
                'NotObserved'   { 'Yellow' }
                default         { 'Red' }
            }

            Write-Host -ForegroundColor $color "  $($outcome.Status) - UDP/$port - $RemoteLabel - $($outcome.Details)"
            Add-TestResult -Direction LocalToRemote -Port $port -Status $outcome.Status -Details $outcome.Details
        }
    } finally {
        Remove-SSHSession -SSHSession $session | Out-Null
    }
}


# Test every requested port from this computer to the current remote system
function Test-LocalToRemotePorts {
    if ($UdpArrivalCheck) {
        Test-UdpArrival
        return
    }

    foreach ($port in $ValidLocalPorts) {
        Start-Sleep -Seconds 1
        Write-Host "  Testing $Protocol/$port on $RemoteLabel ..."
        $probe = Test-Port -ComputerName $RemoteAddress -Port $port -Protocol $Protocol -Timeout $Timeout

        if ($probe.Message) {
            Write-RunLog -Level WARN -Message "$Protocol probe to ${RemoteAddress}:${port}: $($probe.Message)"
        }

        Add-PortProbeResult -Direction LocalToRemote -Port $port -Success $probe.Success
    }
}


# Ask the remote system to test ports on this computer: Test-Port on Windows, netcat on Linux
function Test-RemoteToLocalPorts {
    param ([PSCredential]$RemoteCredential, [string]$OperatingSystem)

    if ($OperatingSystem -notin @('Windows','Linux')) {
        Add-SkippedReverseResults -Reason 'Remote OS could not be identified.'
        return
    }

    if ($OperatingSystem -eq 'Linux' -and -not (Import-PoshSSHModule)) {
        Add-SkippedReverseResults -Reason 'Posh-SSH module unavailable.'
        return
    }

    foreach ($port in $ValidReversePorts) {
        Start-Sleep -Seconds 1
        Write-Host "  Testing $Protocol/$port on local system ($LocalHostname - $LocalAddress) ..."
        $session = $null

        try {
            if ($OperatingSystem -eq 'Windows') {
                # Send the body of Test-Port to the remote computer and run it there
                $probe = Invoke-Command -ComputerName $RemoteAddress -Credential $RemoteCredential -ErrorAction Stop `
                    -ScriptBlock ${function:Test-Port} -ArgumentList $LocalAddress, $port, $Protocol, $Timeout
                Add-PortProbeResult -Direction RemoteToLocal -Port $port -Success $probe.Success
            } else {
                $session = New-RemoteSshSession -ComputerName $RemoteAddress -RemoteCredential $RemoteCredential
                $flags = if ($Protocol -eq 'UDP') { '-zuv' } else { '-zv' }
                $result = Invoke-SSHCommand -SSHSession $session -Command "nc $flags $LocalAddress $port" -ErrorAction Stop

                if ($result.ExitStatus -eq 127) {
                    Add-TestResult -Direction RemoteToLocal -Port $port -Status Error -Details 'Remote command nc (netcat) is missing.'
                } elseif ($Protocol -eq 'UDP') {
                    # Netcat cannot prove that a UDP port is open, whatever its exit status
                    Add-TestResult -Direction RemoteToLocal -Port $port -Status Inconclusive -Details "UDP netcat exit status $($result.ExitStatus); does not confirm an open port."
                } elseif ($result.ExitStatus -eq 0) {
                    Add-TestResult -Direction RemoteToLocal -Port $port -Status Open -Details 'TCP connection established by netcat.'
                } else {
                    Write-RunLog -Level WARN -Message "Reverse TCP port ${port}: netcat exit $($result.ExitStatus); $($result.Error -join ' ')"
                    Add-TestResult -Direction RemoteToLocal -Port $port -Status Failed -Details "TCP connection not confirmed; netcat exit status $($result.ExitStatus)."
                }
            }
        } catch {
            Write-RunLog -Level ERROR -Message "Reverse $Protocol port ${port}: $($_.Exception.Message)"
            Add-TestResult -Direction RemoteToLocal -Port $port -Status Error -Details 'Remote execution failed; see diagnostic log.'
        } finally {
            if ($session) { Remove-SSHSession -SSHSession $session | Out-Null }
        }
    }
}


########## MAIN ##########

$ScriptName    = $MyInvocation.MyCommand.Name
$RunTimestamp  = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'
$LocalHostname = $env:COMPUTERNAME
$LocalAddress  = $null
$RemoteLabel   = $null
$SystemFile    = if ($SystemListPath) { $SystemListPath } else { Join-Path $WorkDirectory 'system.txt' }
$LogFolder     = Join-Path $PSScriptRoot 'Log'
$CsvFolder     = Join-Path $PSScriptRoot 'CSV'
$LogFile       = Join-Path $LogFolder "log_connection-$RunTimestamp.log"
$ResultsFile   = Join-Path $CsvFolder "results_connection-$RunTimestamp.csv"

if (-not $Protocol -or -not ($LocalToRemotePorts -join ',')) {
    Show-Usage
    return
}

foreach ($folder in @($WorkDirectory, $LogFolder, $CsvFolder)) {
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
}

$Protocol = $Protocol.ToUpperInvariant()
Write-RunLog -Message "Run started. Systems: $SystemFile; results: $ResultsFile"

$ValidLocalPorts   = @(Convert-ToPortList -Ports $LocalToRemotePorts -ParameterName '-L')
$ValidReversePorts = @(Convert-ToPortList -Ports $RemoteToLocalPorts -ParameterName '-R')

if ($ValidLocalPorts.Count -eq 0) {
    Write-RunLog -Level ERROR -Message 'No valid local-to-remote ports supplied.'
    Write-Host -ForegroundColor Red 'No valid ports to test.'
    return
}

if (-not (Test-Path -LiteralPath $SystemFile -PathType Leaf)) {
    Write-RunLog -Level ERROR -Message "System list not found: $SystemFile"
    Write-Host -ForegroundColor Red "Create the system list first: $SystemFile (one hostname,ip per line)."
    return
}

foreach ($line in (Get-Content -LiteralPath $SystemFile -ErrorAction Stop)) {
    $RemoteLabel = $null
    $line = $line.Trim()

    if ($line -eq '') { continue }

    # Each line must look like: hostname,ip
    $fields = $line.Split(',')
    $parsedAddress = $null

    if ($fields.Count -ne 2 -or [string]::IsNullOrWhiteSpace($fields[0]) -or
        -not [System.Net.IPAddress]::TryParse($fields[1].Trim(), [ref]$parsedAddress)) {
        Write-Warning "Invalid system entry: '$line'. Expected hostname,ip"
        Write-RunLog -Level WARN -Message "Invalid system entry skipped: '$line'. Expected hostname,ip"
        continue
    }

    $RemoteHostname = $fields[0].Trim()
    $RemoteAddress  = $fields[1].Trim()
    $RemoteLabel    = "$RemoteHostname ($RemoteAddress)"
    $LocalAddress   = Get-LocalIpForRemoteSystem -ComputerName $RemoteAddress

    if (-not $LocalAddress) {
        Write-RunLog -Level WARN -Message 'Unable to determine the local route address.'
    }

    Write-Host -ForegroundColor Green "`nTesting the remote system: $RemoteLabel ...`n"
    Write-RunLog -Message 'Starting remote system checks.'

    # Ping is only informational: port tests run even if ICMP is blocked.
    if (Test-Connection -ComputerName $RemoteAddress -Count 2 -Quiet -ErrorAction SilentlyContinue) {
        Add-TestResult -Direction LocalToRemote -Test Ping -Status Reachable -Details 'ICMP reply received.'
    } else {
        Write-Host -ForegroundColor Red '  Ping KO'
        Add-TestResult -Direction LocalToRemote -Test Ping -Status NoReply -Details 'No ICMP reply; port tests continue because ICMP may be blocked.'
    }

    Test-LocalToRemotePorts

    if ($ValidReversePorts.Count -gt 0) {
        if (-not $LocalAddress) {
            Add-SkippedReverseResults -Reason 'Unable to determine the local route address.'
        } else {
            try {
                $RemoteCredential = Get-RemoteCredential -ComputerName $RemoteAddress
                $DetectedOS = Get-RemoteOperatingSystem -RemoteCredential $RemoteCredential
                Write-Host "  Remote OS: $DetectedOS"
                Write-RunLog -Message "Remote OS: $DetectedOS."
                Test-RemoteToLocalPorts -RemoteCredential $RemoteCredential -OperatingSystem $DetectedOS
            } catch {
                Write-RunLog -Level ERROR -Message "Reverse test setup failed: $($_.Exception.Message)"
                Add-SkippedReverseResults -Reason 'Reverse test setup failed; see diagnostic log.'
            }
        }
    }

    Write-RunLog -Message 'Remote system checks completed.'
}

$RemoteLabel = $null
Write-RunLog -Message 'Run completed.'

if (Test-Path -LiteralPath $ResultsFile -PathType Leaf) {
    Write-Host -ForegroundColor Yellow "`nResults: $ResultsFile"
} else {
    Write-Host -ForegroundColor Yellow "`nNo results generated; CSV not created."
}

Write-Host -ForegroundColor Yellow "Diagnostic log: $LogFile`n"