# Network Connectivity Check

[Test-NetworkConnectivity.ps1](Test-NetworkConnectivity.ps1) tests TCP or UDP connectivity from a Windows computer to systems listed in an input file. It can also run reverse tests from Windows/Linux targets and verify UDP arrival using a capture on Linux. Results are saved to CSV, with diagnostics in a separate log.

## Contents

- [Repository structure](#repository-structure)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Parameters](#parameters)
- [Credentials](#credentials)
- [Test behavior and results](#test-behavior-and-results)
- [Reports and logs](#reports-and-logs)
- [Limitations and troubleshooting](#limitations-and-troubleshooting)
- [Example files](#example-files)
- [License](#license)

## Repository structure

```text
Network-Connectivity-Check/
|-- examples/
|   |-- CSV/
|   |-- Log/
|   `-- system.txt
|-- LICENSE
|-- README.md
`-- Test-NetworkConnectivity.ps1
```

## Requirements

| Feature                                   | Requirement                                                                                                                      |
| ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Local-to-remote tests (normal TCP/UDP)    | No login needed on the remote system                                                                                             |
| Remote-to-local test on **Windows**       | WinRM enabled on the remote system and valid credentials                                                                         |
| Remote-to-local test on **Linux**         | SSH access, `nc` (netcat) on the remote system, **Posh-SSH** module locally                                                      |
| Automatic OS detection (`-RemoteOS Auto`) | WinRM, or SSH + Posh-SSH                                                                                                         |
| UDP capture (`-UdpArrivalCheck`)          | **Linux destination with IPv4**, Posh-SSH locally, `tcpdump` and `timeout` on the Linux host, capture rights (root or `sudo -n`) |

Install the SSH module when needed:

```powershell
Install-Module -Name Posh-SSH
```

## Quick start

Create `C:\temp\system.txt`, or select another input file with `-SystemListPath`. Use one `hostname,ip` entry per line:

```text
<HOSTNAME_1>,<IP_ADDRESS_1>
<HOSTNAME_2>,<IP_ADDRESS_2>
```

Replace the placeholders before running. The IP is used for connections; the hostname labels the results. Blank lines are ignored. Invalid entries are skipped with a warning; comment lines are not specially supported.

Run from the project directory:

```powershell
# TCP to the listed systems
.\Test-NetworkConnectivity.ps1 -T TCP -L 80,443

# TCP in both directions, with Windows targets
.\Test-NetworkConnectivity.ps1 -T TCP -L 5985 -R 8080 -RemoteOS Windows

# UDP arrival capture on Linux, using passwordless sudo
.\Test-NetworkConnectivity.ps1 -T UDP -L 161,514 -UdpArrivalCheck -CaptureSudo -Credential (Get-Credential)

# Custom system list
.\Test-NetworkConnectivity.ps1 -T TCP -L 443 -SystemListPath 'D:\Lists\systems.txt'
```

Running without `-T` or without `-L` displays the built-in usage. Read the generated CSV for individual outcomes; the console reports progress and prints report paths at completion.

## Parameters

| Parameter             | Alias                          | Description                                       | Default                      |
| --------------------- | ------------------------------ | ------------------------------------------------- | ---------------------------- |
| `-Protocol`           | `-T`, `-port_type`             | Protocol to test: `TCP` or `UDP`                  | - (required)                 |
| `-LocalToRemotePorts` | `-L`, `-ports_local_to_remote` | Ports to test from this PC to the remote systems  | - (required)                 |
| `-RemoteToLocalPorts` | `-R`, `-ports_remote_to_local` | Ports to test from the remote system to this PC   | none                         |
| `-RemoteOS`           |                                | `Auto`, `Windows` or `Linux`                      | `Auto`                       |
| `-Timeout`            |                                | Timeout in milliseconds (100-60000)               | `1000`                       |
| `-WorkDirectory`      |                                | Folder for `system.txt` and saved credentials     | `C:\temp`                    |
| `-SystemListPath`     |                                | Alternative path for the system list              | `<WorkDirectory>\system.txt` |
| `-Credential`         |                                | One credential used for all systems, never saved  | -                            |
| `-SaveCredential`     |                                | Save and reuse one credential per system          | off                          |
| `-TrustSshHostKey`    |                                | Accept unknown SSH host keys (trusted hosts only) | off                          |
| `-UdpArrivalCheck`    |                                | Run a `tcpdump` capture on the Linux destination  | off                          |
| `-CaptureSudo`        |                                | Run `tcpdump` with `sudo -n` (no password prompt) | off                          |

Ports can be written as `80,443` or `'80,443'`. Invalid ports (not a number, or outside 1-65535) are ignored with a warning.

**Parameter rules** (otherwise the program stops with an error):

- `-UdpArrivalCheck` requires `-T UDP` and supports `-L` only (not `-R`).
- `-CaptureSudo` requires `-UdpArrivalCheck`.

## Credentials

Normal local-to-remote tests do **not** need credentials. They are needed for reverse tests, OS detection and UDP capture.

| Situation              | Behaviour                                                                                            |
| ---------------------- | ---------------------------------------------------------------------------------------------------- |
| `-Credential` supplied | Used for all systems and never saved (`-SaveCredential` is ignored)                                  |
| No option              | Credentials are requested for each system                                                            |
| `-SaveCredential`      | If a file already exists for that system it is reused; otherwise credentials are requested and saved |

`.cred` files are protected by Windows: only the same user on the same computer can decrypt them. Use `-SaveCredential` on every run to reuse them.

## Test behavior and results

For each system, the program performs an informational ping, local-to-remote port tests (`-L`), then optional reverse tests (`-R`). A failed ping does not stop port tests. Systems and ports are processed sequentially, with a one-second pause between port tests.

### Standard tests

TCP attempts a connection within `-Timeout`. UDP sends a probe and waits for a reply; a service may ignore a probe that is not a valid protocol request.

| Test | Status         | Meaning                                                        |
| ---- | -------------- | -------------------------------------------------------------- |
| Ping | `Reachable`    | ICMP reply received.                                           |
| Ping | `NoReply`      | No ICMP reply; ICMP may be blocked.                            |
| TCP  | `Open`         | Connection established.                                        |
| TCP  | `Failed`       | Connection not established: refused, timed out or unreachable. |
| UDP  | `Open`         | Reply received.                                                |
| UDP  | `Inconclusive` | No reply; this does not establish that the port is closed.     |

### Reverse tests

Windows targets execute the probe through WinRM. Linux targets execute `nc -zv` for TCP or `nc -zuv` for UDP through SSH. Linux UDP results are always `Inconclusive`, since netcat's exit status does not confirm an open UDP port.

With `-RemoteOS Auto`, detection tries WinRM first, then SSH with `uname -s`. Reverse tests use the local route address selected for the destination.

`Skipped` means the reverse test could not be set up, for example because the OS was unrecognized, Posh-SSH was unavailable, or the local route address could not be determined. `Error` indicates a test execution failure, such as a missing `nc` command. Check `Details` and the diagnostic log for the cause.

### UDP arrival capture

`-UdpArrivalCheck` uses SSH to start `tcpdump` on the Linux destination, waits two seconds, then sends a UDP probe with a unique marker. Capture duration includes this startup interval and `-Timeout` rounded up to whole seconds. The capture filter is `udp port N or icmp`.

| Status          | Meaning                                                                                                  |
| --------------- | -------------------------------------------------------------------------------------------------------- |
| `ReplyObserved` | Probe arrived and a UDP reply was seen leaving the target; delivery back to the source is not verified.  |
| `PortRefused`   | Probe arrived and an ICMP Port Unreachable was observed, indicating no listener or a firewall rejection. |
| `ArrivalOnly`   | Probe arrived without an observed reply or refusal; port state remains unknown.                          |
| `NotObserved`   | Probe was not seen before capture ended.                                                                 |
| `Error`         | Capture setup or execution failed; inspect the log.                                                      |

Arrival alone does not prove a port is open. Capture outcomes are printed to the console and stored in CSV; standard UDP outcomes should be read from CSV.

## Reports and logs

| File                                 | Location                               | Purpose                               |
| ------------------------------------ | -------------------------------------- | ------------------------------------- |
| `system.txt`                         | `-WorkDirectory`, or `-SystemListPath` | Input system list.                    |
| `file_cred_<ip>.cred`                | `-WorkDirectory`                       | Optional saved credentials.           |
| `results_connection-<timestamp>.csv` | `CSV` next to the script               | One result row per ping or port test. |
| `log_connection-<timestamp>.log`     | `Log` next to the script               | Diagnostic messages.                  |

Output names use `yyyy-MM-dd_HH-mm-ss-fff`, creating separate files for each run. The work, CSV and log directories are created automatically; the CSV is created only when the first result is recorded. `-WorkDirectory` does not relocate CSV/log output.

The CSV is semicolon-separated UTF-8:

| Columns                                | Contents                                                             |
| -------------------------------------- | -------------------------------------------------------------------- |
| `Timestamp`                            | Time of the result.                                                  |
| `Direction`                            | `LocalToRemote` or `RemoteToLocal`.                                  |
| `SourceHostname`, `SourceIP`           | Origin of the probe.                                                 |
| `DestinationHostname`, `DestinationIP` | Target of the probe.                                                 |
| `Test`, `Protocol`, `Port`             | `Ping`/`Port`, `ICMP`/`TCP`/`UDP`, and port number (empty for ping). |
| `Status`, `Details`                    | Outcome and its explanation.                                         |

Log entries use this format:

```text
<TIMESTAMP> [INFO|WARN|ERROR] [<HOSTNAME> (<IP_ADDRESS>)] <MESSAGE>
```

The log records socket, SSH/WinRM and capture errors, rejected input entries and invalid ports. Use it when CSV details refer to a setup or execution failure.

## Limitations and troubleshooting

- UDP capture requires a Linux IPv4 destination. Windows or IPv6 capture targets produce errors.
- The capture filter does not restrict source IP; other traffic on the same port can affect interpretation of replies or ICMP refusals.
- If `tcpdump` starts too slowly, the probe can be sent before capture is ready and produce `NotObserved`.
- Missing reports can indicate invalid input, no recorded results or output-directory permission problems. Inspect console messages and the log.

## Example files

The `examples` folder contains sample input and output files, so you can see what the program reads and produces without running it. Hostnames, IPs and timestamps are fictitious.

| File                                                                                                          | Description                                                |
| ------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| [system.txt](examples/system.txt)                                                                             | Sample system list (`hostname,ip` per line)                |
| [results_connection-2026-10-01_14-30-00-123.csv](examples/CSV/results_connection-2026-10-01_14-30-00-123.csv) | CSV from a TCP run with a reverse test (see command below) |
| [log_connection-2026-10-01_14-30-00-123.log](examples/Log/log_connection-2026-10-01_14-30-00-123.log)         | Log of the same TCP run                                    |
| [results_connection-2026-10-01_15-10-00-456.csv](examples/CSV/results_connection-2026-10-01_15-10-00-456.csv) | CSV from a UDP capture run                                 |
| [log_connection-2026-10-01_15-10-00-456.log](examples/Log/log_connection-2026-10-01_15-10-00-456.log)         | Log of the same UDP capture run                            |

**TCP example** (CSV and log `14-30-00-123`):

```powershell
.\Test-NetworkConnectivity.ps1 -T TCP -L 80,443 -R 8080 -RemoteOS Linux
```

**UDP capture example** (CSV and log `15-10-00-456`):

```powershell
.\Test-NetworkConnectivity.ps1 -T UDP -L 161,514,5000,9999 -UdpArrivalCheck -CaptureSudo
```

## License

Released under the MIT License. See [LICENSE](LICENSE).
