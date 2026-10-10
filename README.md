# Network Connectivity Check

A program that checks whether **TCP and UDP** ports are reachable from a Windows machine to one or more remote systems (Windows or Linux). It can also run the reverse test (from the remote system back to the local machine).

Results are saved in a **CSV** file and technical details in a **log** file.

---

## Table of contents

1. [What it does](#what-it-does)
2. [Requirements](#requirements)
3. [Quick start](#quick-start)
4. [Project structure](#project-structure)
5. [Parameters](#parameters)
6. [Files used and generated](#files-used-and-generated)
7. [How the tests work](#how-the-tests-work)
8. [Console output](#console-output)
9. [CSV content](#csv-content)
10. [Status and Details values](#status-and-details-values)
11. [Log format](#log-format)
12. [Credentials](#credentials)
13. [Known limitations](#known-limitations)
14. [Usage reference](#usage-reference)
15. [Usage examples](#usage-examples)
16. [Example files](#example-files)
17. [License](#license)

---

## What it does

For every system listed in `system.txt`, the script runs, in order:

1. **Ping** (informational only: port tests continue even if the ping fails).
2. **Local-to-remote test** on the ports given with `-L`.
3. **Remote-to-local test** on the ports given with `-R` (optional).

Instead of step 2, `-UdpArrivalCheck` runs a **`tcpdump` capture** on the Linux destination to check whether the UDP probe actually arrived.

---

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

---

## Quick start

**1. Create the system list** (default `C:\temp\system.txt`), one `hostname,ip` per line:

```text
host1,<IP1>
host2,<IP2>
```

Tests always use the **IP**; the hostname is only used to label the results.

**2. Run the script:**

```powershell
.\Test-NetworkConnectivity.ps1 -T TCP -L 80,443
```

**3. Read the results** in the CSV and log files shown at the end of the run.

Running the script **without** `-T` and `-L` prints the help text, including the file paths.

---

## Project structure

```text
Infrastructure-Connectivity-Check/
├── Test-NetworkConnectivity.ps1
├── README.md
└── examples/
    ├── system.txt
    ├── CSV/
    │   ├── results_connection-2026-10-01_14-30-00-123.csv
    │   └── results_connection-2026-10-01_15-10-00-456.csv
    └── Log/
        ├── log_connection-2026-10-01_14-30-00-123.log
        └── log_connection-2026-10-01_15-10-00-456.log
```

---

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

**Parameter rules** (otherwise the script stops with an error):

- `-UdpArrivalCheck` requires `-T UDP` and supports `-L` only (not `-R`).
- `-CaptureSudo` requires `-UdpArrivalCheck`.

---

## Files used and generated

| File                                 | Location                                 | Content                                             |
| ------------------------------------ | ---------------------------------------- | --------------------------------------------------- |
| `system.txt`                         | `<WorkDirectory>` (or `-SystemListPath`) | Systems to test, one `hostname,ip` per line (input) |
| `file_cred_<ip>.cred`                | `<WorkDirectory>`                        | Credential saved with `-SaveCredential`             |
| `results_connection-<timestamp>.csv` | `CSV` folder next to the script          | Test results                                        |
| `log_connection-<timestamp>.log`     | `Log` folder next to the script          | Diagnostic log                                      |

The `Log`, `CSV` and `<WorkDirectory>` folders are created automatically. The CSV is created only when the first result is recorded.

---

## How the tests work

### TCP

The program tries to open a connection to the port within `-Timeout`. If the connection opens the port is **Open**; otherwise it is **Failed** (refused, timed out or unreachable).

### UDP

UDP has no handshake, so the program sends a packet and waits for a reply within `-Timeout`.

- Reply received: **Open**.
- No reply: **Inconclusive**. This does not mean the port is closed: many services (for example 3389 or 161/SNMP) only answer valid requests.

### UDP with capture (`-UdpArrivalCheck`)

1. The program connects to the Linux destination over SSH and starts `tcpdump` (filter `udp port N or icmp`).
2. After 2 seconds it sends a UDP probe carrying a unique marker text.
3. When the capture ends it looks in the `tcpdump` output for the probe marker, an ICMP _port unreachable_ and a UDP reply.

Time per port: about 2 seconds of startup plus `-Timeout` rounded up to whole seconds.

### Reverse test (`-R`)

- **Windows**: the test function is run on the remote system through WinRM (`Invoke-Command`) and tries to reach the local IP.
- **Linux**: over SSH the program runs `nc -zv` (TCP) or `nc -zuv` (UDP) towards the local IP.
- For UDP the result on Linux is always **Inconclusive**, because netcat cannot confirm that a UDP port is open.

### OS detection (`-RemoteOS`)

The program tries WinRM first (if a session opens, the system is `Windows`), then SSH with `uname -s` (if it answers `Linux`, the system is `Linux`). Otherwise the result is `Unrecognized` and reverse tests are skipped.

There is a 1-second pause between ports.

---

## Console output

| Message                                                            | Colour  | When                           |
| ------------------------------------------------------------------ | ------- | ------------------------------ |
| `Testing the remote system: <host> (<ip>) ...`                     | green   | Start of a system              |
| `  Ping KO`                                                        | red     | The ping got no reply          |
| `  Testing <TCP/UDP>/<port> on <host> (<ip>) ...`                  | default | Local-to-remote test           |
| `  Testing <TCP/UDP>/<port> on local system (<host> - <ip>) ...`   | default | Remote-to-local test           |
| `  Remote OS: <Windows/Linux/Unrecognized>`                        | default | After OS detection             |
| `Invalid port '<x>' in -L; ignored.`                               | red     | Invalid port in `-L` or `-R`   |
| `No valid ports to test.`                                          | red     | No valid port in `-L`          |
| `Create the system list first: <path> (one hostname,ip per line).` | red     | `system.txt` not found         |
| `Invalid system entry: '<line>'. Expected hostname,ip`             | warning | Malformed line in `system.txt` |
| `Results: <CSV path>`                                              | yellow  | End of run, CSV created        |
| `No results generated; CSV not created.`                           | yellow  | End of run, no results         |
| `Diagnostic log: <log path>`                                       | yellow  | End of run                     |

In UDP tests (without capture) the status of each port is **not** printed to the console: read it in the CSV.

With `-UdpArrivalCheck` each port prints one line in the format `  <Status> - UDP/<port> - <host> (<ip>) - <Details>`:

| Status                 | Colour     |
| ---------------------- | ---------- |
| `ReplyObserved`        | dark green |
| `ArrivalOnly`          | cyan       |
| `NotObserved`          | yellow     |
| `PortRefused`, `Error` | red        |

If the capture setup fails, each port prints: `  Error - UDP/<port> - capture setup failed on <host> (<ip>)`.

---

## CSV content

Semicolon-separated, UTF-8 encoded. One row per test.

| Column                                 | Description                                                     |
| -------------------------------------- | --------------------------------------------------------------- |
| `Timestamp`                            | Date and time of the result                                     |
| `Direction`                            | `LocalToRemote` or `RemoteToLocal`                              |
| `SourceHostname`, `SourceIP`           | Origin of the test (in reverse tests this is the remote system) |
| `DestinationHostname`, `DestinationIP` | Target of the test (in reverse tests this is the local PC)      |
| `Test`                                 | `Port` or `Ping`                                                |
| `Protocol`                             | `TCP`, `UDP` or `ICMP` (for ping)                               |
| `Port`                                 | Port number (empty for ping)                                    |
| `Status`                               | Outcome, see the tables below                                   |
| `Details`                              | Explanation of the outcome                                      |

---

## Status and Details values

### Ping

| Status      | Details                                                           |
| ----------- | ----------------------------------------------------------------- |
| `Reachable` | `ICMP reply received.`                                            |
| `NoReply`   | `No ICMP reply; port tests continue because ICMP may be blocked.` |

### Normal TCP and UDP tests (both directions)

| Protocol | Status         | Details                                                               |
| -------- | -------------- | --------------------------------------------------------------------- |
| TCP      | `Open`         | `TCP connection established.`                                         |
| TCP      | `Failed`       | `TCP connection not established (refused, timed out or unreachable).` |
| UDP      | `Open`         | `UDP reply received.`                                                 |
| UDP      | `Inconclusive` | `No UDP reply received.`                                              |

### UDP capture (`-UdpArrivalCheck`)

| Status          | Meaning                                                                                              | Details                                                                                                                                                    |
| --------------- | ---------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ReplyObserved` | The probe arrived and the target sent a UDP reply. This does not prove the reply made it back to you | `Probe arrived; UDP reply seen leaving the target. Delivery back here is not verified.`                                                                    |
| `PortRefused`   | The probe arrived and the target sent ICMP _Port Unreachable_ (no listener, or a firewall rejection) | `Probe arrived; target sent ICMP Port Unreachable (no listener or firewall rejection).`                                                                    |
| `ArrivalOnly`   | The probe arrived, but neither a reply nor a refusal was seen: port state undetermined               | `Probe arrived; no reply or refusal seen. Port state is undetermined.`                                                                                     |
| `NotObserved`   | The probe was not seen on the target before the capture ended                                        | `Probe not seen on the target before the capture ended.`                                                                                                   |
| `Error`         | The capture did not work (see the log)                                                               | `tcpdump did not start; see diagnostic log.` / `UDP arrival capture failed; see diagnostic log.` / `UDP arrival capture setup failed; see diagnostic log.` |

UDP arrival alone does **not** prove that a port is open, and the lack of a reply can be perfectly normal.

### Reverse test (`-R`)

| Remote system | Status                             | Details                                                      |
| ------------- | ---------------------------------- | ------------------------------------------------------------ |
| Windows       | `Open` / `Failed` / `Inconclusive` | Same texts as the normal TCP/UDP tests                       |
| Linux, TCP    | `Open`                             | `TCP connection established by netcat.`                      |
| Linux, TCP    | `Failed`                           | `TCP connection not confirmed; netcat exit status <N>.`      |
| Linux, UDP    | `Inconclusive`                     | `UDP netcat exit status <N>; does not confirm an open port.` |
| Linux         | `Error`                            | `Remote command nc (netcat) is missing.`                     |
| Any           | `Error`                            | `Remote execution failed; see diagnostic log.`               |

### Skipped reverse tests (`Skipped`)

| Details (reason)                                 |
| ------------------------------------------------ |
| `Remote OS could not be identified.`             |
| `Posh-SSH module unavailable.`                   |
| `Unable to determine the local route address.`   |
| `Reverse test setup failed; see diagnostic log.` |

---

## Log format

Every line looks like this:

```text
2026-10-01 14:30:12 [LEVEL] [host (ip)] message
```

- `LEVEL` is `INFO`, `WARN` or `ERROR`.
- The second field is the system being tested (or the local PC name when none is selected).
- The log holds details that the CSV only hints at: socket error messages, `tcpdump` output when it fails to start, WinRM/SSH errors, netcat exit codes, rejected lines of `system.txt`, invalid ports.

---

## Credentials

Normal local-to-remote tests do **not** need credentials. They are needed for reverse tests, OS detection and UDP capture.

| Situation              | Behaviour                                                                                            |
| ---------------------- | ---------------------------------------------------------------------------------------------------- |
| `-Credential` supplied | Used for all systems and never saved (`-SaveCredential` is ignored)                                  |
| No option              | Credentials are requested for each system                                                            |
| `-SaveCredential`      | If a file already exists for that system it is reused; otherwise credentials are requested and saved |

`.cred` files are protected by Windows: only the same user on the same computer can decrypt them. Use `-SaveCredential` on every run to reuse them.

---

## Known limitations

- **UDP capture works only on Linux with IPv4.** With a Windows (or IPv6) target the program returns `Error` for every port.
- With UDP, "no reply" is `Inconclusive`, not "port closed".
- The reverse UDP test towards Linux is always `Inconclusive`.
- The capture filter does not restrict the source IP (so it also works behind NAT): ICMP refusals or replies on that port could in theory come from other traffic.
- If `tcpdump` takes more than 2 seconds to start, the probe is sent too early and the result is `NotObserved`. The pause can be increased in `Invoke-UdpArrivalCapture`.
- The reverse test on Windows needs WinRM and an account with the required rights.

---

## Usage reference

```
INFRASTRUCTURE CONNECTIVITY CHECK

Usage:
  .\Test-NetworkConnectivity.ps1 -T <TCP|UDP> -L <ports> [options]

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
  .\Test-NetworkConnectivity.ps1 -T TCP -L 80,443
  .\Test-NetworkConnectivity.ps1 -T TCP -L 5985 -R 8080 -RemoteOS Windows
  .\Test-NetworkConnectivity.ps1 -T UDP -L 161,514 -UdpArrivalCheck

System list:    C:\temp\system.txt
Diagnostic log: C:\<user>\<documents>\Log\log_connection-2026-10-03_19-10-00-432.log
Results CSV:    C:\<user>\<documents>\CSV\results_connection-2026-10-03_19-10-00-432.csv
```

---

## Usage examples

```powershell
# TCP to ports 80 and 443 on every system
.\Test-NetworkConnectivity.ps1 -T TCP -L 80,443

# TCP in both directions, Windows remote system
.\Test-NetworkConnectivity.ps1 -T TCP -L 5985 -R 8080 -RemoteOS Windows

# UDP with capture on Linux
.\Test-NetworkConnectivity.ps1 -T UDP -L 161,514 -UdpArrivalCheck

# Capture with a single credential and passwordless sudo
.\Test-NetworkConnectivity.ps1 -T UDP -L 161 -UdpArrivalCheck -CaptureSudo -Credential (Get-Credential)

# System list in a different location
.\Test-NetworkConnectivity.ps1 -T TCP -L 443 -SystemListPath 'D:\Lists\systems.txt'
```

---

## Example files

The `examples` folder contains sample input and output files, so you can see what the script reads and produces without running it. Hostnames, IPs and timestamps are fictitious.

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

It shows `Open` and `Failed` results, a reverse test through netcat, and a log with a timeout warning and a netcat refusal.

**UDP capture example** (CSV and log `15-10-00-456`):

```powershell
.\Test-NetworkConnectivity.ps1 -T UDP -L 161,514,5000,9999 -UdpArrivalCheck -CaptureSudo
```

## License

Released under the MIT License. See [LICENSE](LICENSE).
