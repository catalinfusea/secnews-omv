#Requires -Version 5.1
<#
  Shows a Windows toast notification for an ntfy message.
  Called by "ntfy subscribe --from-config" (see client.yml).

  Security: title and message come from RSS feeds (untrusted content).
  They are NOT passed on the command line (cmd would expand %VAR%, and a title with
  quotes could inject commands). They are read straight from the environment variables
  set by ntfy and put into the XML via InnerText (automatic escaping).

  Requires Windows PowerShell 5.1 (powershell.exe). Does not work in PowerShell 7 (pwsh),
  which lacks the WinRT projection used here.
  No external dependencies. Tested on Windows 11 with ntfy CLI 2.31.1.
#>
$ErrorActionPreference = 'Stop'

function Limit-Text([string]$Text, [int]$Max) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $clean = ($Text -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', '').Trim()
    if ($clean.Length -gt $Max) { $clean = $clean.Substring(0, $Max - 1) + [char]0x2026 }
    return $clean
}

try {
    $title   = Limit-Text $env:NTFY_TITLE 120
    $message = Limit-Text $env:NTFY_MESSAGE 400
    if (-not $title)   { $title = 'SecNews' }
    if (-not $message) { $message = '(no content)' }

    # Build the XML with System.Xml; InnerText escapes < > & "
    $doc = New-Object System.Xml.XmlDocument
    $toast = $doc.CreateElement('toast')
    $visual = $doc.CreateElement('visual')
    $binding = $doc.CreateElement('binding')
    $binding.SetAttribute('template', 'ToastGeneric')
    foreach ($t in @($title, $message)) {
        $node = $doc.CreateElement('text')
        $node.InnerText = $t
        [void]$binding.AppendChild($node)
    }
    [void]$visual.AppendChild($binding)
    [void]$toast.AppendChild($visual)
    [void]$doc.AppendChild($toast)

    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

    $winrtXml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $winrtXml.LoadXml($doc.OuterXml)

    # Own AppUserModelID "SecNews", registered under HKCU (no admin needed). Shows up as a
    # separate app in Settings -> Notifications and can be added to the priority list.
    $appId = 'SecNews.Ntfy'
    $key = "HKCU:\Software\Classes\AppUserModelId\$appId"
    if (-not (Test-Path $key)) {
        New-Item -Path $key -Force | Out-Null
        New-ItemProperty -Path $key -Name DisplayName -Value 'SecNews' -PropertyType String -Force | Out-Null
    }
    $notification = [Windows.UI.Notifications.ToastNotification]::new($winrtXml)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($notification)
}
catch {
    # Minimal log, without the message content
    $logDir = Join-Path $env:LOCALAPPDATA 'secnews'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
    $line = '{0:u} toast error: {1}' -f (Get-Date), $_.Exception.GetType().FullName
    Add-Content -Path (Join-Path $logDir 'toast-errors.log') -Value $line
    exit 1
}
