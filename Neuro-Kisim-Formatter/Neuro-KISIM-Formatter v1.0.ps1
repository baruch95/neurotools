<#
.SYNOPSIS
    KISIM Formatter v1.0
#>
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Collections
Add-Type -AssemblyName Microsoft.VisualBasic

# --- 1. Fix DPI Scaling ---
try {
    $code = '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
    $win32 = Add-Type -MemberDefinition $code -Name "Win32" -Namespace Win32 -PassThru
    $null = $win32::SetProcessDPIAware()
} catch {}

# --- 2. Configuration & State ---
$script:configFile = Join-Path $PSScriptRoot "formatterv2_rules.json"
$script:sessionFile = Join-Path $PSScriptRoot "formatterv2_temp_session.json"
$script:snippetFile = Join-Path $PSScriptRoot "formatterv2_textbausteine.json"
$script:rules = New-Object System.Collections.ArrayList
$script:snippets = New-Object System.Collections.ArrayList
$script:globalFont = "Arial"
$script:tabCounter = 1
$script:isLoadingSession = $false

# Load Config
if (Test-Path $script:configFile) {
    try {
        $json = Get-Content $script:configFile -Raw | ConvertFrom-Json
        $script:globalFont = $json.font
        foreach($r in $json.rules) { [void]$script:rules.Add($r) }
    } catch {
        [void]$script:rules.Add(@{keyword="Sozialanamnese"; style="underline"})
    }
} else {
    [void]$script:rules.Add(@{keyword="Sozialanamnese"; style="underline"})
    [void]$script:rules.Add(@{keyword="$EEG vom *:$"; style="bold"})
}

if (Test-Path $script:snippetFile) {
    try {
        $snippetJson = Get-Content $script:snippetFile -Raw | ConvertFrom-Json
        foreach ($snip in $snippetJson) {
            if (-not [string]::IsNullOrWhiteSpace($snip.title) -and -not [string]::IsNullOrWhiteSpace($snip.content)) {
                [void]$script:snippets.Add([PSCustomObject]@{ title = [string]$snip.title; content = [string]$snip.content })
            }
        }
    } catch {}
}

if ($script:snippets.Count -eq 0) {
    [void]$script:snippets.Add([PSCustomObject]@{ title = "o.B."; content = "o.B." })
    [void]$script:snippets.Add([PSCustomObject]@{ title = "Pat. berichtet"; content = "Der Patient berichtet über " })
}

# --- 3. RTF Generation Logic ---
function Get-RTF {
    param($text)

    $rtfHeader = "{\rtf1\ansi\deff0{\fonttbl{\f0\fnil\fcharset0 $script:globalFont;}}"
    $rtfHeader += "{\colortbl ;\red255\green255\blue0;}"
    $rtfHeader += "\viewkind4\uc1\pard\lang1031\f0\fs22 "

    $safeText = $text -replace "\\", "\\" -replace "\{", "\{" -replace "\}", "\}"
    $safeText = $safeText -replace "`r`n", "\par " -replace "`n", "\par "

    $sortedRules = $script:rules | Sort-Object -Property @{Expression={$_.keyword.Length}} -Descending

    $tokenMap = @{}
    $tokenCounter = 0

    foreach ($rule in $sortedRules) {
        if (-not [string]::IsNullOrWhiteSpace($rule.keyword)) {
            $cleanKey = $rule.keyword
            $isWholeLine = $false

            if ($cleanKey.StartsWith("^") -and $cleanKey.EndsWith("$") -and $cleanKey.Length -gt 2) {
                $isWholeLine = $true
                $cleanKey = $cleanKey.Substring(1, $cleanKey.Length - 2)
            }
            elseif ($cleanKey.StartsWith("$") -and $cleanKey.EndsWith("$") -and $cleanKey.Length -gt 2) {
                $isWholeLine = $true
                $cleanKey = $cleanKey.Substring(1, $cleanKey.Length - 2)
            }

            $k = [Regex]::Escape($cleanKey)
            $k = $k -replace "\\\?", "."
            if ($k -match "\\\*$") { $k = $k -replace "\\\*$", "\S*" }
            $k = $k -replace "\\\*", ".*?"

            if ($isWholeLine) {
                $regexPattern = "(?:^|(?<=\\par ))($k)(?=$|\\par)"
            } else {
                $regexPattern = "($k)"
            }

            $tagStart = ""; $tagEnd = ""
            switch ($rule.style) {
                "bold"      { $tagStart = "\b "; $tagEnd = "\b0 " }
                "underline" { $tagStart = "\ul "; $tagEnd = "\ulnone " }
                "italic"    { $tagStart = "\i "; $tagEnd = "\i0 " }
                "highlight" { $tagStart = "\highlight1 "; $tagEnd = "\highlight0 " }
                "none"      { $tagStart = ""; $tagEnd = "" }
            }

            $safeText = [Regex]::Replace($safeText, $regexPattern, {
                param($match)

                $token = "##RTF_TOKEN_$($tokenCounter)##"
                Set-Variable -Name tokenCounter -Value ($tokenCounter + 1) -Scope 1

                $formattedString = "$tagStart$($match.Value)$tagEnd"
                $tokenMap[$token] = $formattedString

                return $token
            }, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
    }

    foreach ($key in $tokenMap.Keys) {
        $safeText = $safeText.Replace($key, $tokenMap[$key])
    }

    return $rtfHeader + $safeText + "}"
}

function Get-UniquePatientName {
    param([string]$baseName)
    $name = $baseName
    $counter = 2
    while ($tabPatients.TabPages | Where-Object { $_.Text -eq $name }) {
        $name = "$baseName ($counter)"
        $counter++
    }
    return $name
}

function Get-ActiveEditor {
    if (-not $tabPatients.SelectedTab) { return $null }
    if ($tabPatients.SelectedTab.Controls.Count -eq 0) { return $null }
    return $tabPatients.SelectedTab.Controls[0]
}

function Save-Snippets {
    $script:snippets | ConvertTo-Json -Depth 4 | Set-Content -Path $script:snippetFile -Encoding UTF8
}

function Insert-TextIntoActiveEditor {
    param([string]$text)
    $editor = Get-ActiveEditor
    if (-not $editor) { return }

    $selectionStart = $editor.SelectionStart
    $selectionLength = $editor.SelectionLength
    $currentText = $editor.Text

    $before = $currentText.Substring(0, $selectionStart)
    $after = $currentText.Substring($selectionStart + $selectionLength)
    $editor.Text = $before + $text + $after

    $newPos = $selectionStart + $text.Length
    $editor.SelectionStart = $newPos
    $editor.SelectionLength = 0
    $editor.Focus()
}

function Show-TextbausteineDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Textbausteine"
    $dlg.Size = New-Object System.Drawing.Size(720, 500)
    $dlg.StartPosition = "CenterParent"

    $splitDlg = New-Object System.Windows.Forms.SplitContainer
    $splitDlg.Dock = "Fill"
    $splitDlg.FixedPanel = "Panel1"
    $splitDlg.SplitterDistance = 240
    $dlg.Controls.Add($splitDlg)

    $list = New-Object System.Windows.Forms.ListBox
    $list.Dock = "Fill"
    $splitDlg.Panel1.Controls.Add($list)

    $pnlRightDlg = New-Object System.Windows.Forms.Panel
    $pnlRightDlg.Dock = "Fill"
    $splitDlg.Panel2.Controls.Add($pnlRightDlg)

    $lblTitleDlg = New-Object System.Windows.Forms.Label
    $lblTitleDlg.Text = "Titel"
    $lblTitleDlg.Dock = "Top"
    $pnlRightDlg.Controls.Add($lblTitleDlg)

    $txtSnippetTitle = New-Object System.Windows.Forms.TextBox
    $txtSnippetTitle.Dock = "Top"
    $pnlRightDlg.Controls.Add($txtSnippetTitle)

    $lblContentDlg = New-Object System.Windows.Forms.Label
    $lblContentDlg.Text = "Inhalt"
    $lblContentDlg.Dock = "Top"
    $pnlRightDlg.Controls.Add($lblContentDlg)

    $txtSnippetContent = New-Object System.Windows.Forms.TextBox
    $txtSnippetContent.Multiline = $true
    $txtSnippetContent.ScrollBars = "Vertical"
    $txtSnippetContent.Dock = "Fill"
    $pnlRightDlg.Controls.Add($txtSnippetContent)

    $pnlActionsDlg = New-Object System.Windows.Forms.FlowLayoutPanel
    $pnlActionsDlg.Dock = "Bottom"
    $pnlActionsDlg.Height = 42
    $pnlActionsDlg.FlowDirection = "LeftToRight"
    $pnlRightDlg.Controls.Add($pnlActionsDlg)

    $btnNewSnip = New-Object System.Windows.Forms.Button
    $btnNewSnip.Text = "Neu"
    $btnSaveSnip = New-Object System.Windows.Forms.Button
    $btnSaveSnip.Text = "Speichern"
    $btnDeleteSnip = New-Object System.Windows.Forms.Button
    $btnDeleteSnip.Text = "Löschen"
    $btnInsertSnip = New-Object System.Windows.Forms.Button
    $btnInsertSnip.Text = "Einfügen"
    $btnCloseDlg = New-Object System.Windows.Forms.Button
    $btnCloseDlg.Text = "Schließen"

    $pnlActionsDlg.Controls.AddRange(@($btnNewSnip, $btnSaveSnip, $btnDeleteSnip, $btnInsertSnip, $btnCloseDlg))

    $refreshSnipList = {
        $list.Items.Clear()
        foreach ($sn in $script:snippets) {
            [void]$list.Items.Add($sn.title)
        }
    }

    $loadSelected = {
        if ($list.SelectedIndex -lt 0) { return }
        $sel = $script:snippets[$list.SelectedIndex]
        $txtSnippetTitle.Text = [string]$sel.title
        $txtSnippetContent.Text = [string]$sel.content
    }

    $list.Add_SelectedIndexChanged($loadSelected)

    $btnNewSnip.Add_Click({
        $txtSnippetTitle.Text = ""
        $txtSnippetContent.Text = ""
        $list.ClearSelected()
        $txtSnippetTitle.Focus()
    })

    $btnSaveSnip.Add_Click({
        $title = $txtSnippetTitle.Text.Trim()
        $content = $txtSnippetContent.Text
        if ([string]::IsNullOrWhiteSpace($title) -or [string]::IsNullOrWhiteSpace($content)) {
            [System.Windows.Forms.MessageBox]::Show("Titel und Inhalt sind erforderlich.", "Hinweis")
            return
        }

        if ($list.SelectedIndex -ge 0) {
            $script:snippets[$list.SelectedIndex] = [PSCustomObject]@{ title = $title; content = $content }
        } else {
            [void]$script:snippets.Add([PSCustomObject]@{ title = $title; content = $content })
            $list.SelectedIndex = $script:snippets.Count - 1
        }

        Save-Snippets
        & $refreshSnipList
    })

    $btnDeleteSnip.Add_Click({
        if ($list.SelectedIndex -lt 0) { return }
        $idx = $list.SelectedIndex
        $confirm = [System.Windows.Forms.MessageBox]::Show("Textbaustein löschen?", "Löschen", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $script:snippets.RemoveAt($idx)
        Save-Snippets
        & $refreshSnipList
        $txtSnippetTitle.Text = ""
        $txtSnippetContent.Text = ""
    })

    $btnInsertSnip.Add_Click({
        if ($list.SelectedIndex -lt 0) { return }
        $sel = $script:snippets[$list.SelectedIndex]
        Insert-TextIntoActiveEditor -text ([string]$sel.content)
        Save-TempSession
        $dlg.Close()
    })

    $btnCloseDlg.Add_Click({ $dlg.Close() })

    $list.Add_DoubleClick({
        if ($list.SelectedIndex -lt 0) { return }
        $sel = $script:snippets[$list.SelectedIndex]
        Insert-TextIntoActiveEditor -text ([string]$sel.content)
        Save-TempSession
        $dlg.Close()
    })

    & $refreshSnipList
    if ($list.Items.Count -gt 0) { $list.SelectedIndex = 0 }

    [void]$dlg.ShowDialog($form)
}

function Save-TempSession {
    if (-not $tabPatients) { return }

    $patients = @()
    foreach ($tab in $tabPatients.TabPages) {
        $editor = $tab.Controls[0]
        $patients += [PSCustomObject]@{
            name = $tab.Text
            text = $editor.Text
        }
    }

    $session = [PSCustomObject]@{
        activePatient = if ($tabPatients.SelectedTab) { $tabPatients.SelectedTab.Text } else { $null }
        patients = $patients
    }

    $session | ConvertTo-Json -Depth 4 | Set-Content -Path $script:sessionFile -Encoding UTF8
}

function Add-PatientTab {
    param(
        [string]$name,
        [string]$text = "",
        [bool]$switchToTab = $true
    )

    $tabPage = New-Object System.Windows.Forms.TabPage
    $tabPage.Text = $name

    $editor = New-Object System.Windows.Forms.RichTextBox
    $editor.Dock = "Fill"
    $editor.ScrollBars = "Both"
    $editor.WordWrap = $true
    $editor.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $editor.Text = $text
    $editor.AcceptsTab = $true
    $editor.HideSelection = $false

    $editor.Add_TextChanged({
        if (-not $script:isLoadingSession) {
            Save-TempSession
        }
    })

    $editor.Add_KeyDown({
        param($sender, $e)

        $tb = [System.Windows.Forms.RichTextBox]$sender

        $findNextToken = {
            param([string]$text, [int]$startPos)
            if ([string]::IsNullOrEmpty($text)) { return $null }
            $left = $text.IndexOf('[', [Math]::Max(0, $startPos))
            if ($left -lt 0) { $left = $text.IndexOf('[', 0) }
            if ($left -lt 0) { return $null }
            $right = $text.IndexOf(']', $left + 1)
            if ($right -lt 0) { return $null }
            return @($left, $right)
        }

        $findPrevToken = {
            param([string]$text, [int]$startPos)
            if ([string]::IsNullOrEmpty($text)) { return $null }
            $left = $text.LastIndexOf('[', [Math]::Max(0, $startPos - 1))
            if ($left -lt 0) { $left = $text.LastIndexOf('[') }
            if ($left -lt 0) { return $null }
            $right = $text.IndexOf(']', $left + 1)
            if ($right -lt 0) { return $null }
            return @($left, $right)
        }

        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Tab) {
            $token = $null
            $currentText = $tb.Text
            if ($currentText.Contains('[') -and $currentText.Contains(']')) {
                $token = if ($e.Shift) {
                    & $findPrevToken $currentText ($tb.SelectionStart)
                } else {
                    & $findNextToken $currentText ($tb.SelectionStart + $tb.SelectionLength)
                }
            }

            if ($token) {
                $tb.Focus()
                $tb.Select($token[0], ($token[1] - $token[0] + 1))
            } elseif (-not $e.Shift) {
                $tb.SelectedText = "`t"
            }

            $e.SuppressKeyPress = $true
            $e.Handled = $true
            return
        }

        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter -and $tb.SelectionLength -gt 1) {
            $selStart = $tb.SelectionStart
            $selText = $tb.SelectedText
            if ($selText.StartsWith('[') -and $selText.EndsWith(']')) {
                $inner = $selText.Substring(1, $selText.Length - 2)
                $tb.SelectedText = $inner
                $newPos = $selStart + $inner.Length
                $tb.Select($newPos, 0)

                $token = & $findNextToken $tb.Text $newPos
                if ($token) {
                    $tb.Select($token[0], ($token[1] - $token[0] + 1))
                }
                $e.SuppressKeyPress = $true
                $e.Handled = $true
                return
            }
        }

        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Back -and $tb.SelectionLength -gt 1) {
            $selStart = $tb.SelectionStart
            $selText = $tb.SelectedText
            if ($selText.StartsWith('[') -and $selText.EndsWith(']')) {
                $tb.SelectedText = ""
                $tb.Select($selStart, 0)

                $token = & $findNextToken $tb.Text $selStart
                if ($token) {
                    $tb.Select($token[0], ($token[1] - $token[0] + 1))
                }
                $e.SuppressKeyPress = $true
                $e.Handled = $true
                return
            }
        }

        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            $caret = $tb.SelectionStart + $tb.SelectionLength
            $tb.Select($caret, 0)
            $e.SuppressKeyPress = $true
            $e.Handled = $true
        }
    })

    $tabPage.Controls.Add($editor)
    [void]$tabPatients.TabPages.Add($tabPage)

    if ($switchToTab) {
        $tabPatients.SelectedTab = $tabPage
        $editor.Focus()
    }

    return $tabPage
}

function Close-ActiveTab {
    if (-not $tabPatients.SelectedTab) { return }
    if ($tabPatients.TabCount -le 1) {
        [System.Windows.Forms.MessageBox]::Show("Mindestens ein Patient-Tab muss offen bleiben.", "Hinweis")
        return
    }

    $tabName = $tabPatients.SelectedTab.Text
    $answer = [System.Windows.Forms.MessageBox]::Show("Patient '$tabName' schließen?", "Patient schließen", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $tabPatients.TabPages.Remove($tabPatients.SelectedTab)
    Save-TempSession
}

function Load-TempSession {
    $script:isLoadingSession = $true
    try {
        $tabPatients.TabPages.Clear()

        if (Test-Path $script:sessionFile) {
            try {
                $session = Get-Content -Path $script:sessionFile -Raw | ConvertFrom-Json
                if ($session.patients -and $session.patients.Count -gt 0) {
                    foreach ($p in $session.patients) {
                        Add-PatientTab -name $p.name -text $p.text -switchToTab:$false | Out-Null
                    }
                    if ($session.activePatient) {
                        $active = $tabPatients.TabPages | Where-Object { $_.Text -eq $session.activePatient } | Select-Object -First 1
                        if ($active) { $tabPatients.SelectedTab = $active }
                    }
                }
            } catch {
                # fallback to clean startup
            }
        }

        if ($tabPatients.TabCount -eq 0) {
            Add-PatientTab -name "Patient 1" -switchToTab:$true | Out-Null
        }

        $script:tabCounter = $tabPatients.TabCount + 1
    } finally {
        $script:isLoadingSession = $false
    }
}

# --- 4. GUI SETUP ---
$form = New-Object System.Windows.Forms.Form
$form.Text = "Neuro-KISIM-Formatter V1.0"
$form.Size = New-Object System.Drawing.Size(1100, 700)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

# Split Container
$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = "Fill"
$split.SplitterWidth = 5
$split.FixedPanel = "Panel1"
$split.Panel1MinSize = 300
$form.Controls.Add($split)

# === LEFT PANEL ===
$pnlLeft = $split.Panel1
$pnlLeft.Padding = New-Object System.Windows.Forms.Padding(10)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = "Save Settings"
$btnSave.Dock = "Bottom"
$btnSave.Height = 35
$btnSave.BackColor = [System.Drawing.Color]::LightGray
$pnlLeft.Controls.Add($btnSave)

$btnRemove = New-Object System.Windows.Forms.Button
$btnRemove.Text = "Remove Selected Rule"
$btnRemove.Dock = "Bottom"
$btnRemove.Height = 30
$btnRemove.FlatStyle = "Flat"
$pnlLeft.Controls.Add($btnRemove)

$lblSpacer = New-Object System.Windows.Forms.Label; $lblSpacer.Height = 10; $lblSpacer.Dock = "Bottom"; $pnlLeft.Controls.Add($lblSpacer)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "Configuration"
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$lblTitle.AutoSize = $true
$lblTitle.Dock = "Top"
$pnlLeft.Controls.Add($lblTitle)

$grpFont = New-Object System.Windows.Forms.GroupBox; $grpFont.Text = "Global Font"; $grpFont.Height = 60; $grpFont.Dock = "Top"; $pnlLeft.Controls.Add($grpFont)
$cbFont = New-Object System.Windows.Forms.ComboBox
$cbFont.Items.AddRange(@("Arial", "Times New Roman", "Verdana", "Courier New", "Tahoma"))
$cbFont.Text = $script:globalFont
$cbFont.Location = New-Object System.Drawing.Point(10, 25); $cbFont.Width = 240
$grpFont.Controls.Add($cbFont)

$grpRule = New-Object System.Windows.Forms.GroupBox; $grpRule.Text = "Add Rule (supports *, ?, $, s. Anleitung)"; $grpRule.Height = 130; $grpRule.Dock = "Top"; $pnlLeft.Controls.Add($grpRule)

$txtKey = New-Object System.Windows.Forms.TextBox
$txtKey.Location = New-Object System.Drawing.Point(10, 25); $txtKey.Width = 240
$grpRule.Controls.Add($txtKey)

$cbStyle = New-Object System.Windows.Forms.ComboBox
$cbStyle.Location = New-Object System.Drawing.Point(10, 55); $cbStyle.Width = 240
$cbStyle.Items.AddRange(@("bold", "underline", "italic", "highlight", "none"))
$cbStyle.SelectedIndex = 0
$grpRule.Controls.Add($cbStyle)

$btnAdd = New-Object System.Windows.Forms.Button
$btnAdd.Text = "Add Rule"
$btnAdd.Location = New-Object System.Drawing.Point(10, 90); $btnAdd.Width = 240; $btnAdd.BackColor = [System.Drawing.Color]::WhiteSmoke
$grpRule.Controls.Add($btnAdd)

$lblSpacer2 = New-Object System.Windows.Forms.Label; $lblSpacer2.Height = 10; $lblSpacer2.Dock = "Top"; $pnlLeft.Controls.Add($lblSpacer2)

$lblListHeader = New-Object System.Windows.Forms.Label; $lblListHeader.Text = "Active Rules:"; $lblListHeader.Dock = "Top"; $lblListHeader.Height = 20; $pnlLeft.Controls.Add($lblListHeader)

$lstRules = New-Object System.Windows.Forms.ListBox
$lstRules.Dock = "Fill"
$lstRules.IntegralHeight = $false
$pnlLeft.Controls.Add($lstRules)
$lstRules.BringToFront()

# === RIGHT PANEL ===
$pnlRight = $split.Panel2
$pnlRight.Padding = New-Object System.Windows.Forms.Padding(10)

$lblInput = New-Object System.Windows.Forms.Label
$lblInput.Text = "Input Text (Patient Tabs):"
$lblInput.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$lblInput.Dock = "Top"
$lblInput.Height = 25
$pnlRight.Controls.Add($lblInput)

$btnCopy = New-Object System.Windows.Forms.Button
$btnCopy.Text = "FORMAT & COPY TO CLIPBOARD"
$btnCopy.Dock = "Bottom"
$btnCopy.Height = 55
$btnCopy.BackColor = [System.Drawing.Color]::DodgerBlue
$btnCopy.ForeColor = [System.Drawing.Color]::White
$btnCopy.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$btnCopy.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnCopy.FlatStyle = "Flat"
$pnlRight.Controls.Add($btnCopy)

$lblSpacerRight = New-Object System.Windows.Forms.Label; $lblSpacerRight.Height = 10; $lblSpacerRight.Dock = "Bottom"; $pnlRight.Controls.Add($lblSpacerRight)

$pnlTabActions = New-Object System.Windows.Forms.Panel
$pnlTabActions.Dock = "Top"
$pnlTabActions.Height = 40
$pnlRight.Controls.Add($pnlTabActions)

$btnNewTab = New-Object System.Windows.Forms.Button
$btnNewTab.Text = "+ Patient"
$btnNewTab.Width = 95
$btnNewTab.Height = 28
$btnNewTab.Location = New-Object System.Drawing.Point(0, 6)
$pnlTabActions.Controls.Add($btnNewTab)

$btnRenameTab = New-Object System.Windows.Forms.Button
$btnRenameTab.Text = "Rename"
$btnRenameTab.Width = 90
$btnRenameTab.Height = 28
$btnRenameTab.Location = New-Object System.Drawing.Point(100, 6)
$pnlTabActions.Controls.Add($btnRenameTab)

$btnCloseTab = New-Object System.Windows.Forms.Button
$btnCloseTab.Text = "Close"
$btnCloseTab.Width = 90
$btnCloseTab.Height = 28
$btnCloseTab.Location = New-Object System.Drawing.Point(195, 6)
$pnlTabActions.Controls.Add($btnCloseTab)

$btnTextbausteine = New-Object System.Windows.Forms.Button
$btnTextbausteine.Text = "Textbausteine"
$btnTextbausteine.Width = 110
$btnTextbausteine.Height = 28
$btnTextbausteine.Location = New-Object System.Drawing.Point(290, 6)
$pnlTabActions.Controls.Add($btnTextbausteine)

$tabPatients = New-Object System.Windows.Forms.TabControl
$tabPatients.Dock = "Fill"
$tabPatients.Multiline = $true
$pnlRight.Controls.Add($tabPatients)
$tabPatients.BringToFront()

# --- 5. LOGIC & EVENTS ---

function Refresh-List {
    $lstRules.Items.Clear()
    foreach ($r in $script:rules) {
        $lstRules.Items.Add("$($r.style.ToUpper()) - '$($r.keyword)'")
    }
}

$btnAdd.Add_Click({
    if (-not [string]::IsNullOrWhiteSpace($txtKey.Text)) {
        $newRule = @{keyword=$txtKey.Text; style=$cbStyle.Text}
        [void]$script:rules.Add($newRule)
        Refresh-List
        $txtKey.Text = ""
        $txtKey.Focus()
    }
})

$btnRemove.Add_Click({
    if ($lstRules.SelectedIndex -ge 0) {
        $script:rules.RemoveAt($lstRules.SelectedIndex)
        Refresh-List
    }
})

$btnSave.Add_Click({
    $script:globalFont = $cbFont.Text
    $export = @{ font = $script:globalFont; rules = $script:rules }
    $json = $export | ConvertTo-Json -Depth 3
    $json | Set-Content $script:configFile -Encoding UTF8
    [System.Windows.Forms.MessageBox]::Show("Settings saved!", "Saved")
})

$btnNewTab.Add_Click({
    $suggested = "Patient $script:tabCounter"
    $nameInput = [Microsoft.VisualBasic.Interaction]::InputBox("Name für neuen Patienten:", "Neuer Patient", $suggested)
    if ([string]::IsNullOrWhiteSpace($nameInput)) { return }

    $name = Get-UniquePatientName -baseName $nameInput.Trim()
    Add-PatientTab -name $name -switchToTab:$true | Out-Null
    $script:tabCounter++
    Save-TempSession
})

$btnRenameTab.Add_Click({
    if (-not $tabPatients.SelectedTab) { return }
    $current = $tabPatients.SelectedTab.Text
    $newName = [Microsoft.VisualBasic.Interaction]::InputBox("Neuer Name:", "Patient umbenennen", $current)
    if ([string]::IsNullOrWhiteSpace($newName)) { return }

    $trimmed = $newName.Trim()
    $alreadyExists = $tabPatients.TabPages | Where-Object { $_ -ne $tabPatients.SelectedTab -and $_.Text -eq $trimmed }
    if ($alreadyExists) {
        [System.Windows.Forms.MessageBox]::Show("Name existiert bereits.", "Hinweis")
        return
    }

    $tabPatients.SelectedTab.Text = $trimmed
    Save-TempSession
})

$btnCloseTab.Add_Click({ Close-ActiveTab })
$btnTextbausteine.Add_Click({ Show-TextbausteineDialog })
$tabPatients.Add_SelectedIndexChanged({ Save-TempSession })

$btnCopy.Add_Click({
    $editor = Get-ActiveEditor
    if (-not $editor) { return }

    $raw = $editor.Text
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    $script:globalFont = $cbFont.Text

    $rtfData = Get-RTF -text $raw

    try {
        [System.Windows.Forms.Clipboard]::SetText($rtfData, [System.Windows.Forms.TextDataFormat]::Rtf)
        $editor.Rtf = $rtfData

        $originalText = $btnCopy.Text
        $originalColor = $btnCopy.BackColor
        $btnCopy.Text = "COPIED SUCCESSFULLY!"
        $btnCopy.BackColor = [System.Drawing.Color]::SeaGreen
        $form.Refresh()
        Start-Sleep -Milliseconds 750
        $btnCopy.Text = $originalText
        $btnCopy.BackColor = $originalColor

        Save-TempSession
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Error accessing clipboard.", "Error")
    }
})

$form.Add_FormClosing({
    param($sender, $e)
    $result = [System.Windows.Forms.MessageBox]::Show(
        "Möchten Sie die geöffneten Patientendaten als temporäre Datei speichern?`n`nJa = Speichern und beenden`nNein = Ohne Speichern beenden (Temp-Datei löschen)`nAbbrechen = Zurück zur App",
        "Programm beenden",
        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    switch ($result) {
        ([System.Windows.Forms.DialogResult]::Yes) {
            Save-TempSession
        }
        ([System.Windows.Forms.DialogResult]::No) {
            if (Test-Path $script:sessionFile) {
                Remove-Item -Path $script:sessionFile -Force -ErrorAction SilentlyContinue
            }
        }
        default {
            $e.Cancel = $true
        }
    }
})

# --- Run ---
Refresh-List
$form.Add_Shown({
    Load-TempSession
    $editor = Get-ActiveEditor
    if ($editor) { $editor.Focus() }
})
$form.Add_Load({ $split.SplitterDistance = 320 })
Clear-Host
Write-Host "-----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "   Neuro-KISIM-Formatter V1.0" -ForegroundColor White
Write-Host "   Created with ♥ by Nicolò " -ForegroundColor White
Write-Host "-----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host " "
Write-Host "-----------------------------------------------------------------" -ForegroundColor White
Write-Host "   Du kannst dieses Fenster minimieren, aber nicht schliessen" -ForegroundColor Red
Write-Host "-----------------------------------------------------------------" -ForegroundColor White
[void] $form.ShowDialog()
