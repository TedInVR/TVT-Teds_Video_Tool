$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
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
$heading.Text = "Ted's Video Tool for 2D, 3D and VR"
$heading.Font = New-Object Drawing.Font('Segoe UI', 16, [Drawing.FontStyle]::Bold)
$heading.TextAlign = 'MiddleLeft'
$heading.SetBounds(76, 32, 536, 38)
$form.Controls.Add($heading)
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
    @{ Title = 'Picture and Format'; X = 322; Y = 127; Tools = @('Upscale Video','Convert Video','Change Aspect or Stereo Layout') },
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
    if ($arguments[0] -in @('batch-item','upscale','convert','audio','layout','trim')) {
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
function Start-Engine([string[]]$arguments, [string]$reportName, [string]$trimSource, [string]$discSource) {
    $script:job = New-EngineProcess $arguments
    $script:job.Report = $reportName
    $script:job.TrimSource = $trimSource
    $script:job.DiscSource = $discSource
    foreach ($button in $buttons) { $button.Enabled = $false }
    $browse.Enabled = $false
    $clear.Enabled = $false
    $script:resultPath = $null
    $reveal.Visible = $false
    $messages = @{
        split='Splitting movie'; join='Joining parts'; link='Linking videos'; upscale='Upscaling video'
        convert='Converting video'; download='Downloading media'; audio='Processing audio'
        subtitles='Preparing subtitles'; layout='Changing video layout'; info='Reading media information'
        duration='Opening trim editor'; trim='Exporting selected clip'
        'disc-scan'='Scanning disc backup'; 'disc-import'='Importing disc title'; 'batch-item'='Processing batch item'
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
    $trimSource = $job.TrimSource
    $discSource = $job.DiscSource
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
        if ($discSource) {
            try { Complete-DiscScan $discSource @(ConvertFrom-Json $result) }
            catch { Notice 'Disc import failed' $_.Exception.Message }
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
    if ($source -and $source -match '\.mkv$' -and (Test-Path -LiteralPath $source -PathType Leaf)) {
        if (-not (Confirm 'Convert MVC MKV to Full Side-by-Side?' 'Choose this for an MKV that still contains both Blu-ray 3D views.')) { return }
        $destination = Pick-Output $source 'mkv' 'Full SBS'
        if ($destination) { Start-Engine @('disc-import',$source,'0','mvc',$destination) }
    } elseif ($source) { Start-Engine @('disc-scan',$source) -discSource $source }
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
            'Trim Clip' {
                Start-Engine @('duration',$file) -trimSource $file
            }
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
                if ($files.Count -gt 1) { Start-Batch 'upscale' $height $files; return }
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
                $choice = Pick-Index 'Convert Video - choose the output format' @($profiles | ForEach-Object { $_[1] })
                if ($choice -lt 0) { return }
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
    if ($job -or $script:trim) { if ($manual) { Notice 'TVT' 'Wait until the current operation finishes.' }; return }
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
try { [void]$form.ShowDialog() }
finally {
    $badge.Image.Dispose()
    $form.Icon.Dispose()
}
