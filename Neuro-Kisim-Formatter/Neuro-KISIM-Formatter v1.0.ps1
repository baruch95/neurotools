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
$script:textbausteinForm = $null
$script:rulesForm = $null
$script:sidebarFilteredSnippets = @()
$script:autoSaveTimer = $null

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
                $cats = @()
                if ($snip.categories) {
                    foreach ($c in $snip.categories) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$c)) { $cats += ([string]$c).Trim() }
                    }
                } elseif ($snip.category) {
                    $cats += ([string]$snip.category).Trim()
                }
                if ($cats.Count -eq 0) { $cats = @('Allgemein') }

                [void]$script:snippets.Add([PSCustomObject]@{ title = [string]$snip.title; content = [string]$snip.content; categories = $cats })
            }
        }
    } catch {}
}

if ($script:snippets.Count -eq 0) {
    [void]$script:snippets.Add([PSCustomObject]@{ title = "o.B."; content = "o.B."; categories = @("Allgemein") })
    [void]$script:snippets.Add([PSCustomObject]@{ title = "Pat. berichtet"; content = "Der Patient berichtet über "; categories = @("Allgemein") })
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

function Ensure-SnippetState {
    if (-not $script:snippets) {
        $script:snippets = New-Object System.Collections.ArrayList
    }

    if ($script:snippets -isnot [System.Collections.ArrayList]) {
        $arr = New-Object System.Collections.ArrayList
        foreach ($item in @($script:snippets)) { [void]$arr.Add($item) }
        $script:snippets = $arr
    }

    for ($i = 0; $i -lt $script:snippets.Count; $i++) {
        $item = $script:snippets[$i]
        if (-not $item) { continue }

        $cats = @()
        if ($item.PSObject.Properties.Name -contains 'categories' -and $item.categories) {
            foreach ($c in @($item.categories)) {
                $tag = [string]$c
                if (-not [string]::IsNullOrWhiteSpace($tag) -and ($cats -notcontains $tag.Trim())) { $cats += $tag.Trim() }
            }
        }
        elseif ($item.PSObject.Properties.Name -contains 'category' -and $item.category) {
            $tag = ([string]$item.category).Trim()
            if (-not [string]::IsNullOrWhiteSpace($tag)) { $cats += $tag }
        }
        if ($cats.Count -eq 0) { $cats = @('Allgemein') }

        $script:snippets[$i] = [PSCustomObject]@{
            title = [string]$item.title
            content = [string]$item.content
            categories = $cats
        }
    }
}

function Save-Snippets {
    Ensure-SnippetState
    $script:snippets | ConvertTo-Json -Depth 5 | Set-Content -Path $script:snippetFile -Encoding UTF8
}

function Get-SnippetCategories {
    Ensure-SnippetState
    $cats = New-Object System.Collections.Generic.HashSet[string]
    foreach ($sn in $script:snippets) {
        if ($sn.categories) {
            foreach ($c in $sn.categories) {
                if (-not [string]::IsNullOrWhiteSpace([string]$c)) {
                    [void]$cats.Add(([string]$c).Trim())
                }
            }
        }
    }
    return $cats | Sort-Object
}

function Update-SnippetFilterOptions {
    if (-not $cbSnippetFilter) { return }

    $selected = [string]$cbSnippetFilter.SelectedItem
    $cbSnippetFilter.Items.Clear()
    [void]$cbSnippetFilter.Items.Add('All')
    foreach ($cat in (Get-SnippetCategories)) {
        [void]$cbSnippetFilter.Items.Add($cat)
    }

    if (-not [string]::IsNullOrWhiteSpace($selected) -and $cbSnippetFilter.Items.Contains($selected)) {
        $cbSnippetFilter.SelectedItem = $selected
    } else {
        $cbSnippetFilter.SelectedIndex = 0
    }
}

function Refresh-SnippetSidebar {
    Ensure-SnippetState
    if (-not $lstSnippetSidebar) { return }

    $lstSnippetSidebar.Items.Clear()
    $script:sidebarFilteredSnippets = @()

    $selectedFilter = if ($cbSnippetFilter -and $cbSnippetFilter.SelectedItem) { [string]$cbSnippetFilter.SelectedItem } else { 'All' }

    foreach ($sn in $script:snippets) {
        $matches = $true
        if ($selectedFilter -ne 'All') {
            $matches = $false
            if ($sn.categories) {
                foreach ($c in $sn.categories) {
                    if ([string]$c -eq $selectedFilter) { $matches = $true; break }
                }
            }
        }

        if ($matches) {
            $script:sidebarFilteredSnippets += $sn
            [void]$lstSnippetSidebar.Items.Add([string]$sn.title)
        }
    }
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
    Ensure-SnippetState

    if ($script:textbausteinForm -and -not $script:textbausteinForm.IsDisposed) {
        $script:textbausteinForm.BringToFront()
        $script:textbausteinForm.Focus()
        return
    }

    $dlg = New-Object System.Windows.Forms.Form
    $script:textbausteinForm = $dlg
    $dlg.Text = "Textbausteine-Editor"
    $dlg.Size = New-Object System.Drawing.Size(800, 560)
    $dlg.StartPosition = "CenterScreen"

    $splitDlg = New-Object System.Windows.Forms.SplitContainer
    $splitDlg.Dock = "Fill"
    $splitDlg.FixedPanel = "Panel1"
    $splitDlg.SplitterDistance = 260
    $dlg.Controls.Add($splitDlg)

    $list = New-Object System.Windows.Forms.ListBox
    $list.Dock = "Fill"
    $splitDlg.Panel1.Controls.Add($list)

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = "Fill"
    $layout.RowCount = 3
    $layout.ColumnCount = 1
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 130)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 44)))
    $splitDlg.Panel2.Controls.Add($layout)

    $pnlFields = New-Object System.Windows.Forms.Panel
    $pnlFields.Dock = "Fill"
    $layout.Controls.Add($pnlFields, 0, 0)

    $lblTitleDlg = New-Object System.Windows.Forms.Label
    $lblTitleDlg.Text = "Titel"
    $lblTitleDlg.AutoSize = $true
    $lblTitleDlg.Location = New-Object System.Drawing.Point(0, 4)
    $pnlFields.Controls.Add($lblTitleDlg)

    $txtSnippetTitle = New-Object System.Windows.Forms.TextBox
    $txtSnippetTitle.Location = New-Object System.Drawing.Point(0, 22)
    $txtSnippetTitle.Width = 490
    $txtSnippetTitle.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $pnlFields.Controls.Add($txtSnippetTitle)

    $lblCategoriesDlg = New-Object System.Windows.Forms.Label
    $lblCategoriesDlg.Text = "Kategorien / Tags (Komma-getrennt)"
    $lblCategoriesDlg.AutoSize = $true
    $lblCategoriesDlg.Location = New-Object System.Drawing.Point(0, 52)
    $pnlFields.Controls.Add($lblCategoriesDlg)

    $txtSnippetCategories = New-Object System.Windows.Forms.TextBox
    $txtSnippetCategories.Location = New-Object System.Drawing.Point(0, 70)
    $txtSnippetCategories.Width = 490
    $txtSnippetCategories.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $pnlFields.Controls.Add($txtSnippetCategories)

    $lblContentDlg = New-Object System.Windows.Forms.Label
    $lblContentDlg.Text = "Inhalt"
    $lblContentDlg.AutoSize = $true
    $lblContentDlg.Location = New-Object System.Drawing.Point(0, 100)
    $pnlFields.Controls.Add($lblContentDlg)

    $txtSnippetContent = New-Object System.Windows.Forms.TextBox
    $txtSnippetContent.Multiline = $true
    $txtSnippetContent.ScrollBars = "Vertical"
    $txtSnippetContent.Dock = "Fill"
    $layout.Controls.Add($txtSnippetContent, 0, 1)

    $pnlActionsDlg = New-Object System.Windows.Forms.FlowLayoutPanel
    $pnlActionsDlg.Dock = "Fill"
    $pnlActionsDlg.FlowDirection = "LeftToRight"
    $layout.Controls.Add($pnlActionsDlg, 0, 2)

    $btnNewSnip = New-Object System.Windows.Forms.Button; $btnNewSnip.Text = "Neu"
    $btnSaveSnip = New-Object System.Windows.Forms.Button; $btnSaveSnip.Text = "Speichern"
    $btnDeleteSnip = New-Object System.Windows.Forms.Button; $btnDeleteSnip.Text = "Löschen"
    $btnInsertSnip = New-Object System.Windows.Forms.Button; $btnInsertSnip.Text = "Einfügen"
    $btnCloseDlg = New-Object System.Windows.Forms.Button; $btnCloseDlg.Text = "Schließen"
    $pnlActionsDlg.Controls.AddRange(@($btnNewSnip, $btnSaveSnip, $btnDeleteSnip, $btnInsertSnip, $btnCloseDlg))

    $refreshSnipList = {
        Ensure-SnippetState
        $list.Items.Clear()
        foreach ($sn in $script:snippets) { [void]$list.Items.Add([string]$sn.title) }
    }

    $loadSelected = {
        Ensure-SnippetState
        if ($list.SelectedIndex -lt 0) { return }
        if ($list.SelectedIndex -ge $script:snippets.Count) { return }

        $sel = $script:snippets[$list.SelectedIndex]
        if (-not $sel) { return }

        $txtSnippetTitle.Text = [string]$sel.title
        $txtSnippetContent.Text = [string]$sel.content
        $txtSnippetCategories.Text = if ($sel.categories) { (@($sel.categories) -join ', ') } else { '' }
    }

    $list.Add_SelectedIndexChanged($loadSelected.GetNewClosure())

    $btnNewSnip.Add_Click({
        $txtSnippetTitle.Text = ''
        $txtSnippetContent.Text = ''
        $txtSnippetCategories.Text = ''
        $list.ClearSelected()
        $txtSnippetTitle.Focus()
    }.GetNewClosure())

    $btnSaveSnip.Add_Click({
        Ensure-SnippetState

        $title = [string]$txtSnippetTitle.Text
        if (-not [string]::IsNullOrWhiteSpace($title)) { $title = $title.Trim() }
        $content = [string]$txtSnippetContent.Text

        if ([string]::IsNullOrWhiteSpace($title) -or [string]::IsNullOrWhiteSpace($content)) {
            [System.Windows.Forms.MessageBox]::Show("Titel und Inhalt sind erforderlich.", "Hinweis")
            return
        }

        $cats = @()
        foreach ($part in ([string]$txtSnippetCategories.Text -split ',')) {
            $tag = $part.Trim()
            if (-not [string]::IsNullOrWhiteSpace($tag) -and ($cats -notcontains $tag)) { $cats += $tag }
        }
        if ($cats.Count -eq 0) { $cats = @('Allgemein') }

        $obj = [PSCustomObject]@{ title = $title; content = $content; categories = $cats }

        if ($list.SelectedIndex -ge 0 -and $list.SelectedIndex -lt $script:snippets.Count) {
            $script:snippets[$list.SelectedIndex] = $obj
        } else {
            [void]$script:snippets.Add($obj)
            $list.SelectedIndex = $script:snippets.Count - 1
        }

        Save-Snippets
        & $refreshSnipList
        Update-SnippetFilterOptions
        Refresh-SnippetSidebar
        [System.Windows.Forms.MessageBox]::Show("Textbaustein gespeichert.", "Saved")
    }.GetNewClosure())

    $btnDeleteSnip.Add_Click({
        Ensure-SnippetState
        if ($list.SelectedIndex -lt 0 -or $list.SelectedIndex -ge $script:snippets.Count) { return }

        $confirm = [System.Windows.Forms.MessageBox]::Show("Textbaustein löschen?", "Löschen", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $script:snippets.RemoveAt($list.SelectedIndex)
        Save-Snippets
        & $refreshSnipList
        Update-SnippetFilterOptions
        Refresh-SnippetSidebar

        $txtSnippetTitle.Text = ''
        $txtSnippetContent.Text = ''
        $txtSnippetCategories.Text = ''
    }.GetNewClosure())

    $btnInsertSnip.Add_Click({
        Ensure-SnippetState
        if ($list.SelectedIndex -lt 0 -or $list.SelectedIndex -ge $script:snippets.Count) { return }
        $sel = $script:snippets[$list.SelectedIndex]
        Insert-TextIntoActiveEditor -text ([string]$sel.content)
        Save-TempSession
    }.GetNewClosure())

    $btnCloseDlg.Add_Click({ $dlg.Close() }.GetNewClosure())

    $list.Add_DoubleClick({
        Ensure-SnippetState
        if ($list.SelectedIndex -lt 0 -or $list.SelectedIndex -ge $script:snippets.Count) { return }
        $sel = $script:snippets[$list.SelectedIndex]
        Insert-TextIntoActiveEditor -text ([string]$sel.content)
        Save-TempSession
    }.GetNewClosure())

    $dlg.Add_FormClosed({ $script:textbausteinForm = $null }.GetNewClosure())

    & $refreshSnipList
    if ($list.Items.Count -gt 0) { $list.SelectedIndex = 0 }

    $dlg.Show()
}

function Show-RulesEditor {
    if ($script:rulesForm -and -not $script:rulesForm.IsDisposed) {
        $script:rulesForm.BringToFront()
        $script:rulesForm.Focus()
        return
    }

    $dlg = New-Object System.Windows.Forms.Form
    $script:rulesForm = $dlg
    $dlg.Text = 'Regel-Editor'
    $dlg.Size = New-Object System.Drawing.Size(520, 560)
    $dlg.StartPosition = 'CenterScreen'

    $pnl = New-Object System.Windows.Forms.Panel
    $pnl.Dock = 'Fill'
    $pnl.Padding = New-Object System.Windows.Forms.Padding(10)
    $dlg.Controls.Add($pnl)

    $lst = New-Object System.Windows.Forms.ListBox
    $lst.Dock = 'Fill'
    $pnl.Controls.Add($lst)

    $grp = New-Object System.Windows.Forms.GroupBox
    $grp.Text = 'Regel hinzufügen / bearbeiten'
    $grp.Dock = 'Top'
    $grp.Height = 140
    $pnl.Controls.Add($grp)

    $txtK = New-Object System.Windows.Forms.TextBox
    $txtK.Location = New-Object System.Drawing.Point(10, 26)
    $txtK.Width = 470
    $grp.Controls.Add($txtK)

    $cbS = New-Object System.Windows.Forms.ComboBox
    $cbS.Location = New-Object System.Drawing.Point(10, 56)
    $cbS.Width = 470
    $cbS.Items.AddRange(@('bold','underline','italic','highlight','none'))
    $cbS.SelectedIndex = 0
    $grp.Controls.Add($cbS)

    $btnAddR = New-Object System.Windows.Forms.Button
    $btnAddR.Text = 'Regel hinzufügen'
    $btnAddR.Location = New-Object System.Drawing.Point(10, 90)
    $btnAddR.Width = 150
    $grp.Controls.Add($btnAddR)

    $btnDelR = New-Object System.Windows.Forms.Button
    $btnDelR.Text = 'Ausgewählte Regel löschen'
    $btnDelR.Dock = 'Bottom'
    $btnDelR.Height = 32
    $pnl.Controls.Add($btnDelR)

    $lblFontR = New-Object System.Windows.Forms.Label
    $lblFontR.Text = 'Global Font'
    $lblFontR.Dock = 'Bottom'
    $lblFontR.Height = 18
    $pnl.Controls.Add($lblFontR)

    $cbFontR = New-Object System.Windows.Forms.ComboBox
    $cbFontR.Dock = 'Bottom'
    $cbFontR.Items.AddRange(@('Arial','Times New Roman','Verdana','Courier New','Tahoma'))
    $cbFontR.Text = $script:globalFont
    $pnl.Controls.Add($cbFontR)

    $btnSaveR = New-Object System.Windows.Forms.Button
    $btnSaveR.Text = 'Regeln + Font speichern'
    $btnSaveR.Dock = 'Bottom'
    $btnSaveR.Height = 36
    $pnl.Controls.Add($btnSaveR)

    $refreshRulesList = {
        $lst.Items.Clear()
        foreach ($r in $script:rules) { [void]$lst.Items.Add("$($r.style.ToUpper()) - '$($r.keyword)'") }
    }

    $btnAddR.Add_Click({
        if (-not [string]::IsNullOrWhiteSpace($txtK.Text)) {
            [void]$script:rules.Add(@{ keyword = $txtK.Text; style = $cbS.Text })
            & $refreshRulesList
            $txtK.Text = ''
            $txtK.Focus()
        }
    }.GetNewClosure())

    $btnDelR.Add_Click({
        if ($lst.SelectedIndex -ge 0) {
            $script:rules.RemoveAt($lst.SelectedIndex)
            & $refreshRulesList
        }
    }.GetNewClosure())

    $btnSaveR.Add_Click({
        $script:globalFont = $cbFontR.Text
        $export = @{ font = $script:globalFont; rules = $script:rules }
        $json = $export | ConvertTo-Json -Depth 3
        $json | Set-Content $script:configFile -Encoding UTF8
        [System.Windows.Forms.MessageBox]::Show('Regeln und Font gespeichert!', 'Saved')
    }.GetNewClosure())

    $dlg.Add_FormClosed({ $script:rulesForm = $null }.GetNewClosure())
    & $refreshRulesList
    $dlg.Show()
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
$form.Text = "Neuro-KISIM-Formatter V1.2"
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

$lblSnipTitle = New-Object System.Windows.Forms.Label
$lblSnipTitle.Text = "Textbausteine"
$lblSnipTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$lblSnipTitle.AutoSize = $true
$lblSnipTitle.Dock = "Top"
$pnlLeft.Controls.Add($lblSnipTitle)

$lblFilter = New-Object System.Windows.Forms.Label
$lblFilter.Text = "Filter"
$lblFilter.Dock = "Top"
$lblFilter.Height = 18
$pnlLeft.Controls.Add($lblFilter)

$cbSnippetFilter = New-Object System.Windows.Forms.ComboBox
$cbSnippetFilter.Dock = "Top"
$cbSnippetFilter.DropDownStyle = "DropDownList"
$pnlLeft.Controls.Add($cbSnippetFilter)

$btnSnippetEditor = New-Object System.Windows.Forms.Button
$btnSnippetEditor.Text = "Textbaustein-Editor"
$btnSnippetEditor.Dock = "Top"
$btnSnippetEditor.Height = 30
$pnlLeft.Controls.Add($btnSnippetEditor)

$btnRulesEditor = New-Object System.Windows.Forms.Button
$btnRulesEditor.Text = "Regel-Editor"
$btnRulesEditor.Dock = "Top"
$btnRulesEditor.Height = 30
$pnlLeft.Controls.Add($btnRulesEditor)

$lstSnippetSidebar = New-Object System.Windows.Forms.ListBox
$lstSnippetSidebar.Dock = "Fill"
$lstSnippetSidebar.IntegralHeight = $false
$pnlLeft.Controls.Add($lstSnippetSidebar)
$lstSnippetSidebar.BringToFront()

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

$tabPatients = New-Object System.Windows.Forms.TabControl
$tabPatients.Dock = "Fill"
$tabPatients.Multiline = $true
$pnlRight.Controls.Add($tabPatients)
$tabPatients.BringToFront()

# --- 5. LOGIC & EVENTS ---

$btnSnippetEditor.Add_Click({ Show-TextbausteineDialog })
$btnRulesEditor.Add_Click({ Show-RulesEditor })

$cbSnippetFilter.Add_SelectedIndexChanged({ Refresh-SnippetSidebar })

$lstSnippetSidebar.Add_DoubleClick({
    $idx = $lstSnippetSidebar.SelectedIndex
    if ($idx -lt 0 -or $idx -ge $script:sidebarFilteredSnippets.Count) { return }
    $snippet = $script:sidebarFilteredSnippets[$idx]
    Insert-TextIntoActiveEditor -text ([string]$snippet.content)
    Save-TempSession
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
$tabPatients.Add_SelectedIndexChanged({ Save-TempSession })

$btnCopy.Add_Click({
    $editor = Get-ActiveEditor
    if (-not $editor) { return }

    $raw = $editor.Text
    if ([string]::IsNullOrWhiteSpace($raw)) { return }

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
    if ($script:autoSaveTimer) { $script:autoSaveTimer.Stop() }
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
            if ($script:autoSaveTimer) { $script:autoSaveTimer.Start() }
        }
    }
})

$script:autoSaveTimer = New-Object System.Windows.Forms.Timer
$script:autoSaveTimer.Interval = 10000
$script:autoSaveTimer.Add_Tick({
    try {
        Save-TempSession
        Write-Host ("[Autosave] " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -ForegroundColor DarkCyan
    } catch {
        Write-Host ("[Autosave-Error] " + $_.Exception.Message) -ForegroundColor Red
    }
})

# --- Run ---
Update-SnippetFilterOptions
Refresh-SnippetSidebar
$form.Add_Shown({
    Load-TempSession
    if ($script:autoSaveTimer) { $script:autoSaveTimer.Start() }
    $editor = Get-ActiveEditor
    if ($editor) { $editor.Focus() }
})
$form.Add_Load({ $split.SplitterDistance = 320 })
Clear-Host
Write-Host "-----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "   Neuro-KISIM-Formatter V1.2" -ForegroundColor White
Write-Host "   Created with ♥ by Nicolò " -ForegroundColor White
Write-Host "-----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host " "
Write-Host "-----------------------------------------------------------------" -ForegroundColor White
Write-Host "   Du kannst dieses Fenster minimieren, aber nicht schliessen" -ForegroundColor Red
Write-Host "-----------------------------------------------------------------" -ForegroundColor White
[void] $form.ShowDialog()
