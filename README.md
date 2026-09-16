# Proxmox Guest Disk Alert

A lightweight disk-capacity monitor for a standalone Proxmox VE node.

It checks disk usage for:

- Running QEMU virtual machines through QEMU Guest Agent:
  ```bash
  qm agent <vmid> get-fsinfo
  ```
- Running LXC containers:
  ```bash
  pct df <vmid>
  ```
- Persistent local filesystems on the Proxmox host:
  ```bash
  df --block-size=1
  ```

The monitor is intended for environments that need useful disk-full alerts without deploying a full monitoring stack.

## Features

- Monitors all currently running QEMU VMs and LXC containers.
- Monitors persistent Proxmox host filesystems.
- Supports multiple filesystems per VM or container.
- Tracks alert state separately for every guest filesystem and host filesystem.
- Sends one combined message per affected VM, LXC container, or Proxmox host.
- Alerts when disk usage is greater than or equal to a configurable threshold.
- Sends an initial alert when a filesystem first exceeds the threshold.
- Sends no more than one reminder per affected filesystem per calendar day.
- Sends a recovery notification when filesystem usage falls below the threshold.
- Supports configurable quiet hours.
- Uses `America/New_York` by default for quiet-hour and daily-reminder decisions.
- Ignores stopped guests.
- Ignores VM pseudo-filesystems, loop devices, USB-backed filesystems, SquashFS, EROFS, and similar non-actionable mounts.
- Ignores host pseudo-filesystems and `/etc/pve` / pmxcfs.
- Uses `flock` to prevent overlapping runs.
- Uses atomic root-owned state files.
- Runs from a systemd timer every 15 minutes.
- Sends diagnostic output to the systemd journal.

## Requirements

This project is designed for a standalone Proxmox VE node.

The script requires:

- Bash
- `jq`
- `awk`
- `qm`
- `pct`
- `df`
- `flock`
- `timeout`
- `sendmail`
- systemd

Most requirements are already available on Proxmox VE. Verify them with:

```bash
for cmd in awk date df flock hostname jq logger mkdir mktemp mv pct qm sendmail sha256sum timeout tr; do
  command -v "$cmd" || echo "MISSING: $cmd"
done
```

No output indicates that all required commands are available.

## Notification prerequisites

The script submits notifications using:

```bash
/usr/sbin/sendmail -t -oi
```

with the recipient set to local `root`.

Before enabling the monitor, verify that mail sent to local root is delivered through the desired path, including email and Pushover if applicable.

Send a test message:

```bash
{
  printf 'To: root\n'
  printf 'Subject: [PVE Disk Alert TEST] Notification path test\n'
  printf 'Auto-Submitted: auto-generated\n'
  printf 'Content-Type: text/plain; charset=UTF-8\n'
  printf '\n'
  printf 'This is a test of the PVE disk-alert notification path.\n'
  printf 'No disk condition exists; this is only a delivery test.\n'
} | /usr/sbin/sendmail -t -oi
```

Verify that the intended email and Pushover notifications arrive before continuing.

> The script treats successful submission to the local `sendmail` command as a successful local handoff. It cannot independently confirm final delivery by a remote SMTP server, webhook, or Pushover.

## Repository files

| File | Purpose | Installed path |
|---|---|---|
| `pve-guest-disk-alert` | Disk-monitoring script | `/usr/local/sbin/pve-guest-disk-alert` |
| `pve-guest-disk-alert.service` | systemd one-shot service | `/etc/systemd/system/pve-guest-disk-alert.service` |
| `pve-guest-disk-alert.timer` | systemd timer, every 15 minutes | `/etc/systemd/system/pve-guest-disk-alert.timer` |
| `install.sh` | Optional local installer | Run from repository checkout |

## Installation

### Option A: Review and install manually

This method is recommended if you prefer to review every file and copy it yourself.

Clone the repository:

```bash
git clone [https://github.com/REPLACE_WITH_YOUR_ACCOUNT/pve-guest-disk-alert.git](https://github.com/REPLACE_WITH_YOUR_ACCOUNT/pve-guest-disk-alert.git)
cd pve-guest-disk-alert
```

Or download the repository ZIP from GitHub, extract it, and change into the extracted directory.

Review the files:

```bash
less pve-guest-disk-alert
less pve-guest-disk-alert.service
less pve-guest-disk-alert.timer
```

Validate the script syntax:

```bash
bash -n pve-guest-disk-alert
```

Install the script:

```bash
install -o root -g root -m 0750 \
  pve-guest-disk-alert \
  /usr/local/sbin/pve-guest-disk-alert
```

Install the systemd service and timer:

```bash
install -o root -g root -m 0644 \
  pve-guest-disk-alert.service \
  /etc/systemd/system/pve-guest-disk-alert.service

install -o root -g root -m 0644 \
  pve-guest-disk-alert.timer \
  /etc/systemd/system/pve-guest-disk-alert.timer
```

Create the protected state directory:

```bash
install -d -o root -g root -m 0700 \
  /var/lib/pve-guest-disk-alert
```

Reload systemd and validate the unit files:

```bash
systemctl daemon-reload

systemd-analyze verify \
  /etc/systemd/system/pve-guest-disk-alert.service \
  /etc/systemd/system/pve-guest-disk-alert.timer
```

No output from `systemd-analyze verify` normally means the unit files are valid.

### Option B: Install from GitHub

This method downloads the current release files from the GitHub `main` branch,
installs them in their final locations, creates the protected state directory,
reloads systemd, and validates the installed script and unit files.

> Review the installer source on GitHub before running it. It runs as root and
> installs files under `/usr/local/sbin` and `/etc/systemd/system`.

#### Install without enabling the timer

Use this for the initial installation so you can test behavior before the
monitor begins running automatically:

```bash
curl -fsSL --proto '=https' --tlsv1.2 \
  [https://raw.githubusercontent.com/KittDoesntCode/pve-guest-disk-alert/main/install.sh](https://raw.githubusercontent.com/KittDoesntCode/pve-guest-disk-alert/main/install.sh) \
  | sudo bash -s -- --no-enable
```

The installer will:

- Download `pve-guest-disk-alert`, `pve-guest-disk-alert.service`, and `pve-guest-disk-alert.timer`.
- Validate the downloaded Bash script and systemd unit files.
- Back up existing installed files under `/root/pve-guest-disk-alert-backup-<timestamp>/`.
- Install the script with mode `0750`.
- Install systemd unit files with mode `0644`.
- Create `/var/lib/pve-guest-disk-alert` with mode `0700`.
- Reload systemd.
- Leave the timer disabled.

#### Test the monitor

First run a broad dry run. This checks all qualifying filesystems but does not
write state or send notifications:

```bash
/usr/local/sbin/pve-guest-disk-alert \
  --threshold 1 \
  --dry-run \
  --verbose
```

Then confirm the actual production alert selection:

```bash
/usr/local/sbin/pve-guest-disk-alert \
  --threshold 90 \
  --dry-run \
  --verbose
```

Review the output before continuing. In the example environment, only LXC 108
`/mnt/hdd` should currently alert at 90%.

#### Send one real test alert

After confirming the 90% dry-run output, run the monitor once without
`--dry-run`:

```bash
/usr/local/sbin/pve-guest-disk-alert --threshold 90 --verbose
```

Confirm that the expected email and Pushover notification arrive.

Immediately run it again to confirm same-day duplicate suppression:

```bash
/usr/local/sbin/pve-guest-disk-alert --threshold 90 --verbose
```

The second run should not send another alert for a filesystem that remains
above the threshold.

#### Enable the timer

After testing succeeds, enable and start the 15-minute systemd timer:

```bash
systemctl enable --now pve-guest-disk-alert.timer
```

Verify the timer and its next scheduled run:

```bash
systemctl status pve-guest-disk-alert.timer --no-pager
systemctl list-timers pve-guest-disk-alert.timer --all
```

To view monitor logs:

```bash
journalctl -u pve-guest-disk-alert.service --since today --no-pager
```

#### Re-run the installer

You can also re-run the installer without `--no-enable` to install the latest
files and enable/start the timer:

```bash
curl -fsSL --proto '=https' --tlsv1.2 \
  [https://raw.githubusercontent.com/KittDoesntCode/pve-guest-disk-alert/main/install.sh](https://raw.githubusercontent.com/KittDoesntCode/pve-guest-disk-alert/main/install.sh) \
  | sudo bash
```

For upgrades where the timer is already enabled, use `--refresh`. This
reinstalls and validates the latest files while preserving the timer's existing
enabled and active state:

```bash
curl -fsSL --proto '=https' --tlsv1.2 \
  [https://raw.githubusercontent.com/KittDoesntCode/pve-guest-disk-alert/main/install.sh](https://raw.githubusercontent.com/KittDoesntCode/pve-guest-disk-alert/main/install.sh) \
  | sudo bash -s -- --refresh
```

## Configuration

Edit the installed script:

```bash
nano /usr/local/sbin/pve-guest-disk-alert
```

The normal configuration section is near the top of the file:

```bash
DEFAULT_THRESHOLD=90
TIME_ZONE='America/New_York'
QUIET_START_HOUR=0
QUIET_END_HOUR=7
MONITOR_HOST_FILESYSTEMS=true
IGNORE_GUEST_IDS=()
ALLOW_GUEST_IDS=()
GUEST_COMMAND_TIMEOUT=30
```

### Alert threshold

The default threshold is 90%.

```bash
DEFAULT_THRESHOLD=90
```

A filesystem alerts when utilization is greater than or equal to the threshold.

### Quiet hours

The default behavior suppresses notifications from midnight through 06:59 in `America/New_York`.

```bash
TIME_ZONE='America/New_York'
QUIET_START_HOUR=0
QUIET_END_HOUR=7
```

A timer run at 07:00 may send pending alerts and recovery messages.

To disable quiet hours:

```bash
QUIET_START_HOUR=0
QUIET_END_HOUR=0
```

To suppress notifications from 22:00 through 06:59:

```bash
QUIET_START_HOUR=22
QUIET_END_HOUR=7
```

The script still records disk state during quiet hours. It sends queued new alerts, reminders, and recovery messages during the next permitted run.

### Guest filtering

Ignore specific guest IDs:

```bash
IGNORE_GUEST_IDS=(111)
```

Monitor only an explicit list of guest IDs:

```bash
ALLOW_GUEST_IDS=(100 101 102 104 105 108 109 110 111)
```

When `ALLOW_GUEST_IDS` is empty, all running guests are monitored except IDs in `IGNORE_GUEST_IDS`.

### Host filesystem monitoring

Host filesystem monitoring is enabled by default:

```bash
MONITOR_HOST_FILESYSTEMS=true
```

Disable it with:

```bash
MONITOR_HOST_FILESYSTEMS=false
```

## Safe testing

Always test before enabling the timer.

### Validate Bash syntax

```bash
bash -n /usr/local/sbin/pve-guest-disk-alert
echo "Syntax status: $?"
```

Expected:

```text
Syntax status: 0
```

### Test all discovered filesystems

Use a low threshold and dry-run mode. It prints what would be sent but does not write alert state and does not submit mail.

```bash
/usr/local/sbin/pve-guest-disk-alert \
  --threshold 1 \
  --dry-run \
  --verbose
```

Expected behavior:

- Running VMs and containers are checked.
- Stopped VMs and containers are skipped.
- One output block appears per guest or host with one or more qualifying filesystems.
- No email or Pushover notification is sent.
- No state files are created or changed.

### Test current production alert selection

Run a dry test at your intended production threshold:

```bash
/usr/local/sbin/pve-guest-disk-alert \
  --threshold 90 \
  --dry-run \
  --verbose
```

Review the alert list carefully before sending a real notification.

Based on the example environment used during development, this should identify only filesystems currently at or above 90%.

### Test real local mail handoff

After reviewing dry-run output, run once without `--dry-run`:

```bash
/usr/local/sbin/pve-guest-disk-alert --threshold 90 --verbose
```

This creates monitor state and hands off actual alerts to local `sendmail`.

Immediately run it again:

```bash
/usr/local/sbin/pve-guest-disk-alert --threshold 90 --verbose
```

Expected: no duplicate alert for a filesystem that remains above threshold on the same calendar day.

If you need to reset monitor state during testing:

```bash
rm -rf /var/lib/pve-guest-disk-alert
install -d -o root -g root -m 0700 /var/lib/pve-guest-disk-alert
```

> Resetting state causes all currently high filesystems to be treated as new conditions on the next non-dry run.

## Enable the systemd timer

After manual testing succeeds:

```bash
systemctl enable --now pve-guest-disk-alert.timer
```

Check the next scheduled activation:

```bash
systemctl list-timers pve-guest-disk-alert.timer --all
```

The timer runs every 15 minutes at:

```text
:00
:15
:30
:45
```

The timer has `Persistent=true`. If the host was off during a scheduled execution, systemd runs one catch-up check when the timer becomes active again.

## Operations and logging

Check the timer:

```bash
systemctl status pve-guest-disk-alert.timer --no-pager
```

Check the most recent service execution:

```bash
systemctl status pve-guest-disk-alert.service --no-pager
```

View monitor logs for today:

```bash
journalctl \
  -u pve-guest-disk-alert.service \
  --since today \
  --no-pager
```

Follow monitor logs live:

```bash
journalctl -u pve-guest-disk-alert.service -f
```

Run a check immediately:

```bash
systemctl start pve-guest-disk-alert.service
```

Disable scheduled checks without deleting configuration:

```bash
systemctl disable --now pve-guest-disk-alert.timer
```

## Alert behavior

| Condition | Result |
|---|---|
| Filesystem reaches or exceeds threshold | Queues an alert |
| New high condition during allowed hours | Sends an alert |
| New high condition during quiet hours | Records state and sends after quiet hours end |
| Filesystem remains high | Sends no more than one alert per calendar day |
| Filesystem returns below threshold | Queues a recovery notification |
| Recovery occurs during quiet hours | Sends recovery after quiet hours end |
| Guest is stopped | Skipped; its prior state is retained |
| QEMU Guest Agent request fails | VM is skipped for that run; a warning is logged |
| `pct df` fails | Container is skipped for that run; a warning is logged |
| Local `sendmail` handoff fails | Pending alert/recovery state remains and is retried later |
| Timer/service overlap | `flock` allows only one script instance at a time |

## Filesystem filtering

### VM filesystems

The script checks each filesystem reported by:

```bash
qm agent <vmid> get-fsinfo
```

It includes normal filesystem mounts such as:

- `/`
- `/boot`
- EFI mounts
- Guest data disks
- Unraid data mounts such as `/mnt/disk1`

It excludes:

- Filesystem types such as `tmpfs`, `proc`, `sysfs`, `overlay`, `squashfs`, and `erofs`.
- Device names matching `loop*`.
- Filesystems whose QEMU Guest Agent disk metadata reports USB backing.

### LXC filesystems

The script checks every mount returned by:

```bash
pct df <vmid>
```

This includes:

- `rootfs`
- `mp0`
- `mp1`
- Other configured Proxmox container mount points

The LXC threshold comparison uses the native decimal `Use%` value reported by `pct df`. Alert messages retain the native `Used` and `Size` values from `pct df`; they are not reconstructed from rounded display values.

### Host filesystems

The script checks persistent host filesystems returned by:

```bash
df --block-size=1
```

It excludes temporary, virtual, and pseudo-filesystems. It also excludes `/etc/pve`, normally mounted as a FUSE/pmxcfs filesystem.

## Upgrade procedure

1. Download or pull the updated repository version.
2. Review changes:
   ```bash
   git diff
   ```
3. Syntax-check the new script:
   ```bash
   bash -n pve-guest-disk-alert
   ```
4. Run a dry test:
   ```bash
   ./pve-guest-disk-alert --threshold 90 --dry-run --verbose
   ```
5. Install using the manual commands or:
   ```bash
   sudo ./install.sh
   ```
6. Confirm the timer remains enabled:
   ```bash
   systemctl is-enabled pve-guest-disk-alert.timer
   ```
7. Review the next scheduled execution:
   ```bash
   systemctl list-timers pve-guest-disk-alert.timer --all
   ```

## Uninstall

Disable the timer:

```bash
systemctl disable --now pve-guest-disk-alert.timer
```

Remove systemd unit files:

```bash
rm -f /etc/systemd/system/pve-guest-disk-alert.service
rm -f /etc/systemd/system/pve-guest-disk-alert.timer
systemctl daemon-reload
```

Remove the script:

```bash
rm -f /usr/local/sbin/pve-guest-disk-alert
```

Optionally remove retained alert state:

```bash
rm -rf /var/lib/pve-guest-disk-alert
```

Removing state means a future installation considers every currently high filesystem to be a new condition.

## Security notes

- Run installation and monitoring as root because `qm`, `pct`, host filesystem inspection, systemd, and local mail handoff require root-level access.
- Inspect repository changes before running the installer.
- Do not place Pushover application keys, user keys, webhook credentials, or SMTP credentials in the monitor script.
- Use the existing Proxmox/MTA notification configuration for delivery credentials.
- The script stores only monitoring state under:
  ```text
  /var/lib/pve-guest-disk-alert
  ```
- State files are root-owned and written with mode `0600`.
- The state directory is root-owned with mode `0700`.
- The script uses `flock` to prevent overlapping invocations.
