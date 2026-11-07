param(
    [ValidatePattern('^[a-f0-9]{40}$')][string]$Commit,
    [version]$Version,
    [int]$ParentId
)
$ErrorActionPreference = 'Stop'
$repo = 'TedInVR/TVT-Teds_Video_Tool'
$install = Join-Path $env:LOCALAPPDATA 'Programs\VFLR'
$current = Join-Path $install 'App'
$stage = Join-Path $install ('.stage-' + [guid]::NewGuid())
$lock = $null
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [void](New-Item -ItemType Directory -Path $install -Force)
    $lock = [IO.File]::Open((Join-Path $install '.install-lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    if (-not $Commit) {
        $Commit = (Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/commits/main" -TimeoutSec 20).sha
        if ($Commit -notmatch '^[a-f0-9]{40}$') { throw 'Invalid GitHub commit.' }
        $Version = [version](Invoke-RestMethod -Uri "https://raw.githubusercontent.com/$repo/$Commit/VERSION" -TimeoutSec 20).Trim()
    }
    [void](New-Item -ItemType Directory -Path $stage)
    $archive = Join-Path $stage 'source.zip'
    Invoke-WebRequest -UseBasicParsing -Uri "https://codeload.github.com/$repo/zip/$Commit" -OutFile $archive -TimeoutSec 120
    $expanded = Join-Path $stage 'source'
    Expand-Archive -LiteralPath $archive -DestinationPath $expanded
    $source = @(Get-ChildItem -LiteralPath $expanded -Directory)
    if ($source.Count -ne 1) { throw 'Unexpected TVT source package.' }
    $candidate = $source[0].FullName
    if ([version](Get-Content -LiteralPath (Join-Path $candidate 'VERSION') -Raw).Trim() -ne $Version) {
        throw 'The downloaded TVT version did not match the update.'
    }
    if ($ParentId) {
        $parent = Get-Process -Id $ParentId -ErrorAction SilentlyContinue
        if ($parent) { $parent.WaitForExit() }
    }
    $other = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains((Join-Path $current 'windows\VFLR.ps1')) }
    if ($other) { throw 'Close TVT before installing.' }
    $previous = Join-Path $stage 'Previous'
    if (Test-Path -LiteralPath $current) { Move-Item -LiteralPath $current -Destination $previous }
    try { Move-Item -LiteralPath $candidate -Destination $current }
    catch {
        if (Test-Path -LiteralPath $previous) {
            try { Move-Item -LiteralPath $previous -Destination $current }
            catch { $backup = $previous; $stage = $null; throw "The previous version is at $backup." }
        }
        throw
    }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) "Ted's Video Tool.lnk"))
    $shortcut.TargetPath = Join-Path $PSHOME 'powershell.exe'
    $shortcut.Arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $current 'windows\VFLR.ps1') + '"'
    $shortcut.WorkingDirectory = $current
    $shortcut.IconLocation = (Join-Path $current 'windows\VFLR.ico') + ',0'
    $shortcut.Save()
    $legacyShortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'VFLR.lnk'
    if (Test-Path -LiteralPath $legacyShortcut) { Remove-Item -LiteralPath $legacyShortcut -ErrorAction SilentlyContinue }
    if (-not $ParentId) { Write-Host "Installed TVT $Version. Open Ted's Video Tool from the Start menu." }
} catch {
    if (-not $ParentId) { throw }
    Add-Type -AssemblyName System.Windows.Forms
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'TVT update failed')
} finally {
    if ($stage -and (Test-Path -LiteralPath $stage)) { Remove-Item -LiteralPath $stage -Recurse -Force }
    if ($lock) { $lock.Dispose() }
    if ($ParentId -and $PSCommandPath) { Remove-Item -LiteralPath $PSCommandPath -Force }
}
