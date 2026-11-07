$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$root = Split-Path $PSScriptRoot
$version = [version](Get-Content (Join-Path $root VERSION) -Raw).Trim()
$repo = 'TedInVR/VFLR_VideoFixLinkRestore'
$profiles = @(Get-Content (Join-Path $root ConversionProfiles.tsv) | ForEach-Object { ,($_ -split "`t", 3) })
$form = New-Object Windows.Forms.Form
$form.Text = "VFLR $version - Video Fix Link Restore"
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object Drawing.Size(632, 423)
$menu = New-Object Windows.Forms.MenuStrip
$helpMenu = $menu.Items.Add('Help')
$guide = $helpMenu.DropDownItems.Add('VFLR User Guide')
$guide.Add_Click({ Start-Process notepad.exe -ArgumentList (Quote-Arg (Join-Path $root 'UserGuide.txt')) })
$update = $helpMenu.DropDownItems.Add('Check for Updates...')
$update.Add_Click({ Check-Update $true })
$form.Controls.Add($menu)
$form.MainMenuStrip = $menu
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$tooltip = New-Object Windows.Forms.ToolTip
$sourcesLabel = New-Object Windows.Forms.Label
$sourcesLabel.SetBounds(18, 43, 420, 25)
$sourcesLabel.Text = 'Drop videos here, or browse for files.'
$sourcesLabel.AutoEllipsis = $true
$form.Controls.Add($sourcesLabel)
$browse = New-Object Windows.Forms.Button
$browse.Text = 'Browse...'
$browse.SetBounds(449, 39, 81, 27)
$browse.Add_Click({ Set-Sources @(Pick-Files $true) })
$form.Controls.Add($browse)
$clear = New-Object Windows.Forms.Button
$clear.Text = 'Clear'
$clear.SetBounds(537, 39, 74, 27)
$clear.Enabled = $false
$clear.Add_Click({
    $script:sources = @()
    $sourcesLabel.Text = 'Drop videos here, or browse for files.'
    $tooltip.SetToolTip($sourcesLabel, '')
    $clear.Enabled = $false
})
$form.Controls.Add($clear)
$script:sources = @()

$buttons = @()
$groups = @(
    @{ Title = 'Edit and Assemble'; X = 18; Y = 79; Tools = @('Split Movie','Join Parts','Link Videos') },
    @{ Title = 'Picture and Format'; X = 322; Y = 79; Tools = @('Upscale Video','Convert Video','Change Aspect or Stereo Layout') },
    @{ Title = 'Audio and Subtitles'; X = 18; Y = 226; Tools = @('Extract or Remove Audio','Add Subtitles') },
    @{ Title = 'Inspect and Download'; X = 322; Y = 226; Tools = @('MediaInfo','Download Online') }
)
foreach ($group in $groups) {
    $box = New-Object Windows.Forms.GroupBox
    $box.Text = $group.Title
    $box.SetBounds($group.X, $group.Y, 291, (31 + $group.Tools.Count * 35))
    for ($i = 0; $i -lt $group.Tools.Count; $i++) {
        $button = New-Object Windows.Forms.Button
        $button.Text = $group.Tools[$i]
        $button.SetBounds(12, (24 + $i * 35), 264, 28)
        $button.Add_Click({ param($sender, $eventArgs) Choose-Operation $sender.Text })
        $box.Controls.Add($button)
        $buttons += $button
    }
    $form.Controls.Add($box)
}

$banner = New-Object Windows.Forms.Panel
$banner.SetBounds(18, 353, 595, 47)
$banner.BackColor = [Drawing.Color]::FromArgb(235,235,235)
$status = New-Object Windows.Forms.Label
$status.SetBounds(11, 14, 450, 23)
$status.Text = 'Ready. Drop a video or choose a tool.'
$status.ForeColor = [Drawing.Color]::FromArgb(35,35,35)
$banner.Controls.Add($status)
$reveal = New-Object Windows.Forms.Button
$reveal.Text = 'Show Result'
$reveal.SetBounds(482, 10, 102, 27)
$reveal.Visible = $false
$reveal.Add_Click({
    if ($script:resultPath) {
        Start-Process explorer.exe -ArgumentList ('/select,' + (Quote-Arg $script:resultPath))
    }
})
$banner.Controls.Add($reveal)
$form.Controls.Add($banner)

function Set-Sources([string[]]$paths) {
    if ($script:job -or $script:queued) { return }
    $valid = @($paths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -Unique)
    if (-not $valid.Count) { return }
    $script:sources = $valid
    $sourcesLabel.Text = if ($valid.Count -eq 1) { [IO.Path]::GetFileName($valid[0]) } else { "$($valid.Count) files loaded" }
    $tooltip.SetToolTip($sourcesLabel, ($valid -join "`n"))
    $clear.Enabled = $true
}

function Enable-FileDrop($control) {
    $control.AllowDrop = $true
    $control.Add_DragEnter({
        param($sender, $eventArgs)
        if (-not $script:job -and -not $script:queued -and $eventArgs.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
            $eventArgs.Effect = [Windows.Forms.DragDropEffects]::Copy
        }
    })
    $control.Add_DragDrop({
        param($sender, $eventArgs)
        if ($eventArgs.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
            Set-Sources ($eventArgs.Data.GetData([Windows.Forms.DataFormats]::FileDrop))
        }
    })
    foreach ($child in $control.Controls) { Enable-FileDrop $child }
}
Enable-FileDrop $form

function Notice($title, $message) {
    [void][Windows.Forms.MessageBox]::Show($form, $message, $title)
}
function Confirm($title, $message) {
    [Windows.Forms.MessageBox]::Show($form, $message, $title, 'OKCancel') -eq 'OK'
}
function Pick-Files([bool]$multiple, [string]$directory) {
    $dialog = New-Object Windows.Forms.OpenFileDialog
    try {
        $dialog.Multiselect = $multiple
        if ($directory) { $dialog.InitialDirectory = $directory }
        $dialog.Filter = 'All files|*.*'
        if ($dialog.ShowDialog($form) -eq 'OK') { $dialog.FileNames }
    } finally { $dialog.Dispose() }
}
function Pick-Sources([bool]$multiple) {
    if (-not $script:sources.Count) { Pick-Files $multiple; return }
    if ($multiple) {
        if ($script:sources.Count -ge 2) { $script:sources; return }
        $extras = @(Pick-Files $true ([IO.Path]::GetDirectoryName($script:sources[0])))
        if ($extras.Count) { ($script:sources + $extras) | Select-Object -Unique }
        return
    }
    if ($script:sources.Count -eq 1) { $script:sources[0]; return }
    $choice = Pick-Index 'Choose a loaded file' $script:sources
    if ($choice -ge 0) { $script:sources[$choice] }
}

function Pick-Output($file, $extension, $suffix) {
    $dialog = New-Object Windows.Forms.SaveFileDialog
    try {
        $dialog.InitialDirectory = [IO.Path]::GetDirectoryName($file)
        $dialog.FileName = [IO.Path]::GetFileNameWithoutExtension($file) + " $suffix.$extension"
        $dialog.Filter = "$extension files|*.$extension"
        $dialog.DefaultExt = $extension
        $dialog.OverwritePrompt = $false
        if ($dialog.ShowDialog($form) -eq 'OK') { $dialog.FileName }
    } finally { $dialog.Dispose() }
}
function Pick-Index($title, [string[]]$items, [int]$default = 0) {
    $dialog = New-Object Windows.Forms.Form
    try {
        $dialog.Text = $title
        $dialog.StartPosition = 'CenterParent'
        $dialog.ClientSize = New-Object Drawing.Size(560, 105)
        $combo = New-Object Windows.Forms.ComboBox
        $combo.DropDownStyle = 'DropDownList'
        $combo.SetBounds(12, 12, 530, 25)
        $combo.Items.AddRange($items)
        $combo.SelectedIndex = $default
        $ok = New-Object Windows.Forms.Button
        $ok.Text = 'Continue'
        $ok.DialogResult = 'OK'
        $ok.SetBounds(370, 59, 80, 27)
        $cancel = New-Object Windows.Forms.Button
        $cancel.Text = 'Cancel'
        $cancel.DialogResult = 'Cancel'
        $cancel.SetBounds(462, 59, 80, 27)
        $dialog.Controls.AddRange(@($combo,$ok,$cancel))
        $dialog.AcceptButton = $ok
        $dialog.CancelButton = $cancel
        if ($dialog.ShowDialog($form) -eq 'OK') { return $combo.SelectedIndex }
        return -1
    } finally { $dialog.Dispose() }
}
function Text-Input($title, $value = '') {
    $dialog = New-Object Windows.Forms.Form
    try {
        $dialog.Text = $title
        $dialog.StartPosition = 'CenterParent'
        $dialog.ClientSize = New-Object Drawing.Size(500, 108)
        $field = New-Object Windows.Forms.TextBox
        $field.Text = $value
        $field.SetBounds(10, 12, 475, 25)
        $ok = New-Object Windows.Forms.Button
        $ok.Text = 'Continue'
        $ok.DialogResult = 'OK'
        $ok.SetBounds(310, 60, 80, 27)
        $cancel = New-Object Windows.Forms.Button
        $cancel.Text = 'Cancel'
        $cancel.DialogResult = 'Cancel'
        $cancel.SetBounds(400, 60, 80, 27)
        $dialog.Controls.AddRange(@($field,$ok,$cancel))
        $dialog.AcceptButton = $ok
        $dialog.CancelButton = $cancel
        if ($dialog.ShowDialog($form) -eq 'OK') { $field.Text.Trim() }
    } finally { $dialog.Dispose() }
}
$layoutLabels = @('Full Side-by-Side','Half Side-by-Side','Full Over-Under','Half Over-Under')
$layoutCodes = @('sbsl','sbs2l','abl','ab2l')
function Quote-Arg([string]$value) {
    # Windows CreateProcess quoting, including trailing backslashes.
    '"' + (($value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}
function Find-Tool([string]$name) {
    $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    throw "$name is required. See Help > VFLR User Guide for installation."
}
function Start-Engine([string[]]$arguments, [string]$reportName) {
    $process = New-Object Diagnostics.Process
    $info = $process.StartInfo
    $info.FileName = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
    if (-not (Test-Path -LiteralPath $info.FileName)) {
        $info.FileName = Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe'
    }
    if (-not (Test-Path -LiteralPath $info.FileName)) { throw 'Git for Windows is required. See the VFLR User Guide.' }
    if ($arguments[0] -eq 'info') {
        $info.EnvironmentVariables['VFLR_MEDIAINFO'] = (Find-Tool 'mediainfo.exe').Replace('\','/')
    } else {
        [void](Find-Tool 'ffmpeg.exe')
        [void](Find-Tool 'ffprobe.exe')
        if ($arguments[0] -eq 'download') {
            $info.EnvironmentVariables['VFLR_YTDLP'] = (Find-Tool 'yt-dlp.exe').Replace('\','/')
        }
        if ($arguments[0] -eq 'subtitles' -and ($arguments[3] -ne 'flat' -or $arguments[5] -eq 'online')) {
            $info.EnvironmentVariables['VFLR_PYTHON'] = (Find-Tool 'python.exe').Replace('\','/')
            $info.EnvironmentVariables['VFLR_SUBTITLE_CONFIG'] = Join-Path (Split-Path $root) 'OpenSubtitles.json'
        }
    }
    $scriptFile = (Join-Path $PSScriptRoot 'engine-windows.sh').Replace('\','/')
    $info.Arguments = (@('--noprofile','--norc',$scriptFile) + $arguments | ForEach-Object { Quote-Arg $_ }) -join ' '
    $info.CreateNoWindow = $true
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    [void]$process.Start()
    $script:job = @{
        Process = $process
        Output = $process.StandardOutput.ReadToEndAsync()
        Errors = $process.StandardError.ReadToEndAsync()
        Report = $reportName
    }
    foreach ($button in $buttons) { $button.Enabled = $false }
    $browse.Enabled = $false
    $clear.Enabled = $false
    $script:resultPath = $null
    $reveal.Visible = $false
    $messages = @{
        split='Splitting movie'; join='Joining parts'; link='Linking videos'; upscale='Upscaling video'
        convert='Converting video'; download='Downloading media'; audio='Processing audio'
        subtitles='Preparing subtitles'; layout='Changing video layout'; info='Reading media information'
    }
    $status.Text = $messages[$arguments[0]] + '... Please wait.'
    $banner.BackColor = [Drawing.Color]::FromArgb(199,224,255)
    $script:pulse = [Diagnostics.Stopwatch]::StartNew()
    $poll.Start()
}
function Show-Report($title, $report) {
    $viewer = New-Object Windows.Forms.Form
    $viewer.Text = "MediaInfo - $title"
    $viewer.ClientSize = New-Object Drawing.Size(820, 575)
    $text = New-Object Windows.Forms.RichTextBox
    $text.ReadOnly = $true
    $text.Dock = 'Fill'
    $text.Font = New-Object Drawing.Font('Consolas', 10)
    $text.Text = $report
    $copy = New-Object Windows.Forms.Button
    $copy.Text = 'Copy Report'
    $copy.Dock = 'Bottom'
    $copy.Tag = $report
    $copy.Add_Click({ param($sender, $eventArgs) [Windows.Forms.Clipboard]::SetText([string]$sender.Tag) })
    $viewer.Controls.AddRange(@($text,$copy))
    $viewer.Show($form)
}
$script:job = $null
$poll = New-Object Windows.Forms.Timer
$poll.Interval = 65
$poll.Add_Tick({
    if (-not $job.Process.HasExited -or -not $job.Output.IsCompleted -or -not $job.Errors.IsCompleted) {
        if (-not [Windows.Forms.SystemInformation]::HighContrast) {
            $phase = (1 - [Math]::Cos($script:pulse.Elapsed.TotalSeconds * 3)) / 2
            $banner.BackColor = [Drawing.Color]::FromArgb([int](199 - 50 * $phase), [int](224 - 25 * $phase), 255)
        }
        return
    }
    $poll.Stop()
    $result = $job.Output.Result.Trim()
    $errors = $job.Errors.Result.Trim()
    $report = $job.Report
    $code = $job.Process.ExitCode
    $job.Process.Dispose()
    $script:job = $null
    foreach ($button in $buttons) { $button.Enabled = -not $script:queued }
    $browse.Enabled = -not $script:queued
    $clear.Enabled = (-not $script:queued -and $script:sources.Count -gt 0)
    if ($code -ne 0 -or -not $result) {
        $banner.BackColor = [Drawing.Color]::FromArgb(255,211,209)
        $status.Text = 'Processing failed.'
        if (-not $errors) { $errors = 'The selected file could not be processed.' }
        Notice 'VFLR' $errors
    } else {
        $banner.BackColor = [Drawing.Color]::FromArgb(201,237,209)
        if ($report) {
            $status.Text = 'Finished. MediaInfo report is ready.'
            Show-Report $report $result
        } else {
            $script:resultPath = $result
            $status.Text = 'Finished. Your result is ready.'
            $reveal.Visible = $true
        }
    }
})
function Choose-Operation($operation) {
    try {
        if ($operation -eq 'Download Online') {
            $url = Text-Input 'Paste an online video page URL'
            if (-not $url) { return }
            $choice = Pick-Index 'Download Online' @('Video (MKV)','Audio Only (MP3)')
            if ($choice -lt 0) { return }
            $extension = @('mkv','mp3')[$choice]
            $save = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Online.mp4'
            $destination = Pick-Output $save $extension 'Download'
            if ($destination) { Start-Engine @('download',@('video','audio')[$choice],$url,$destination) }
            return
        }
        $multiple = $operation -in @('Join Parts','Link Videos')
        $files = @(Pick-Sources $multiple)
        if (-not $files.Count) { return }
        if ($multiple -and $files.Count -lt 2) { Notice $operation 'Choose at least two files.'; return }
        $file = $files[0]
        switch ($operation) {
            'Split Movie' {
                $choice = Pick-Index 'Number of roughly equal parts' (2..12 | ForEach-Object { "$_" }) 2
                if ($choice -ge 0) { Start-Engine @('split', "$($choice + 2)", $file) }
            }
            'Join Parts' {
                $ordered = @($files | Sort-Object { [regex]::Replace([IO.Path]::GetFileName($_), '\d+', { param($m) $m.Value.PadLeft(20, '0') }) })
                if (Confirm 'Join Parts' ($ordered -join "`n")) { Start-Engine (@('join') + $ordered) }
            }
            'Link Videos' {
                $remaining = New-Object 'System.Collections.Generic.List[string]'
                $remaining.AddRange([string[]]@($files | Sort-Object))
                $ordered = @()
                while ($remaining.Count -gt 1) {
                    $choice = Pick-Index "Choose clip $($ordered.Count + 1) of $($files.Count)" $remaining.ToArray()
                    if ($choice -lt 0) { return }
                    $ordered += $remaining[$choice]
                    $remaining.RemoveAt($choice)
                }
                $ordered += $remaining[0]
                $destination = Pick-Output $ordered[0] 'mp4' 'Linked'
                if ($destination) { Start-Engine (@('link',$destination) + $ordered) }
            }
            'Upscale Video' {
                $choice = Pick-Index 'Upscale Video' @('1080p','4K')
                if ($choice -lt 0) { return }
                $label = @('1080p','4K')[$choice]
                $height = @('1080','2160')[$choice]
                $destination = Pick-Output $file 'mp4' $label
                if ($destination) { Start-Engine @('upscale',$height,$file,$destination) }
            }
            'MediaInfo' {
                $choice = Pick-Index 'MediaInfo report view' @('Summary','Full Details','JSON')
                if ($choice -ge 0) { Start-Engine @('info',@('summary','full','json')[$choice],$file) ([IO.Path]::GetFileName($file)) }
            }
            'Extract or Remove Audio' {
                $choice = Pick-Index 'Extract first audio track or remove all audio' @('MP3','M4A','FLAC','WAV','Remove audio (MKV)')
                if ($choice -lt 0) { return }
                $format = @('mp3','m4a','flac','wav','silent')[$choice]
                $extension = @('mp3','m4a','flac','wav','mkv')[$choice]
                $suffix = if ($format -eq 'silent') { 'Silent' } else { 'Audio' }
                $destination = Pick-Output $file $extension $suffix
                if ($destination) { Start-Engine @('audio',$format,$file,$destination) }
            }
            'Add Subtitles' {
                $choice = Pick-Index 'Choose the video layout' (@('2D') + $layoutLabels)
                if ($choice -lt 0) { return }
                $layout = (@('flat') + $layoutCodes)[$choice]
                $method = Pick-Index 'Choose the subtitle source' @('Local text subtitle','Search OpenSubtitles')
                if ($method -lt 0) { return }
                $depth = '0'
                if ($choice -gt 0) {
                    $level = Pick-Index '3D subtitle depth' @('At the screen','Slightly forward','More forward','Most forward') 1
                    if ($level -lt 0) { return }
                    $depth = @('0','0.8','1.5','2.5')[$level]
                }
                if ($method -eq 0) {
                    $caption = @(Pick-Files $false)
                    if (-not $caption.Count) { return }
                    $inputArgs = @('local',$caption[0])
                } else {
                    $title = Text-Input 'Movie title and year, or show title and S01E01' ([IO.Path]::GetFileNameWithoutExtension($file))
                    if (-not $title) { return }
                    $language = Text-Input 'Subtitle language code' 'en'
                    if (-not $language) { return }
                    $inputArgs = @('online',$title,$language)
                }
                $destination = Pick-Output $file 'mkv' 'Subtitled'
                if ($destination) { Start-Engine (@('subtitles',$file,$destination,$layout,$depth) + $inputArgs) }
            }
            'Change Aspect or Stereo Layout' {
                $choice = Pick-Index 'Change Aspect or Stereo Layout' @('2D aspect ratio (pad to fit)','3D stereo layout')
                if ($choice -lt 0) { return }
                $from = 'flat'
                if ($choice -eq 0) {
                    $ratios = @('16:9','4:3','1:1','9:16')
                    $toIndex = Pick-Index 'Choose an aspect ratio' $ratios
                    if ($toIndex -lt 0) { return }
                    $to = $ratios[$toIndex]
                } else {
                    $fromIndex = Pick-Index 'Current stereo layout (left eye first)' $layoutLabels
                    if ($fromIndex -lt 0) { return }
                    $toIndex = Pick-Index 'Output stereo layout' $layoutLabels
                    if ($toIndex -lt 0 -or $toIndex -eq $fromIndex) { return }
                    $from = $layoutCodes[$fromIndex]
                    $to = $layoutCodes[$toIndex]
                }
                $destination = Pick-Output $file 'mkv' 'Reframed'
                if ($destination) { Start-Engine @('layout',$from,$to,$file,$destination) }
            }
            'Convert Video' {
                $choice = Pick-Index 'Convert Video - choose the output format' @($profiles | ForEach-Object { $_[1] })
                if ($choice -lt 0) { return }
                $extension = $profiles[$choice][0]
                $destination = Pick-Output $file $extension 'Converted'
                if ($destination) { Start-Engine @('convert',$extension,$file,$destination) }
            }
        }
    } catch { Notice 'VFLR' $_.Exception.Message }
}
$script:queued = $false
function Check-Update([bool]$manual) {
    if ($script:queued) { if ($manual) { Notice 'VFLR' 'Close VFLR to install the update.' }; return }
    if ($job) { if ($manual) { Notice 'VFLR' 'Wait until the current operation finishes.' }; return }
    try {
        $commit = (Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/commits/main" -TimeoutSec 12).sha
        if ($commit -notmatch '^[a-f0-9]{40}$') { throw 'GitHub did not return a valid version reference.' }
        $release = [version](Invoke-RestMethod -Uri "https://raw.githubusercontent.com/$repo/$commit/VERSION" -TimeoutSec 12).Trim()
        if ($release -le $version) { if ($manual) { Notice 'VFLR' "VFLR $version is up to date." }; return }
        if (-not (Confirm 'VFLR Update' "Version $release is available. Queue installation for when VFLR closes?")) { return }
        $install = Split-Path $root
        $helper = Join-Path $install ('Update-' + [guid]::NewGuid() + '.ps1')
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Install-VFLR.ps1') -Destination $helper
        $args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $(Quote-Arg $helper) -ParentId $PID -Commit $commit -Version $release"
        try { Start-Process powershell.exe -ArgumentList $args -WindowStyle Hidden -ErrorAction Stop }
        catch { Remove-Item -LiteralPath $helper -Force; throw }
        $script:queued = $true
        foreach ($button in $buttons) { $button.Enabled = $false }
        $browse.Enabled = $false
        $clear.Enabled = $false
        $status.Text = 'Update queued. Close VFLR to install it.'
    } catch { if ($manual) { Notice 'Update check failed' $_.Exception.Message } }
}
$updates = New-Object Windows.Forms.Timer
$updates.Interval = 900000
$updates.Add_Tick({ Check-Update $false })
$form.Add_Shown({ $updates.Start() })
$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($job) { $eventArgs.Cancel = $true; Notice 'VFLR' 'Wait for the current operation to finish before closing.' }
})
[void]$form.ShowDialog()
