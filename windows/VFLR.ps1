$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName @('System.Windows.Forms','System.Drawing')
[System.Windows.Forms.Application]::EnableVisualStyles()
$root = Split-Path $PSScriptRoot
$version = [version](Get-Content (Join-Path $root VERSION) -Raw).Trim()
$repo = 'TedInVR/TVT-Teds_Video_Tool'
$profiles = @(Get-Content (Join-Path $root ConversionProfiles.tsv) | ForEach-Object { ,($_ -split "`t", 3) })
$form = New-Object Windows.Forms.Form
$form.Text = "Ted's Video Tool (TVT) $version"
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object Drawing.Size(632, 543)
$menu = New-Object Windows.Forms.MenuStrip
$appsMenu = $menu.Items.Add('Apps')
$helpMenu = $menu.Items.Add('Help')
$guide = $helpMenu.DropDownItems.Add('TVT User Guide')
$guide.Add_Click({ Start-Process notepad.exe -ArgumentList (Quote-Arg (Join-Path $root 'UserGuide.txt')) })
$update = $helpMenu.DropDownItems.Add('Check for Updates...')
$update.Add_Click({ Check-Update $true })
$form.Controls.Add($menu)
$form.MainMenuStrip = $menu
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Icon = New-Object Drawing.Icon((Join-Path $PSScriptRoot 'VFLR.ico'))
$badge = New-Object Windows.Forms.PictureBox
$badge.Image = [Drawing.Image]::FromFile((Join-Path $root 'TVT.png'))
$badge.SizeMode = 'Zoom'
$badge.AccessibleName = 'TVT'
$badge.SetBounds(18, 28, 46, 46)
$form.Controls.Add($badge)
$heading = New-Object Windows.Forms.Label
$heading.Text = "Ted's Video Tool"
$heading.Font = New-Object Drawing.Font('Segoe UI', 16, [Drawing.FontStyle]::Bold)
$heading.TextAlign = 'MiddleLeft'
$heading.SetBounds(76, 26, 536, 29)
$form.Controls.Add($heading)
$subtitle = New-Object Windows.Forms.Label
$subtitle.Text = 'for 2D, 3D, and VR'
$subtitle.Font = New-Object Drawing.Font('Segoe UI', 9)
$subtitle.ForeColor = [Drawing.SystemColors]::GrayText
$subtitle.TextAlign = 'MiddleLeft'
$subtitle.SetBounds(76, 55, 536, 20)
$form.Controls.Add($subtitle)
$tooltip = New-Object Windows.Forms.ToolTip
$sourcesLabel = New-Object Windows.Forms.Label
$sourcesLabel.SetBounds(18, 91, 420, 25)
$sourcesLabel.Text = 'Drop videos here, or browse for files.'
$sourcesLabel.AutoEllipsis = $true
$form.Controls.Add($sourcesLabel)
$browse = New-Object Windows.Forms.Button
$browse.Text = 'Browse...'
$browse.SetBounds(449, 87, 81, 27)
$browse.Add_Click({ Set-Sources @(Pick-Files $true) })
$form.Controls.Add($browse)
$clear = New-Object Windows.Forms.Button
$clear.Text = 'Clear'
$clear.SetBounds(537, 87, 74, 27)
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
    @{ Title = 'Edit and Assemble'; X = 18; Y = 127; Tools = @('Trim Clip','Split Movie','Join Parts','Link Videos','Import Disc Backup') },
    @{ Title = 'Picture and Format'; X = 322; Y = 127; Tools = @('Upscale Video','Convert Video','Change Aspect or Stereo Layout','Change Speed') },
    @{ Title = 'Audio and Subtitles'; X = 18; Y = 345; Tools = @('Extract or Remove Audio','Add Subtitles') },
    @{ Title = 'Inspect and Download'; X = 322; Y = 345; Tools = @('MediaInfo','Download Online') }
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
$banner.SetBounds(18, 472, 595, 47)
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
    $valid = @($paths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique)
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

function Pick-Output($file, $extension, $suffix, $owner = $form) {
    $dialog = New-Object Windows.Forms.SaveFileDialog
    try {
        $dialog.InitialDirectory = [IO.Path]::GetDirectoryName($file)
        $label = if ($suffix) { " $suffix" } else { '' }
        $dialog.FileName = [IO.Path]::GetFileNameWithoutExtension($file) + "$label.$extension"
        $dialog.Filter = "$extension files|*.$extension"
        $dialog.DefaultExt = $extension
        $dialog.OverwritePrompt = $false
        if ($dialog.ShowDialog($owner) -eq 'OK') { $dialog.FileName }
    } finally { $dialog.Dispose() }
}
function Pick-Index($title, [string[]]$items, [int]$default = 0, $owner = $form) {
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
        if ($dialog.ShowDialog($owner) -eq 'OK') { return $combo.SelectedIndex }
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
    throw "$name is required. See Help > TVT User Guide for installation."
}
function New-EngineProcess([string[]]$arguments) {
    $process = New-Object Diagnostics.Process
    $info = $process.StartInfo
    if ($arguments[0] -in @('disc-scan','disc-import')) {
        $info.FileName = Find-Tool 'python.exe'
        $info.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
        $info.Arguments = (@((Join-Path $root 'disc_tools.py')) + $arguments | ForEach-Object { Quote-Arg $_ }) -join ' '
    } else {
        $info.FileName = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
        if (-not (Test-Path -LiteralPath $info.FileName)) {
            $info.FileName = Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe'
        }
        if (-not (Test-Path -LiteralPath $info.FileName)) { throw 'Git for Windows is required. See the TVT User Guide.' }
        if ($arguments[0] -eq 'info') {
            $info.EnvironmentVariables['VFLR_MEDIAINFO'] = (Find-Tool 'mediainfo.exe').Replace('\','/')
        } else {
            [void](Find-Tool 'ffmpeg.exe')
            [void](Find-Tool 'ffprobe.exe')
            if ($arguments[0] -eq 'download') {
                $info.EnvironmentVariables['VFLR_YTDLP'] = (Find-Tool 'yt-dlp.exe').Replace('\','/')
            }
            if ($arguments[0] -eq 'subtitles' -and ($arguments[3] -ne 'flat' -or $arguments[5] -ne 'local')) {
                $info.EnvironmentVariables['VFLR_PYTHON'] = (Find-Tool 'python.exe').Replace('\','/')
                $info.EnvironmentVariables['VFLR_SUBTITLE_CONFIG'] = Join-Path (Split-Path $root) 'OpenSubtitles.json'
                $info.EnvironmentVariables['TVT_SUBDL_CONFIG'] = Join-Path (Split-Path $root) 'SubDL.json'
            }
        }
        $scriptFile = (Join-Path $PSScriptRoot 'engine-windows.sh').Replace('\','/')
        $info.Arguments = (@('--noprofile','--norc',$scriptFile) + $arguments | ForEach-Object { Quote-Arg $_ }) -join ' '
    }
    $info.CreateNoWindow = $true
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $progress = $null
    if ($arguments[0] -in @('batch-item','upscale','convert','audio','layout','trim','speed')) {
        $progress = Join-Path ([IO.Path]::GetTempPath()) ('TVT-' + [guid]::NewGuid())
        $info.EnvironmentVariables['TVT_PROGRESS_FILE'] = $progress.Replace('\','/')
    }
    [void]$process.Start()
    @{
        Process = $process
        Progress = $progress
        Output = $process.StandardOutput.ReadToEndAsync()
        Errors = $process.StandardError.ReadToEndAsync()
    }
}
function Start-Engine([string[]]$arguments, [string]$reportName, [string]$trimSource, [string]$discSource, [string]$audioSource, [string]$speedSource) {
    $script:job = New-EngineProcess $arguments
    $script:job.Report = $reportName
    $script:job.SpeedSource = $speedSource
    $script:job.TrimSource = $trimSource
    $script:job.DiscSource = $discSource
    $script:job.AudioSource = $audioSource
    foreach ($button in $buttons) { $button.Enabled = $false }
    $browse.Enabled = $false
    $clear.Enabled = $false
    $script:resultPath = $null
    $reveal.Visible = $false
    $messages = @{
        split='Splitting movie'; join='Joining parts'; link='Linking videos'; upscale='Upscaling video'
        convert='Converting video'; download='Downloading media'; audio='Processing audio'
        subtitles='Preparing subtitles'; layout='Changing video layout'; info='Reading media information'
        duration='Opening editor'; trim='Exporting selected clip'; speed='Changing video speed'
        'disc-scan'='Scanning disc backup'; 'disc-import'='Importing disc title'; 'batch-item'='Processing batch item'
        'audio-tracks'='Reading audio tracks'
    }
    $job.Label = $messages[$arguments[0]] + '... Please wait.'
    if ($job.Progress -and $arguments[0] -ne 'batch-item') {
        $index = if ($arguments[0] -eq 'layout') { 3 } else { 2 }
        $job.Label = $messages[$arguments[0]] + ' - ' + [IO.Path]::GetFileName($arguments[$index])
    }
    $job.NextProgress = 0
    $status.Text = $job.Label
    $banner.BackColor = [Drawing.Color]::FromArgb(199,224,255)
    $script:pulse = [Diagnostics.Stopwatch]::StartNew()
    $poll.Start()
}
$script:batch = $null
function Finish-Batch {
    $batch = $script:batch
    $script:batch = $null
    foreach ($button in $buttons) { $button.Enabled = $true }
    $browse.Enabled = $true
    $clear.Enabled = $script:sources.Count -gt 0
    $count = $batch.Files.Count
    $status.Text = "Batch finished. $($batch.Completed) of $count completed."
    $banner.BackColor = if ($batch.Failures.Count) { [Drawing.Color]::FromArgb(255,211,209) } else { [Drawing.Color]::FromArgb(201,237,209) }
    if ($batch.Completed) {
        $script:resultPath = $batch.Directory
        $reveal.Visible = $true
    }
    if ($batch.Failures.Count) {
        $detail = ($batch.Failures | Select-Object -First 6) -join "`n`n"
        if ($batch.Failures.Count -gt 6) { $detail += "`n`nAnd $($batch.Failures.Count - 6) more." }
        Notice 'Batch finished with errors' $detail
    }
}
function Start-BatchItem {
    $batch = $script:batch
    while ($batch.Index -lt $batch.Files.Count) {
        $video = $batch.Files[$batch.Index]
        try {
            Start-Engine @('batch-item',$batch.Operation,$batch.Setting,$video,$batch.Directory)
            $job.Label = "Video $($batch.Index + 1) of $($batch.Files.Count) - $([IO.Path]::GetFileName($video))"
            $status.Text = $job.Label
            return
        } catch {
            $batch.Failures.Add("$([IO.Path]::GetFileName($video)): $($_.Exception.Message)")
            $batch.Index++
        }
    }
    Finish-Batch
}
function Start-Batch($operation, $setting, [string[]]$videos) {
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    try {
        $dialog.Description = "Choose one folder for all $($videos.Count) outputs."
        $dialog.SelectedPath = [IO.Path]::GetDirectoryName($videos[0])
        if ($dialog.ShowDialog($form) -ne 'OK') { return }
        $directory = $dialog.SelectedPath
    } finally { $dialog.Dispose() }
    $script:batch = @{
        Operation=$operation; Setting=$setting; Files=$videos; Directory=$directory
        Index=0; Completed=0; Failures=(New-Object 'System.Collections.Generic.List[string]')
    }
    $script:resultPath = $null
    $reveal.Visible = $false
    Start-BatchItem
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
function Update-EncodeProgress($job) {
    if (-not $job.Progress -or $script:pulse.ElapsedMilliseconds -lt $job.NextProgress) { return }
    $job.NextProgress = $script:pulse.ElapsedMilliseconds + 500
    try {
        $duration = [double]::Parse([IO.File]::ReadAllText("$($job.Progress).duration"), [Globalization.CultureInfo]::InvariantCulture)
        if ($duration -le 0) { return }
        $stream = [IO.File]::Open($job.Progress, 'Open', 'Read', 'ReadWrite')
        try {
            $offset = [Math]::Max(0, $stream.Length - 4096)
            [void]$stream.Seek($offset, 'Begin')
            $buffer = New-Object byte[] 4096
            $count = $stream.Read($buffer, 0, $buffer.Length)
        } finally { $stream.Dispose() }
        $data = [Text.Encoding]::UTF8.GetString($buffer, 0, $count)
        $timeMatches = [regex]::Matches($data, '(?m)^out_time_us=(-?\d+)\r?\n')
        if ($timeMatches.Count) {
            $microseconds = [double]$timeMatches[$timeMatches.Count - 1].Groups[1].Value
            $percent = [Math]::Floor([Math]::Min(99, [Math]::Max(0, 100 * $microseconds / ($duration * 1000000))))
            $status.Text = "$percent% - $($job.Label)"
        }
    } catch [IO.IOException] {
        # FFmpeg or ffprobe may not have written the status files yet.
    } catch [FormatException] {
        # A duration may still be in the middle of being written.
    }
}
$script:job = $null
$poll = New-Object Windows.Forms.Timer
$poll.Interval = 65
$poll.Add_Tick({
    if (-not $job.Process.HasExited -or -not $job.Output.IsCompleted -or -not $job.Errors.IsCompleted) {
        Update-EncodeProgress $job
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
    $speedSource = $job.SpeedSource
    $trimSource = $job.TrimSource
    $discSource = $job.DiscSource
    $audioSource = $job.AudioSource
    $code = $job.Process.ExitCode
    $job.Process.Dispose()
    if ($job.Progress) {
        Remove-Item -LiteralPath $job.Progress, "$($job.Progress).duration" -ErrorAction SilentlyContinue
    }
    $script:job = $null
    if ($script:batch) {
        $batch = $script:batch
        if ($code -eq 0 -and $result) { $batch.Completed++ }
        else {
            $video = [IO.Path]::GetFileName($batch.Files[$batch.Index])
            if ($errors.Length -gt 350) { $errors = $errors.Substring($errors.Length - 350) }
            if (-not $errors) { $errors = 'No result was created.' }
            $batch.Failures.Add("${video}: $errors")
        }
        $batch.Index++
        Start-BatchItem
        return
    }
    foreach ($button in $buttons) { $button.Enabled = -not $script:queued }
    $browse.Enabled = -not $script:queued
    $clear.Enabled = (-not $script:queued -and $script:sources.Count -gt 0)
    if ($code -ne 0 -or -not $result) {
        $banner.BackColor = [Drawing.Color]::FromArgb(255,211,209)
        $status.Text = 'Processing failed.'
        if (-not $errors) { $errors = 'The selected file could not be processed.' }
        Notice 'TVT' $errors
    } else {
        $banner.BackColor = [Drawing.Color]::FromArgb(201,237,209)
        if ($audioSource) {
            $status.Text = 'Audio tracks read.'
            try { Select-AudioTracks $audioSource (ConvertFrom-Json $result) }
            catch { Notice 'Could not select audio tracks' $_.Exception.Message }
        } elseif ($discSource) {
            try { Complete-DiscScan $discSource @(ConvertFrom-Json $result) }
            catch { Notice 'Disc import failed' $_.Exception.Message }
        } elseif ($speedSource) {
            try {
                $duration = [double]::Parse($result, [Globalization.CultureInfo]::InvariantCulture)
                if ($duration -le 0 -or [double]::IsInfinity($duration) -or [double]::IsNaN($duration)) { throw 'No readable video duration.' }
                $status.Text = 'Speed editor ready.'
                $selection = @(Show-SpeedEditor $speedSource $duration)
                if ($selection.Count) { Start-Engine $selection }
            } catch { Notice 'Could not open speed editor' $_.Exception.Message }
        } elseif ($trimSource) {
            try {
                $duration = [double]::Parse($result, [Globalization.CultureInfo]::InvariantCulture)
                if ($duration -le 0 -or [double]::IsInfinity($duration) -or [double]::IsNaN($duration)) { throw 'No readable video duration.' }
                $status.Text = 'Trim editor ready.'
                $selection = @(Show-TrimEditor $trimSource $duration)
                if ($selection.Count) { Start-Engine $selection }
            } catch {
                $banner.BackColor = [Drawing.Color]::FromArgb(255,211,209)
                $status.Text = 'Trim editor could not open.'
                Notice 'TVT' $_.Exception.Message
            }
        } elseif ($report) {
            $status.Text = 'Finished. MediaInfo report is ready.'
            Show-Report $report $result
        } else {
            $script:resultPath = $result
            $status.Text = 'Finished. Your result is ready.'
            $reveal.Visible = $true
        }
    }
})
function Format-MediaTime([double]$seconds) {
    $seconds.ToString('0.000000', [Globalization.CultureInfo]::InvariantCulture)
}
function Format-Clock([double]$seconds) {
    $time = [TimeSpan]::FromSeconds($seconds)
    '{0:00}:{1:00}:{2:00}.{3:000}' -f [Math]::Floor($time.TotalHours), $time.Minutes, $time.Seconds, $time.Milliseconds
}
function Update-TrimRange {
    $editor = $script:trim
    $position = $editor.Slider.Value / 1000.0
    $editor.Times.Text = "Position $(Format-Clock $position)    Start $(Format-Clock $editor.Start)    End $(Format-Clock $editor.End)"
    $editor.Export.Enabled = $editor.End -gt $editor.Start
    $editor.Highlight.Invalidate()
}
function Request-TrimPreview {
    Update-TrimRange
    $editor = $script:trim
    $editor.Pending = [Math]::Min($editor.Slider.Value / 1000.0, [Math]::Max(0, $editor.Duration - 0.15))
}
function Poll-TrimPreview {
    $editor = $script:trim
    if ($editor.Job) {
        $jobPreview = $editor.Job
        if (-not $jobPreview.Process.HasExited -or -not $jobPreview.Output.IsCompleted -or -not $jobPreview.Errors.IsCompleted) { return }
        try {
            if ($jobPreview.Process.ExitCode -eq 0) {
                $stream = [IO.MemoryStream]::new([IO.File]::ReadAllBytes($editor.Preview))
                try {
                    $frame = [Drawing.Image]::FromStream($stream)
                    try { $bitmap = [Drawing.Bitmap]::new($frame) } finally { $frame.Dispose() }
                } finally { $stream.Dispose() }
                if ($editor.Image.Image) { $editor.Image.Image.Dispose() }
                $editor.Image.Image = $bitmap
                $editor.Hint.Text = 'Preview at ' + (Format-Clock $editor.ActiveTime)
            } else { $editor.Hint.Text = 'No frame at this position. Scrub to a different time.' }
        } catch { $editor.Hint.Text = 'Could not display this frame.' }
        $jobPreview.Process.Dispose()
        $editor.Job = $null
    }
    if ($editor.Closing) { $editor.Window.Close(); return }
    if ($null -ne $editor.Pending) {
        $editor.ActiveTime = $editor.Pending
        $editor.Pending = $null
        $editor.Hint.Text = 'Finding preview frame...'
        try {
            $editor.Job = New-EngineProcess @('preview',(Format-MediaTime $editor.ActiveTime),$editor.File,$editor.Preview)
        } catch { $editor.Hint.Text = $_.Exception.Message }
    }
}
function Show-TrimEditor([string]$file, [double]$duration) {
    $folder = Join-Path (Split-Path $root) ('Trim-' + [guid]::NewGuid())
    [void](New-Item -ItemType Directory -Path $folder)
    $dialog = New-Object Windows.Forms.Form
    $timerPreview = New-Object Windows.Forms.Timer
    try {
        $dialog.Text = 'Trim Clip - ' + [IO.Path]::GetFileName($file)
        $dialog.StartPosition = 'CenterParent'
        $dialog.ClientSize = New-Object Drawing.Size(810, 565)
        $dialog.FormBorderStyle = 'FixedDialog'
        $dialog.MaximizeBox = $false
        $image = New-Object Windows.Forms.PictureBox
        $image.SetBounds(15, 12, 780, 390)
        $image.BackColor = [Drawing.Color]::Black
        $image.SizeMode = 'Zoom'
        $hint = New-Object Windows.Forms.Label
        $hint.SetBounds(16, 407, 775, 20)
        $hint.Text = 'Loading preview...'
        $slider = New-Object Windows.Forms.TrackBar
        $slider.SetBounds(15, 429, 780, 29)
        $slider.AutoSize = $false
        $slider.TickStyle = 'None'
        $slider.Maximum = [int][Math]::Min([int]::MaxValue, [Math]::Floor($duration * 1000))
        $slider.SmallChange = 100
        $slider.LargeChange = 1000
        $slider.Add_ValueChanged({ Request-TrimPreview })
        $highlight = New-Object Windows.Forms.Panel
        $highlight.SetBounds(25, 462, 760, 8)
        $highlight.BackColor = [Drawing.Color]::Gainsboro
        $highlight.Add_Paint({
            param($sender,$eventArgs)
            $editor = $script:trim
            $left = [int]($sender.Width * $editor.Start / $editor.Duration)
            $width = [int]($sender.Width * [Math]::Max(0, $editor.End - $editor.Start) / $editor.Duration)
            $eventArgs.Graphics.FillRectangle([Drawing.Brushes]::DodgerBlue, $left, 0, $width, $sender.Height)
        })
        $times = New-Object Windows.Forms.Label
        $times.SetBounds(16, 480, 779, 20)
        $exportButton = New-Object Windows.Forms.Button
        $exportButton.Text = 'Export Clip...'
        $exportButton.SetBounds(555, 517, 120, 29)
        $exportButton.Add_Click({
            $editor = $script:trim
            if ($editor.End -le $editor.Start) { return }
            $choice = Pick-Index 'Export Clip - choose a format' @($profiles | ForEach-Object { $_[1] }) 1 $editor.Window
            if ($choice -lt 0) { return }
            $extension = $profiles[$choice][0]
            $destination = Pick-Output $editor.File $extension 'Clip' $editor.Window
            if (-not $destination) { return }
            $editor.Result = @('trim',$extension,$editor.File,$destination,(Format-MediaTime $editor.Start),(Format-MediaTime $editor.End))
            $editor.Window.Close()
        })
        $dialog.Controls.AddRange(@($image,$hint,$slider,$highlight,$times,$exportButton))
        $controls = @(
            @{Text='-0.1 s'; X=16; Action={ $script:trim.Slider.Value = [Math]::Max(0, $script:trim.Slider.Value - 100) }},
            @{Text='+0.1 s'; X=108; Action={ $script:trim.Slider.Value = [Math]::Min($script:trim.Slider.Maximum, $script:trim.Slider.Value + 100) }},
            @{Text='Mark Start'; X=213; Action={ $script:trim.Start = $script:trim.Slider.Value / 1000.0; Update-TrimRange }},
            @{Text='Mark End'; X=315; Action={ $script:trim.End = $script:trim.Slider.Value / 1000.0; Update-TrimRange }},
            @{Text='Cancel'; X=703; Action={ $script:trim.Window.Close() }}
        )
        foreach ($control in $controls) {
            $button = New-Object Windows.Forms.Button
            $button.Text = $control.Text
            $button.SetBounds($control.X, 517, 85, 29)
            $button.Add_Click($control.Action)
            $dialog.Controls.Add($button)
        }
        $script:trim = @{
            Window=$dialog; Image=$image; Hint=$hint; Slider=$slider; Times=$times; Export=$exportButton
            Highlight=$highlight; Start=0.0; End=$duration; Duration=$duration; File=$file
            Preview=(Join-Path $folder 'frame.png'); Pending=0.0; Job=$null; Closing=$false; Result=$null
        }
        $dialog.Add_FormClosing({
            param($sender,$eventArgs)
            if ($script:trim.Job) {
                $eventArgs.Cancel = $true
                $script:trim.Closing = $true
                $script:trim.Hint.Text = 'Finishing the current preview...'
            }
        })
        Update-TrimRange
        $timerPreview.Interval = 100
        $timerPreview.Add_Tick({ Poll-TrimPreview })
        $timerPreview.Start()
        [void]$dialog.ShowDialog($form)
        $script:trim.Result
    } finally {
        $timerPreview.Stop()
        $timerPreview.Dispose()
        if ($image -and $image.Image) { $image.Image.Dispose() }
        $dialog.Dispose()
        Remove-Item -LiteralPath $folder -Recurse -Force
        $script:trim = $null
    }
}

# WPF MediaElement provides native playback with sound inside the speed editor.
function Update-SpeedValue([double]$value) {
    $editor = $script:speedEditor
    $editor.Rate = if ($value -eq 0) { 0.0 } else { [Math]::Max(0.05, [Math]::Min(8.0, $value)) }
    $editor.Speed.Value = [int][Math]::Round($editor.Rate * 100)
    $editor.Number.Value = [decimal]$editor.Rate
    if ($editor.Rate -eq 0) {
        $editor.Player.Pause(); $editor.Playing = $false; $editor.Play.Text = 'Play'
    } else { $editor.Player.SpeedRatio = $editor.Rate }
    $editor.Save.Enabled = $editor.Rate -gt 0 -and -not $editor.Job
    $newDuration = if ($editor.Rate -gt 0) { Format-Clock ($editor.Duration / $editor.Rate) } else { 'Stopped' }
    $editor.Times.Text = "Speed $($editor.Rate.ToString('0.00'))x     New duration $newDuration"
}
function Request-SpeedPlayback([double]$position, [bool]$play) {
    $editor = $script:speedEditor
    $editor.Player.Pause(); $editor.Playing = $false; $editor.Play.Text = 'Play'
    $position = [Math]::Max(0, [Math]::Min($editor.Duration, $position))
    $editor.Position = $position
    $editor.PendingPlay = $play
    if ($editor.Ready -and $position -ge $editor.Start -and $position -lt $editor.End - 0.1) {
        $editor.Player.Position = [TimeSpan]::FromSeconds($position - $editor.Start)
        if ($play -and $editor.Rate -gt 0) {
            $editor.Player.SpeedRatio = $editor.Rate
            $editor.Player.Play(); $editor.Playing = $true; $editor.Play.Text = 'Pause'
        }
    } else { $editor.Pending = $position }
}
function Poll-SpeedPlayback {
    $editor = $script:speedEditor
    if ($editor.Job) {
        $task = $editor.Job
        if (-not $task.Process.HasExited -or -not $task.Output.IsCompleted -or -not $task.Errors.IsCompleted) { return }
        $code = $task.Process.ExitCode
        $detail = $task.Errors.Result
        $task.Process.Dispose(); $editor.Job = $null
        if ($editor.Closing) { $editor.Window.Close(); return }
        if ($code -ne 0) {
            $editor.Hint.Text = 'Could not prepare preview: ' + $detail
            $editor.Play.Enabled = $true; $editor.Save.Enabled = $editor.Rate -gt 0
            return
        }
        if ($null -eq $editor.Pending) {
            $editor.Start = $editor.Active
            $editor.End = [Math]::Min($editor.Duration, $editor.Start + 60)
            $editor.Player.Source = [Uri]::new($editor.Preview)
            # MediaOpened completes seeking and optional playback asynchronously.
        }
    }
    if ($null -ne $editor.Pending) {
        $editor.Active = $editor.Pending; $editor.Pending = $null
        $editor.Ready = $false; $editor.Player.Close()
        Get-ChildItem -LiteralPath $editor.Folder -Filter '*.mp4' | Remove-Item -Force -ErrorAction SilentlyContinue
        $editor.Preview = Join-Path $editor.Folder ([guid]::NewGuid().ToString() + '.mp4')
        $editor.Hint.Text = 'Preparing playback with sound...'
        $editor.Play.Enabled = $false; $editor.Save.Enabled = $false
        try { $editor.Job = New-EngineProcess @('playback-preview',(Format-MediaTime $editor.Active),$editor.File,$editor.Preview) }
        catch { $editor.Hint.Text = $_.Exception.Message; $editor.Play.Enabled = $true }
        return
    }
    if ($editor.Playing) {
        $editor.Position = [Math]::Min($editor.Duration, $editor.Start + $editor.Player.Position.TotalSeconds)
        $editor.Updating = $true
        $editor.Timeline.Value = [int][Math]::Min($editor.Timeline.Maximum, $editor.Position * 1000)
        $editor.Updating = $false
        $editor.Hint.Text = 'Position ' + (Format-Clock $editor.Position)
    }
}
function Show-SpeedEditor([string]$file, [double]$duration) {
    Add-Type -AssemblyName @('PresentationCore','PresentationFramework','WindowsBase','WindowsFormsIntegration')
    $folder = Join-Path (Split-Path $root) ('Speed-' + [guid]::NewGuid())
    [void](New-Item -ItemType Directory -Path $folder)
    $dialog = New-Object Windows.Forms.Form
    $timer = New-Object Windows.Forms.Timer
    $media = New-Object Windows.Controls.MediaElement
    $hostView = New-Object Windows.Forms.Integration.ElementHost
    try {
        $dialog.Text = 'Change Speed - ' + [IO.Path]::GetFileName($file)
        $dialog.StartPosition = 'CenterParent'; $dialog.ClientSize = New-Object Drawing.Size(810,655)
        $dialog.FormBorderStyle = 'FixedDialog'; $dialog.MaximizeBox = $false
        $dialog.KeyPreview = $true
        $dialog.Add_KeyDown({
            param($sender,$eventArgs)
            if ($eventArgs.KeyCode -eq 'Space' -and -not $script:speedEditor.Number.Focused) {
                $eventArgs.SuppressKeyPress = $true; $script:speedEditor.Play.PerformClick()
            }
        })
        $hostView.SetBounds(15,12,780,390); $hostView.BackColor = [Drawing.Color]::Black
        $media.LoadedBehavior = 'Manual'; $media.UnloadedBehavior = 'Manual'
        $media.ScrubbingEnabled = $true; $media.Stretch = 'Uniform'; $hostView.Child = $media
        $hint = New-Object Windows.Forms.Label
        $hint.SetBounds(16,408,775,20); $hint.Text = 'Preparing preview...'
        $timeline = New-Object Windows.Forms.TrackBar
        $timeline.SetBounds(15,430,780,30); $timeline.AutoSize = $false; $timeline.TickStyle = 'None'
        $timeline.Maximum = [int][Math]::Min([int]::MaxValue, [Math]::Floor($duration * 1000))
        $timeline.Add_Scroll({ if (-not $script:speedEditor.Updating) { Request-SpeedPlayback ($script:speedEditor.Timeline.Value / 1000.0) $false } })
        $speed = New-Object Windows.Forms.TrackBar
        $speed.SetBounds(75,470,475,35); $speed.AutoSize = $false; $speed.TickStyle = 'None'
        $speed.Maximum = 800; $speed.Value = 100
        $speed.Add_Scroll({ Update-SpeedValue ($script:speedEditor.Speed.Value / 100.0) })
        $number = New-Object Windows.Forms.NumericUpDown
        $number.SetBounds(563,475,75,25); $number.Minimum = 0; $number.Maximum = 8
        $number.DecimalPlaces = 2; $number.Increment = 0.01; $number.Value = 1
        $number.Add_ValueChanged({ if ([Math]::Abs([double]$script:speedEditor.Number.Value - $script:speedEditor.Rate) -gt 0.001) { Update-SpeedValue ([double]$script:speedEditor.Number.Value) } })
        $stopped = New-Object Windows.Forms.Label
        $stopped.Text = 'Stopped'; $stopped.SetBounds(16,480,60,22)
        $fast = New-Object Windows.Forms.Label
        $fast.Text = '8x'; $fast.SetBounds(540,480,25,22)
        $times = New-Object Windows.Forms.Label
        $times.SetBounds(16,515,775,23)
        $play = New-Object Windows.Forms.Button
        $play.Text = 'Play'; $play.SetBounds(16,546,75,29)
        $play.Add_Click({
            $editor = $script:speedEditor
            if ($editor.Playing) { Request-SpeedPlayback $editor.Position $false }
            else {
                if ($editor.Rate -eq 0) { Update-SpeedValue 1 }
                $position = if ($editor.Position -ge $editor.Duration - 0.1) { 0 } else { $editor.Position }
                Request-SpeedPlayback $position $true
            }
        })
        $save = New-Object Windows.Forms.Button
        $save.Text = 'Save Video...'; $save.SetBounds(565,546,120,29)
        $save.Add_Click({
            $editor = $script:speedEditor
            if ($editor.Rate -le 0) { return }
            Request-SpeedPlayback $editor.Position $false
            $choice = Pick-Index 'Save Changed Speed (subtitles and chapters omitted)' @('MP4 (H.264 / AAC)','MKV (H.264 / AAC)') 0 $editor.Window
            if ($choice -lt 0) { return }
            $extension = @('mp4','mkv')[$choice]
            $destination = Pick-Output $editor.File $extension 'Speed' $editor.Window
            if (-not $destination) { return }
            $editor.Result = @('speed',(Format-MediaTime $editor.Rate),$editor.File,$destination)
            $editor.Window.Close()
        })
        $note = New-Object Windows.Forms.Label
        $note.SetBounds(16,595,775,50)
        $note.Text = '0 pauses; save from 0.05x to 8x. Saved audio keeps its pitch. Preview audio may be muted at extreme speeds. Exports video and all audio tracks; subtitles and chapters are omitted.'
        $dialog.Controls.AddRange(@($hostView,$hint,$timeline,$speed,$number,$stopped,$fast,$times,$play,$save,$note))
        foreach ($control in @(
            @{Text='Beginning'; X=96; Width=90; Action={ Request-SpeedPlayback 0 $false }},
            @{Text='-10 s'; X=191; Width=65; Action={ Request-SpeedPlayback ($script:speedEditor.Position - 10) $false }},
            @{Text='+10 s'; X=261; Width=65; Action={ Request-SpeedPlayback ($script:speedEditor.Position + 10) $false }},
            @{Text='Normal 1x'; X=675; Width=110; Y=473; Action={ Update-SpeedValue 1 }},
            @{Text='Cancel'; X=700; Width=85; Action={ $script:speedEditor.Window.Close() }}
        )) {
            $button = New-Object Windows.Forms.Button
            $button.Text = $control.Text
            $y = if ($control.ContainsKey('Y')) { $control.Y } else { 546 }
            $button.SetBounds($control.X,$y,$control.Width,29)
            $button.Add_Click($control.Action); $dialog.Controls.Add($button)
        }
        $volume = New-Object Windows.Forms.TrackBar
        $volume.SetBounds(370,546,160,29); $volume.AutoSize = $false; $volume.TickStyle = 'None'
        $volume.Maximum = 100; $volume.Value = 100
        $volume.AccessibleName = 'Volume'
        $volume.Add_Scroll({ $script:speedEditor.Player.Volume = $this.Value / 100.0 })
        $dialog.Controls.Add($volume)
        $script:speedEditor = @{
            Window=$dialog; Player=$media; Hint=$hint; Timeline=$timeline; Speed=$speed; Number=$number; Times=$times
            Play=$play; Save=$save; Rate=1.0; Duration=$duration; File=$file; Folder=$folder; Preview=$null
            Start=0.0; End=0.0; Position=0.0; Active=0.0; Pending=0.0; PendingPlay=$false
            Playing=$false; Ready=$false; Updating=$false; Job=$null; Closing=$false; Result=$null
        }
        $media.Add_MediaOpened({
            $editor = $script:speedEditor
            if ($null -ne $editor.Pending -or $editor.Closing) { return }
            $editor.Ready = $true
            $editor.Play.Enabled = $true; Update-SpeedValue $editor.Rate
            $editor.Hint.Text = 'Ready. Press Play, then adjust the speed.'
            Request-SpeedPlayback $editor.Start $editor.PendingPlay
        })
        $media.Add_MediaEnded({
            $editor = $script:speedEditor
            if ($editor.End -ge $editor.Duration - 0.15) {
                $editor.Player.Pause(); $editor.Playing = $false; $editor.Play.Text = 'Play'
                $editor.Position = $editor.Duration
                $editor.Timeline.Value = $editor.Timeline.Maximum
                $editor.Hint.Text = 'End of video. Press Play to restart.'
            } else { Request-SpeedPlayback $editor.End $editor.Playing }
        })
        $media.Add_MediaFailed({
            $script:speedEditor.Playing = $false
            $script:speedEditor.Hint.Text = 'Windows could not play this preview.'
        })
        $dialog.Add_FormClosing({
            param($sender,$eventArgs)
            $script:speedEditor.Player.Pause()
            if ($script:speedEditor.Job) {
                $eventArgs.Cancel = $true; $script:speedEditor.Closing = $true
                $script:speedEditor.Hint.Text = 'Finishing the current preview...'
            }
        })
        Update-SpeedValue 1
        $timer.Interval = 100; $timer.Add_Tick({ Poll-SpeedPlayback }); $timer.Start()
        [void]$dialog.ShowDialog($form)
        $script:speedEditor.Result
    } finally {
        $timer.Stop(); $timer.Dispose(); $media.Close(); $hostView.Dispose(); $dialog.Dispose()
        Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
        $script:speedEditor = $null
    }
}

function Complete-DiscScan($file, $titles) {
    $titles = @($titles | ForEach-Object { $_ })
    if (-not $titles.Count) { throw 'No playable titles found.' }
    $status.Text = 'Disc scan complete.'
    $choice = 0
    if ($titles.Count -gt 1) {
        $labels = @($titles | ForEach-Object {
            $flag = if ($_.mvc) { ' - MVC 3D' } else { '' }
            "Title $($_.id) - $($_.duration) - $($_.name)$flag"
        })
        $choice = Pick-Index 'Choose a title (longest shown first)' $labels
        if ($choice -lt 0) { return }
    }
    $title = $titles[$choice]
    $default = if ($title.mvc) { 1 } else { 0 }
    $outputChoices = @(
        'Original MKV (2D or keep original 3D)', 'MVC Blu-ray 3D to Full Side-by-Side',
        'Full Over-Under to Full Side-by-Side', 'Half Over-Under to Full Side-by-Side',
        'Already Full Side-by-Side (tag only)', 'Already Half Side-by-Side (tag only)'
    )
    if ($title.mvc) { $outputChoices = $outputChoices[0..1] }
    $format = Pick-Index 'Choose MKV output (Original if unsure)' $outputChoices $default
    if ($format -lt 0) { return }
    $destination = Pick-Output $file 'mkv' "Title $($title.id)"
    if ($destination) {
        $mode = @('original','mvc','ou','half-ou','sbs','half-sbs')[$format]
        Start-Engine @('disc-import',$file,"$($title.id)",$mode,$destination)
    }
}
function Open-DiscBackup {
    $loaded = @($script:sources | Where-Object { $_ -match '\.(iso|ifo|bdmv|mkv)$' -or (Test-Path -LiteralPath $_ -PathType Container) })
    if ($loaded.Count -eq 1) { $source = $loaded[0] }
    elseif ($loaded.Count -gt 1) {
        $choice = Pick-Index 'Choose a loaded disc backup' $loaded
        if ($choice -lt 0) { return }
        $source = $loaded[$choice]
    } else {
        $kind = Pick-Index 'Choose a disc backup' @('ISO, disc index or MVC 3D MKV','VIDEO_TS or BDMV folder')
        if ($kind -lt 0) { return }
        if ($kind -eq 0) { $source = @(Pick-Files $false) | Select-Object -First 1 }
        else {
            $dialog = New-Object Windows.Forms.FolderBrowserDialog
            try {
                if ($dialog.ShowDialog($form) -eq 'OK') { $source = $dialog.SelectedPath }
            } finally { $dialog.Dispose() }
        }
    }
    if ($source) { Start-DiscBackup $source }
}
function Start-DiscBackup($source, [int]$isoDefault = 1) {
    if ($source -and $source -match '\.mkv$' -and (Test-Path -LiteralPath $source -PathType Leaf)) {
        if (-not (Confirm 'Convert MVC MKV to Full Side-by-Side?' 'Choose this for an MKV that still contains both Blu-ray 3D views.')) { return }
        $destination = Pick-Output $source 'mkv' 'Full SBS'
        if ($destination) { Start-Engine @('disc-import',$source,'0','mvc',$destination) }
    } elseif ($source) {
        if ($source -match '\.iso$' -and (Test-Path -LiteralPath $source -PathType Leaf)) {
            $choice = Pick-Index 'Import Blu-ray ISO' @('Convert longest 3D playlist directly to Full Side-by-Side','Scan disc and choose a title') $isoDefault
            if ($choice -lt 0) { return }
            if ($choice -eq 0) {
                $destination = Pick-Output $source 'mkv' 'Full SBS'
                if ($destination) { Start-Engine @('disc-import',$source,'0','mvc-iso',$destination) }
                return
            }
        }
        Start-Engine @('disc-scan',$source) -discSource $source
    }
}

function Select-AudioTracks($file, $probe) {
    if (-not $probe.streams) {
        Notice 'No audio tracks' 'This video has no audio tracks to select.'
        return
    }
    $languages = @{}
    foreach ($culture in [Globalization.CultureInfo]::GetCultures([Globalization.CultureTypes]::NeutralCultures)) {
        $languages[$culture.ThreeLetterISOLanguageName] = $culture.EnglishName
        $languages[$culture.TwoLetterISOLanguageName] = $culture.EnglishName
    }
    $dialog = New-Object Windows.Forms.Form
    try {
        $dialog.Text = 'Choose audio tracks to keep'
        $dialog.StartPosition = 'CenterParent'
        $dialog.ClientSize = New-Object Drawing.Size(560, 275)
        $hint = New-Object Windows.Forms.Label
        $hint.Text = 'English-tagged tracks are checked. Review your selection before saving a new MKV.'
        $hint.SetBounds(12, 10, 530, 24)
        $tracks = New-Object Windows.Forms.CheckedListBox
        $tracks.CheckOnClick = $true
        $tracks.HorizontalScrollbar = $true
        $tracks.SetBounds(12, 38, 530, 185)
        $number = 0
        foreach ($stream in $probe.streams) {
            $number++
            $code = [string]$stream.tags.language
            $language = if (-not $code -or $code -eq 'und') { 'Unknown language' }
                        elseif ($languages.ContainsKey($code)) { $languages[$code] }
                        else { $code }
            $channels = if ($stream.channels) { "$($stream.channels) ch" }
            $label = (@("Track $number", $language, $stream.tags.title, $stream.codec_name, $channels) |
                      Where-Object { $_ }) -join ' - '
            [void]$tracks.Items.Add($label, ($code -in @('eng','en')))
        }
        $ok = New-Object Windows.Forms.Button
        $ok.Text = 'Continue'
        $ok.DialogResult = 'OK'
        $ok.SetBounds(370, 235, 80, 27)
        $cancel = New-Object Windows.Forms.Button
        $cancel.Text = 'Cancel'
        $cancel.DialogResult = 'Cancel'
        $cancel.SetBounds(462, 235, 80, 27)
        $dialog.Controls.AddRange(@($hint,$tracks,$ok,$cancel))
        $dialog.AcceptButton = $ok
        $dialog.CancelButton = $cancel
        while ($dialog.ShowDialog($form) -eq 'OK') {
            if ($tracks.CheckedIndices.Count) {
                $destination = Pick-Output $file 'mkv' 'Selected Audio'
                if ($destination) {
                    $setting = 'keep:' + ($tracks.CheckedIndices -join ',')
                    Start-Engine @('audio',$setting,$file,$destination)
                }
                return
            }
            Notice 'Choose at least one track' 'Check the audio tracks you want to keep.'
        }
    } finally { $dialog.Dispose() }
}

function Move-VideoOrder($sender, [int]$offset) {
    $state = $sender.FindForm().Tag
    $row = $state.List.SelectedIndex
    $destination = $row + $offset
    if ($row -lt 0 -or $destination -lt 0 -or $destination -ge $state.Files.Count) { return }
    $temp = $state.Files[$row]
    $state.Files[$row] = $state.Files[$destination]
    $state.Files[$destination] = $temp
    $state.List.Items.Clear()
    for ($i = 0; $i -lt $state.Files.Count; $i++) {
        [void]$state.List.Items.Add("$($i + 1). $($state.Files[$i])")
    }
    $state.List.SelectedIndex = $destination
}

function Pick-VideoOrder([string[]]$files) {
    $dialog = New-Object Windows.Forms.Form
    try {
        $dialog.Text = 'Choose the playback order'
        $dialog.StartPosition = 'CenterParent'
        $dialog.ClientSize = New-Object Drawing.Size(680, 330)
        $hint = New-Object Windows.Forms.Label
        $hint.Text = 'Read from top to bottom. Select a video and use Move Up or Move Down.'
        $hint.SetBounds(12, 10, 650, 24)
        $list = New-Object Windows.Forms.ListBox
        $list.HorizontalScrollbar = $true
        $list.SetBounds(12, 38, 650, 235)
        $ordered = @($files | Sort-Object { [regex]::Replace([IO.Path]::GetFileName($_), '\d+', { param($m) $m.Value.PadLeft(20, '0') }) })
        for ($i = 0; $i -lt $ordered.Count; $i++) { [void]$list.Items.Add("$($i + 1). $($ordered[$i])") }
        $list.SelectedIndex = 0
        $dialog.Tag = @{ List=$list; Files=$ordered }
        $up = New-Object Windows.Forms.Button
        $up.Text = 'Move Up'
        $up.SetBounds(12, 288, 100, 28)
        $up.Add_Click({ param($sender,$eventArgs) Move-VideoOrder $sender -1 })
        $down = New-Object Windows.Forms.Button
        $down.Text = 'Move Down'
        $down.SetBounds(120, 288, 100, 28)
        $down.Add_Click({ param($sender,$eventArgs) Move-VideoOrder $sender 1 })
        $ok = New-Object Windows.Forms.Button
        $ok.Text = 'Continue'
        $ok.DialogResult = 'OK'
        $ok.SetBounds(460, 288, 95, 28)
        $cancel = New-Object Windows.Forms.Button
        $cancel.Text = 'Cancel'
        $cancel.DialogResult = 'Cancel'
        $cancel.SetBounds(567, 288, 95, 28)
        $dialog.Controls.AddRange(@($hint,$list,$up,$down,$ok,$cancel))
        $dialog.AcceptButton = $ok
        $dialog.CancelButton = $cancel
        if ($dialog.ShowDialog($form) -eq 'OK') { $dialog.Tag.Files }
    } finally { $dialog.Dispose() }
}

function Choose-Operation($operation) {
    try {
        if ($operation -eq 'Import Disc Backup') { Open-DiscBackup; return }
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
        $supportsBatch = $operation -in @('Upscale Video','Convert Video','Extract or Remove Audio')
        if ($supportsBatch) {
            $files = if ($script:sources.Count) { @($script:sources) } else { @(Pick-Files $true) }
            $files = @($files | Where-Object { $_ })
            if (@($files | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }).Count) {
                Notice 'Choose individual video files' 'Disc backup folders use Import Disc Backup.'
                return
            }
        } else { $files = @(Pick-Sources $multiple) }
        if (-not $files.Count) { return }
        if ($multiple -and $files.Count -lt 2) { Notice $operation 'Choose at least two files.'; return }
        $file = $files[0]
        switch ($operation) {
            'Change Speed' {
                Start-Engine @('duration',$file) -speedSource $file
            }
            'Trim Clip' {
                Start-Engine @('duration',$file) -trimSource $file
            }
            'Split Movie' {
                $choice = Pick-Index 'Number of roughly equal parts' (2..12 | ForEach-Object { "$_" }) 2
                if ($choice -ge 0) { Start-Engine @('split', "$($choice + 2)", $file) }
            }
            'Join Parts' {
                $ordered = @(Pick-VideoOrder $files)
                if ($ordered.Count) { Start-Engine (@('join') + $ordered) }
            }
            'Link Videos' {
                $ordered = @(Pick-VideoOrder $files)
                if (-not $ordered.Count) { return }
                $destination = Pick-Output $ordered[0] 'mp4' 'Linked'
                if ($destination) { Start-Engine (@('link',$destination) + $ordered) }
            }
            'Upscale Video' {
                $choice = Pick-Index 'Upscale Video' @('1080p','4K')
                if ($choice -lt 0) { return }
                $label = @('1080p','4K')[$choice]
                $height = @('1080','2160')[$choice]
                if ($files.Count -gt 1) { Start-Batch 'upscale' $height $files; return }
                $destination = Pick-Output $file 'mp4' $label
                if ($destination) { Start-Engine @('upscale',$height,$file,$destination) }
            }
            'MediaInfo' {
                $choice = Pick-Index 'MediaInfo report view' @('Summary','Full Details','JSON')
                if ($choice -ge 0) { Start-Engine @('info',@('summary','full','json')[$choice],$file) ([IO.Path]::GetFileName($file)) }
            }
            'Extract or Remove Audio' {
                $choice = Pick-Index 'Extract or Remove Audio' @('Keep English Audio Only (MKV)','Keep selected audio tracks (MKV)','MP3','M4A','FLAC','WAV','Remove audio (MKV)')
                if ($choice -lt 0) { return }
                if ($choice -eq 0) {
                    if ($files.Count -gt 1) { Start-Batch 'audio' 'english' $files; return }
                    $destination = Pick-Output $file 'mkv' 'English Audio'
                    if ($destination) { Start-Engine @('audio','english',$file,$destination) }
                    return
                }
                if ($choice -eq 1) {
                    if ($files.Count -ne 1) { Notice 'Choose one video' 'Audio track selection is specific to each video.'; return }
                    Start-Engine @('audio-tracks',$file) -audioSource $file
                    return
                }
                $choice -= 2
                $format = @('mp3','m4a','flac','wav','silent')[$choice]
                if ($files.Count -gt 1) { Start-Batch 'audio' $format $files; return }
                $extension = @('mp3','m4a','flac','wav','mkv')[$choice]
                $suffix = if ($format -eq 'silent') { 'Silent' } else { 'Audio' }
                $destination = Pick-Output $file $extension $suffix
                if ($destination) { Start-Engine @('audio',$format,$file,$destination) }
            }
            'Add Subtitles' {
                $choice = Pick-Index 'Choose the video layout' (@('2D') + $layoutLabels)
                if ($choice -lt 0) { return }
                $layout = (@('flat') + $layoutCodes)[$choice]
                $method = Pick-Index 'Choose the subtitle source' @('Local text subtitle','Search OpenSubtitles','Search Subtitle Cat','Download from SubDL')
                if ($method -lt 0) { return }
                if ($method -eq 2) {
                    $title = Text-Input 'Search Subtitle Cat by movie or episode title' ([IO.Path]::GetFileNameWithoutExtension($file))
                    if (-not $title) { return }
                    $url = 'https://www.subtitlecat.com/index.php?d=1&search=' + [Uri]::EscapeDataString($title)
                    Start-Process -FilePath $url -ErrorAction Stop
                    if ([Windows.Forms.MessageBox]::Show($form, 'Download an SRT in your browser, then return to TVT and click OK to select it.', 'Subtitle Cat', 'OKCancel') -ne 'OK') { return }
                }
                $depth = '0'
                if ($choice -gt 0) {
                    $level = Pick-Index '3D subtitle depth' @('At the screen','Slightly forward','More forward','Most forward') 1
                    if ($level -lt 0) { return }
                    $depth = @('0','0.8','1.5','2.5')[$level]
                }
                if ($method -eq 0 -or $method -eq 2) {
                    $caption = @(Pick-Files $false)
                    if (-not $caption.Count) { return }
                    $inputArgs = @('local',$caption[0])
                } else {
                    $prompt = if ($method -eq 3) { 'Movie title and year, IMDb ID, or show title and S01E01' } else { 'Movie title and year, or show title and S01E01' }
                    $title = Text-Input $prompt ([IO.Path]::GetFileNameWithoutExtension($file))
                    if (-not $title) { return }
                    $language = Text-Input 'Subtitle language code' 'en'
                    if (-not $language) { return }
                    $provider = if ($method -eq 3) { 'subdl' } else { 'online' }
                    $inputArgs = @($provider,$title,$language)
                }
                $extension = 'mkv'
                $suffix = 'English subtitles'
                if ($choice -gt 0) {
                    $format = Pick-Index 'Save 3D subtitles' @('Embed in a new MKV','Save a separate ASS file')
                    if ($format -lt 0) { return }
                    if ($format -eq 1) {
                        $extension = 'ass'
                        $suffix = ''
                    }
                }
                $destination = Pick-Output $file $extension $suffix
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
                $isos = @($files | Where-Object { $_ -match '\.iso$' })
                if ($isos.Count) {
                    if ($files.Count -ne 1) { Notice 'Convert one ISO at a time' 'Select just the disc image, then click Convert Video again.'; return }
                    Start-DiscBackup $isos[0] 0
                    return
                }
                $choices = @($profiles | ForEach-Object { $_[1] }) + @('3D Side-by-Side to Cross-eye (MKV)','3D Side-by-Side to Red/Cyan Anaglyph (MKV)')
                $choice = Pick-Index 'Convert Video - choose the output format' $choices
                if ($choice -lt 0) { return }
                if ($choice -ge $profiles.Count) {
                    $input = Pick-Index 'Current Side-by-Side format' @('Full Side-by-Side (left eye first)','Half Side-by-Side (left eye first)')
                    if ($input -lt 0) { return }
                    $cross = $choice -eq $profiles.Count
                    $setting = $(if ($cross) { 'cross-' } else { 'anaglyph-' }) + @('sbsl','sbs2l')[$input]
                    if ($files.Count -gt 1) { Start-Batch 'convert' $setting $files; return }
                    $suffix = if ($cross) { 'Cross-eye' } else { 'Anaglyph' }
                    $destination = Pick-Output $file 'mkv' $suffix
                    if ($destination) { Start-Engine @('convert',$setting,$file,$destination) }
                    return
                }
                $extension = $profiles[$choice][0]
                if ($files.Count -gt 1) { Start-Batch 'convert' $extension $files; return }
                $destination = Pick-Output $file $extension 'Converted'
                if ($destination) { Start-Engine @('convert',$extension,$file,$destination) }
            }
        }
    } catch { Notice 'TVT' $_.Exception.Message }
}
$script:queued = $false
$installPoll = New-Object Windows.Forms.Timer
$installPoll.Interval = 250
$installPoll.Add_Tick({
    if (Test-Path -LiteralPath $script:updateReady) {
        $installPoll.Stop()
        $script:updateProcess.Dispose()
        $form.Close()
    } elseif ($script:updateProcess.HasExited) {
        $installPoll.Stop()
        $script:updateProcess.Dispose()
        $script:queued = $false
        foreach ($button in $buttons) { $button.Enabled = $true }
        $browse.Enabled = $true
        $clear.Enabled = $script:sources.Count -gt 0
        $status.Text = 'Update preparation failed. Try Help > Check for Updates again.'
    }
})
function Confirm-Update($release) {
    $dialog = New-Object Windows.Forms.Form
    try {
        $dialog.Text = "TVT $release is available"
        $dialog.ClientSize = New-Object Drawing.Size(440, 116)
        $dialog.StartPosition = 'CenterParent'
        $label = New-Object Windows.Forms.Label
        $label.Text = 'TVT will prepare the update, close to install it, and reopen automatically.'
        $label.SetBounds(14, 16, 412, 38)
        $install = New-Object Windows.Forms.Button
        $install.Text = 'Quit and Install Update'
        $install.SetBounds(164, 69, 170, 30)
        $install.DialogResult = 'OK'
        $later = New-Object Windows.Forms.Button
        $later.Text = 'Later'
        $later.SetBounds(344, 69, 80, 30)
        $later.DialogResult = 'Cancel'
        $dialog.AcceptButton = $install
        $dialog.CancelButton = $later
        $dialog.Controls.AddRange(@($label,$install,$later))
        return $dialog.ShowDialog($form) -eq 'OK'
    } finally { $dialog.Dispose() }
}
function Check-Update([bool]$manual) {
    if ($script:queued) { if ($manual) { Notice 'TVT' 'TVT is preparing the update and will reopen automatically.' }; return }
    if ($job -or $script:trim -or $script:speedEditor) { if ($manual) { Notice 'TVT' 'Wait until the current operation finishes.' }; return }
    try {
        $commit = (Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/commits/main" -TimeoutSec 12).sha
        if ($commit -notmatch '^[a-f0-9]{40}$') { throw 'GitHub did not return a valid version reference.' }
        $release = [version](Invoke-RestMethod -Uri "https://raw.githubusercontent.com/$repo/$commit/VERSION" -TimeoutSec 12).Trim()
        if ($release -le $version) { if ($manual) { Notice 'TVT' "TVT $version is up to date." }; return }
        if (-not (Confirm-Update $release)) { return }
        $install = Split-Path $root
        $helper = Join-Path $install ('Update-' + [guid]::NewGuid() + '.ps1')
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Install-VFLR.ps1') -Destination $helper
        $args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $(Quote-Arg $helper) -ParentId $PID -Commit $commit -Version $release -Restart"
        try { $script:updateProcess = Start-Process powershell.exe -ArgumentList $args -WindowStyle Hidden -PassThru -ErrorAction Stop }
        catch { Remove-Item -LiteralPath $helper -Force; throw }
        $script:queued = $true
        foreach ($button in $buttons) { $button.Enabled = $false }
        $browse.Enabled = $false
        $clear.Enabled = $false
        $status.Text = 'Preparing update... TVT will reopen automatically.'
        $script:updateReady = "$helper.ready"
        $installPoll.Start()
    } catch { if ($manual) { Notice 'Update check failed' $_.Exception.Message } }
}
$updates = New-Object Windows.Forms.Timer
$updates.Interval = 900000
$updates.Add_Tick({ Check-Update $false })
$form.Add_Shown({ $updates.Start() })
$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($installPoll.Enabled) { $eventArgs.Cancel = $true; return }
    if ($job) { $eventArgs.Cancel = $true; Notice 'TVT' 'Wait for the current operation to finish before closing.' }
})
# Related apps are shortcuts; installing or removing a shortcut never removes an app.
$script:relatedAppsFile = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'TVT\RelatedApps.json'
$script:relatedBuiltins = @(
    @{Name='InjectZ'; URL='https://github.com/TedInVR/InjectZ'; Names=@('InjectZ','Inject Z'); Description='InjectZ turns photographs into stereoscopic 3D images, including side-by-side, cross-eye and red/cyan anaglyph outputs and animated wigglegrams. Some engines need separate setup or model downloads.'},
    @{Name='StereoMask for Mac'; URL='https://github.com/TedInVR/StereoMask-Mac'; Names=@('StereoMask'); Description='StereoMask for Mac frames stereoscopic images and creates out-of-frame effects, with brushes, lassos, text, speech bubbles and editable projects. A collaboration between Subbiah Rathinagiri and Theodore Whitten. This project is for macOS.'},
    @{Name='VM ReSizer'; URL='https://github.com/TedInVR/VMReSizer'; Names=@('VM Re-Sizer','VM ReSizer','VMReSizer'); Description='VM Re-Sizer prepares stereo photos for View-Master-style reels. Frame, zoom and position both eyes together, preview the reel frame, and export separate left and right images at full resolution or Image3D-ready size.'},
    @{Name='Stereo Slideshow'; URL='https://github.com/TedInVR/StereoSlideshow'; Names=@('Stereo Slideshow','StereoSlideshow'); Description='Stereo Slideshow creates stereoscopic photo and video slideshows with music, titles, captions, fades and optional zoom or pan. Export side-by-side or red/cyan anaglyph video and save editable projects.'}
)
$script:relatedCustom = @()
$script:relatedLocations = @{}
if (Test-Path -LiteralPath $script:relatedAppsFile) {
    try {
        $settings = Get-Content -LiteralPath $script:relatedAppsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:relatedCustom = @($settings.custom | Where-Object { $_.name -and $_.path } | ForEach-Object { @{name=[string]$_.name; path=[string]$_.path} })
        foreach ($entry in $settings.builtins.PSObject.Properties) { $script:relatedLocations[$entry.Name] = [string]$entry.Value }
    } catch { Notice 'Apps menu' 'Saved app shortcuts could not be read. You can add them again from Apps.' }
}
function Save-RelatedApps {
    $directory = Split-Path $script:relatedAppsFile
    [void](New-Item -ItemType Directory -Path $directory -Force)
    $temporary = Join-Path $directory ([guid]::NewGuid().ToString() + '.tmp')
    try {
        @{custom=@($script:relatedCustom); builtins=$script:relatedLocations} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $script:relatedAppsFile -Force
    } finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}
function Pick-RelatedApp($title) {
    $picker = New-Object Windows.Forms.OpenFileDialog
    try {
        $picker.Title = $title
        $picker.Filter = 'Applications and shortcuts|*.exe;*.lnk;*.appref-ms|All files|*.*'
        $picker.CheckFileExists = $true
        if ($picker.ShowDialog($form) -eq 'OK') { return $picker.FileName }
    } finally { $picker.Dispose() }
}
function Open-RelatedApp($entry) {
    try {
        $paths = @()
        if ($entry.ContainsKey('URL')) {
            if ($script:relatedLocations.ContainsKey($entry.Name)) { $paths += $script:relatedLocations[$entry.Name] }
            # Discover shortcuts without assuming an individual user's install path.
            foreach ($folder in @([Environment]::GetFolderPath('Programs'),[Environment]::GetFolderPath('CommonPrograms'))) {
                if ($folder -and (Test-Path -LiteralPath $folder)) {
                    $paths += @(Get-ChildItem -LiteralPath $folder -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -in $entry.Names } | ForEach-Object { $_.FullName })
                }
            }
            foreach ($name in $entry.Names) {
                $command = Get-Command ($name + '.exe') -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($command) { $paths += $command.Source }
            }
        } else { $paths += $entry.path }
        $found = $paths | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
        if ($found) { Start-Process -FilePath $found; return }
        if (-not $entry.ContainsKey('URL')) {
            Notice 'App was not found' 'This shortcut points to a missing file. Remove the shortcut or add the app at its new location.'
            return
        }
        $dialog = New-Object Windows.Forms.Form
        try {
            $dialog.Text = $entry.Name + ' was not found'
            $dialog.StartPosition = 'CenterParent'; $dialog.ClientSize = New-Object Drawing.Size(575,175)
            $dialog.FormBorderStyle = 'FixedDialog'; $dialog.MaximizeBox = $false
            $message = New-Object Windows.Forms.Label
            $message.Text = 'Download the app, or locate it if it is already installed. TVT will remember its location. Some related projects require macOS.'
            $message.SetBounds(15,15,545,50); $dialog.Controls.Add($message)
            $dialog.Tag = $null
            foreach ($option in @(
                @{Title='Download from GitHub'; X=15; Y=75; Width=185; Result='download'},
                @{Title='Navigate to it'; X=210; Y=75; Width=160; Result='locate'},
                @{Title=('What is ' + $entry.Name + '?'); X=15; Y=120; Width=400; Result='description'},
                @{Title='OK'; X=460; Y=120; Width=95; Result='done'}
            )) {
                $button = New-Object Windows.Forms.Button
                $button.Text = $option.Title; $button.Tag = $option.Result
                $button.SetBounds($option.X,$option.Y,$option.Width,30)
                $button.Add_Click({ param($sender,$eventArgs) $sender.FindForm().Tag = $sender.Tag; $sender.FindForm().Close() })
                $dialog.Controls.Add($button)
            }
            do {
                $dialog.Tag = $null
                [void]$dialog.ShowDialog($form)
                if ($dialog.Tag -eq 'description') { Notice ('What is ' + $entry.Name + '?') $entry.Description }
            } while ($dialog.Tag -eq 'description')
            if ($dialog.Tag -eq 'download') { Start-Process $entry.URL }
            if ($dialog.Tag -eq 'locate') {
                $path = Pick-RelatedApp ('Locate ' + $entry.Name)
                if ($path) {
                    $script:relatedLocations[$entry.Name] = $path
                    $script:relatedCustom = @($script:relatedCustom | Where-Object { $_.path -ine $path })
                    Save-RelatedApps; Refresh-RelatedApps
                    Start-Process -FilePath $path
                }
            }
        } finally { $dialog.Dispose() }
    } catch { Notice 'Could not open app' $_.Exception.Message }
}
function Refresh-RelatedApps {
    $appsMenu.DropDownItems.Clear()
    foreach ($entry in $script:relatedBuiltins) {
        $item = $appsMenu.DropDownItems.Add($entry.Name + '...')
        $item.Tag = $entry
        $item.Add_Click({ param($sender,$eventArgs) Open-RelatedApp $sender.Tag })
    }
    if ($script:relatedCustom.Count) {
        [void]$appsMenu.DropDownItems.Add((New-Object Windows.Forms.ToolStripSeparator))
        foreach ($entry in $script:relatedCustom) {
            $item = $appsMenu.DropDownItems.Add($entry.name)
            $item.Tag = $entry
            $item.Add_Click({ param($sender,$eventArgs) Open-RelatedApp $sender.Tag })
        }
    }
    [void]$appsMenu.DropDownItems.Add((New-Object Windows.Forms.ToolStripSeparator))
    $item = $appsMenu.DropDownItems.Add('Add an App...')
    $item.Add_Click({
        try {
            $path = Pick-RelatedApp 'Choose an installed application'
            if (-not $path -or @($script:relatedCustom | Where-Object { $_.path -ieq $path }).Count) { return }
            $script:relatedCustom += @{name=[IO.Path]::GetFileNameWithoutExtension($path); path=$path}
            Save-RelatedApps; Refresh-RelatedApps
        } catch { Notice 'Could not save app shortcut' $_.Exception.Message }
    })
    if ($script:relatedCustom.Count) {
        $item = $appsMenu.DropDownItems.Add('Remove an Added App...')
        $item.Add_Click({
            try {
                $choice = Pick-Index 'Remove an Added App (shortcut only)' @($script:relatedCustom | ForEach-Object { $_.name })
                if ($choice -lt 0) { return }
                $remaining = @()
                for ($i=0; $i -lt $script:relatedCustom.Count; $i++) { if ($i -ne $choice) { $remaining += $script:relatedCustom[$i] } }
                $script:relatedCustom = $remaining
                Save-RelatedApps; Refresh-RelatedApps
            } catch { Notice 'Could not remove app shortcut' $_.Exception.Message }
        })
    }
}
Refresh-RelatedApps

try { [void]$form.ShowDialog() }
finally {
    $badge.Image.Dispose()
    $form.Icon.Dispose()
}
