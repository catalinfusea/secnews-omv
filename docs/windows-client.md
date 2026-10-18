# Windows client

Native Windows toast notifications for ntfy, using only what ships with Windows: the ntfy CLI, Windows PowerShell 5.1 and Task Scheduler. No third-party notification tools.

Tested on Windows 11 with ntfy CLI 2.31.1.

## 1. Install the ntfy CLI

1. Download `ntfy_<version>_windows_amd64.zip` from the official releases page: https://github.com/binwiederhier/ntfy/releases
2. Verify the archive against the release's `checksums.txt`:
   ```powershell
   certutil -hashfile .\ntfy_<version>_windows_amd64.zip SHA256
   ```
3. Extract `ntfy.exe` to a folder of your choice, e.g. `C:\Tools\ntfy\`.

A fresh, unsigned release may be flagged by antivirus heuristics. Verify the hash first; if you add an exclusion, scope it to that exact file, not a whole folder.

## 2. Copy the files

```powershell
New-Item -ItemType Directory -Force "$env:LOCALAPPDATA\secnews" | Out-Null
Copy-Item .\client\windows\ntfy-toast.ps1 "$env:LOCALAPPDATA\secnews\"

New-Item -ItemType Directory -Force "$env:APPDATA\ntfy" | Out-Null
Copy-Item .\client\windows\client.yml "$env:APPDATA\ntfy\client.yml"
notepad "$env:APPDATA\ntfy\client.yml"   # set the OMV host and the reader's token
```

The config file must be named exactly `client.yml` (enable "File name extensions" in Explorer to be sure).

## 3. Test

```powershell
# toast script on its own
$env:NTFY_TITLE = 'Test'; $env:NTFY_MESSAGE = 'Escaping check <b>&"'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\secnews\ntfy-toast.ps1"

# subscriber in the foreground
& "C:\Tools\ntfy\ntfy.exe" subscribe --debug --from-config
```

Then publish from the OMV host (note the full URL; a bare topic name goes to ntfy.sh):

```bash
docker compose exec ntfy ntfy publish --token <publisher token> --title Test http://localhost/secnews "Hello"
```

The debug output should show `Dispatching received message` and `Running command`, and a toast should appear.

## 4. Start at logon (Task Scheduler)

```powershell
$ntfy = 'C:\Tools\ntfy\ntfy.exe'
# conhost --headless: no console window. With Windows Terminal as the default terminal,
# powershell -WindowStyle Hidden still shows a window, and closing it kills the client.
$action = New-ScheduledTaskAction -Execute 'conhost.exe' `
  -Argument "--headless `"$ntfy`" subscribe --from-config"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
  -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'SecNews-ntfy' -Action $action -Trigger $trigger -Settings $settings
Start-ScheduledTask -TaskName 'SecNews-ntfy'
```

- Run it **only when the user is logged on**. "Run whether user is logged on or not" runs in session 0, where toasts can't be shown.
- Check that it runs headless:
  ```powershell
  $p = Get-CimInstance Win32_Process -Filter "Name='ntfy.exe'"
  Get-CimInstance Win32_Process -Filter "ProcessId=$($p.ParentProcessId)" | Select Name, CommandLine
  ```
  The parent should be `conhost.exe --headless ...`.
- `conhost.exe --headless` is not officially documented by Microsoft.

## Do Not Disturb and the "SecNews" app

The toast script registers its own AppUserModelID, `SecNews.Ntfy`, under `HKCU\Software\Classes\AppUserModelId` (no admin rights). After the first toast, **SecNews** shows up as a separate app in Settings → System → Notifications, with its own on/off switch, and it can be added to the priority list.

Observed on Windows 11: with **Do Not Disturb** on, toasts go to Notification Center without a banner, even with SecNews on the priority list. With DND off, banners appear.

## Security notes

- Titles and messages come from RSS feeds, so they are untrusted. The ntfy CLI runs commands through `cmd` on Windows, which expands `%VAR%`; putting `%NTFY_MESSAGE%` on a command line would let a crafted title break out of the quoting. Instead, the script reads `NTFY_TITLE` / `NTFY_MESSAGE` from the environment and builds the toast XML with `InnerText` (automatic escaping). Control characters are stripped and lengths are capped.
- Errors go to `%LOCALAPPDATA%\secnews\toast-errors.log`, exception type only, never message content.
- `-ExecutionPolicy Bypass` applies to that one process; the system policy is unchanged.
- The token in `client.yml` belongs to the read-only user.
