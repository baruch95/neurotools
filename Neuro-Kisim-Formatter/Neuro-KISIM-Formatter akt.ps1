<#
.SYNOPSIS
    KISIM Formatter v1.3 (inkl. Suchfunktionen & Kategorien-Anzeige)
    - Fix: UI-Freeze beim Speichern (Debounce, atomares Schreiben, kein Konsolen-Output im Save-Pfad)
    - Fix: Clipboard-Zugriff mit Retry (Citrix/RDP)
    - Fix: Bestehende Textbausteine werden anhand stabiler IDs aktualisiert
    - Änderung: Formatieren und Kopieren sind getrennte Aktionen
    - Hotfix: Umlaute und westeuropäische Sonderzeichen bleiben beim Formatieren vollständig erhalten
#>
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

# --- 1. Fix DPI Scaling ---
try {
    $code = '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
    $win32 = Add-Type -MemberDefinition $code -Name "Win32" -Namespace Win32 -PassThru
    $null = $win32::SetProcessDPIAware()
} catch {}

# --- Hilfsfunktion für statische Konsole ---
function Update-Console {
    param([string]$statusMsg, [ConsoleColor]$color = 'DarkCyan')
    Clear-Host
    Write-Host "-----------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "   Neuro-KISIM-Formatter V1.3" -ForegroundColor White
    Write-Host "   Created with ♥ by Nicolò " -ForegroundColor White
    Write-Host "-----------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host " "
    Write-Host "-----------------------------------------------------------------" -ForegroundColor White
    Write-Host "   Du kannst dieses Fenster minimieren, aber nicht schliessen" -ForegroundColor Red
    Write-Host "-----------------------------------------------------------------" -ForegroundColor White
    Write-Host " "
    if (-not [string]::IsNullOrEmpty($statusMsg)) {
        Write-Host $statusMsg -ForegroundColor $color
    }
}

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
$script:txtMainSearch = $null
$script:saveDebounceTimer = $null
$script:copyFeedbackTimer = $null
$script:sessionDirty = $false
$script:statusLabel = $null
$script:startupWarnings = New-Object System.Collections.ArrayList

function New-SnippetId {
    return [guid]::NewGuid().ToString('N')
}

function Set-DefaultRules {
    $script:rules.Clear()
    [void]$script:rules.Add(@{keyword="Sozialanamnese"; style="underline"})
    # Einfache Anfuehrungszeichen: in "..." wuerde PowerShell $EEG als (leere) Variable interpretieren
    [void]$script:rules.Add(@{keyword='$EEG vom *:$'; style="bold"})
}

# --- Statusanzeige im Fenster statt Clear-Host/Write-Host ---
# WICHTIG: Konsolen-Output aus Timern/Save-Pfaden heraus kann die GUI einfrieren,
# wenn der Benutzer in das Konsolenfenster geklickt hat (QuickEdit-Modus pausiert
# den Prozess bei jedem Write-Host). Deshalb laeuft der Status jetzt in der Form.
function Set-StatusText {
    param([string]$msg)
    if ($script:statusLabel) {
        $script:statusLabel.Text = $msg
    }
}

# --- Atomares, robustes Schreiben (Temp-Datei + Rename, mit Retry) ---
# Verhindert kaputte JSON-Dateien bei Absturz mitten im Schreiben und haengt
# nicht endlos, wenn Virenscanner/OneDrive/Netzlaufwerk die Datei kurz sperren.
function Write-FileSafely {
    param(
        [string]$path,
        [string]$content
    )
    if ([string]::IsNullOrWhiteSpace($path)) {
        Set-StatusText "Speichern fehlgeschlagen: Ungültiger Dateipfad."
        return $false
    }

    # Eindeutiger Temp-Name verhindert Kollisionen, falls die App versehentlich
    # zweimal gestartet wird.
    $tempPath = "$path.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            [System.IO.File]::WriteAllText($tempPath, $content, [System.Text.UTF8Encoding]::new($true))
            Move-Item -LiteralPath $tempPath -Destination $path -Force -ErrorAction Stop
            return $true
        } catch {
            if (Test-Path -LiteralPath $tempPath) {
                Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
            }
            if ($attempt -eq 3) {
                Set-StatusText "Speichern fehlgeschlagen: $($_.Exception.Message)"
                return $false
            }
            Start-Sleep -Milliseconds (100 * $attempt)
        }
    }
    return $false
}

# Load Config
if (Test-Path $script:configFile) {
    try {
        $json = Get-Content $script:configFile -Raw | ConvertFrom-Json
        if (-not [string]::IsNullOrWhiteSpace([string]$json.font)) {
            $script:globalFont = [string]$json.font
        }
        foreach($r in @($json.rules)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$r.keyword) -and @('bold','underline','italic','highlight','none') -contains [string]$r.style) {
                [void]$script:rules.Add($r)
            }
        }
        if ($script:rules.Count -eq 0) { Set-DefaultRules }
    } catch {
        Set-DefaultRules
        [void]$script:startupWarnings.Add("Die Regeldatei konnte nicht gelesen werden. Es wurden Standardregeln geladen.")
    }
} else {
    Set-DefaultRules
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

                $macro = ""
                if ($snip.PSObject.Properties.Name -contains 'macro' -and $snip.macro) {
                    $macro = ([string]$snip.macro).Trim()
                }

                $id = if ($snip.PSObject.Properties.Name -contains 'id' -and -not [string]::IsNullOrWhiteSpace([string]$snip.id)) {
                    ([string]$snip.id).Trim()
                } else {
                    New-SnippetId
                }

                [void]$script:snippets.Add([PSCustomObject]@{ id = $id; title = [string]$snip.title; content = [string]$snip.content; categories = $cats; macro = $macro })
            }
        }
    } catch {
        [void]$script:startupWarnings.Add("Die Textbaustein-Datei konnte nicht gelesen werden. Es wurden Standardbausteine geladen; die bestehende Datei wurde noch nicht überschrieben.")
    }
}

if ($script:snippets.Count -eq 0) {
    [void]$script:snippets.Add([PSCustomObject]@{ id = (New-SnippetId); title = "o.B."; content = "o.B."; categories = @("Allgemein"); macro = '$ob' })
    [void]$script:snippets.Add([PSCustomObject]@{ id = (New-SnippetId); title = "Pat. berichtet"; content = "Der Patient berichtet über "; categories = @("Allgemein"); macro = '' })
}

# --- 3. RTF Generation Logic ---
function ConvertTo-RtfSafeText {
    param([AllowEmptyString()][string]$text)

    if ($null -eq $text) { return '' }

    $builder = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $text.Length; $i++) {
        $charCode = [int]$text[$i]
        switch ($charCode) {
            9  { [void]$builder.Append('\tab ') }
            10 { [void]$builder.Append('\par ') }
            13 {
                if ($i + 1 -lt $text.Length -and [int]$text[$i + 1] -eq 10) { $i++ }
                [void]$builder.Append('\par ')
            }
            92  { [void]$builder.Append('\\') }
            123 { [void]$builder.Append('\{') }
            125 { [void]$builder.Append('\}') }
            default {
                if ($charCode -ge 160 -and $charCode -le 255) {
                    # RTF/Windows-1252-Hexdarstellung, z.B. ö -> \'f6.
                    # Die vorherige \uN?-Darstellung wurde von der eingesetzten
                    # RichTextBox bei einzelnen Wörtern fehlerhaft interpretiert.
                    [void]$builder.Append(("\'{0:x2}" -f $charCode))
                }
                elseif ($charCode -ge 32) {
                    # Andere Unicode-Zeichen unverändert belassen. Dieses
                    # Verhalten entspricht der zuvor funktionierenden Version.
                    [void]$builder.Append([char]$charCode)
                }
            }
        }
    }

    return $builder.ToString()
}

function Get-RTF {
    param([AllowEmptyString()][string]$text)

    $rtfHeader = "{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\fnil\fcharset0 $script:globalFont;}}"
    $rtfHeader += "{\colortbl ;\red255\green255\blue0;}"
    $rtfHeader += "\viewkind4\uc1\pard\lang1031\f0\fs22 "

    # Regeln auf dem Klartext anwenden. So bleiben Zeilengrenzen eindeutig und
    # Wildcards koennen nicht versehentlich ueber mehrere Absaetze laufen.
    $tokenizedText = ([string]$text) -replace "`r`n", "`n" -replace "`r", "`n"

    $sortedRules = $script:rules | Sort-Object -Property @{Expression={$_.keyword.Length}} -Descending

    $tokenMap = @{}
    do {
        $tokenPrefix = "##KISIM_RTF_$([guid]::NewGuid().ToString('N'))_"
    } while ($tokenizedText.Contains($tokenPrefix))
    # Zaehler in einer Hashtable, damit der Regex-Callback ihn zuverlaessig
    # veraendern kann (Set-Variable -Scope 1 ist im Callback fragil)
    $tokenState = @{ counter = 0 }
    # Timeout gegen "catastrophic backtracking": eine unguenstige Wildcard-Regel
    # darf die App nicht einfrieren, sondern wird uebersprungen
    $regexTimeout = [TimeSpan]::FromSeconds(2)

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
            $k = $k -replace "\\\?", "[^\r\n]"
            if ($k -match "\\\*$") { $k = $k -replace "\\\*$", "\S*" }
            $k = $k -replace "\\\*", ".*?"

            if ($isWholeLine) {
                $regexPattern = "(?m)^($k)$"
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

            try {
                $tokenizedText = [Regex]::Replace($tokenizedText, $regexPattern, {
                    param($match)

                    $token = "$tokenPrefix$($tokenState.counter)##"
                    $tokenState.counter++

                    $formattedString = "$tagStart$(ConvertTo-RtfSafeText -text $match.Value)$tagEnd"
                    $tokenMap[$token] = $formattedString

                    return $token
                }, ([System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant), $regexTimeout)
            } catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
                # Regel ueberspringen statt einfrieren
                continue
            }
        }
    }

    $safeText = ConvertTo-RtfSafeText -text $tokenizedText

    # Tokens in absteigender Reihenfolge aufloesen: spaeter erzeugte Tokens koennen
    # (durch Wildcard-Regeln) fruehere Tokens enthalten - so werden auch
    # verschachtelte Tokens vollstaendig ersetzt
    for ($i = $tokenState.counter - 1; $i -ge 0; $i--) {
        $key = "$tokenPrefix$i##"
        if ($tokenMap.ContainsKey($key)) {
            $safeText = $safeText.Replace($key, $tokenMap[$key])
        }
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

    $knownIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    for ($i = 0; $i -lt $script:snippets.Count; $i++) {
        $item = $script:snippets[$i]
        if (-not $item) { continue }

        $id = if ($item.PSObject.Properties.Name -contains 'id' -and -not [string]::IsNullOrWhiteSpace([string]$item.id)) {
            ([string]$item.id).Trim()
        } else {
            New-SnippetId
        }
        while (-not $knownIds.Add($id)) { $id = New-SnippetId }

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

        $macro = ""
        if ($item.PSObject.Properties.Name -contains 'macro' -and $item.macro) {
            $macro = ([string]$item.macro).Trim()
        }

        $script:snippets[$i] = [PSCustomObject]@{
            id = $id
            title = [string]$item.title
            content = [string]$item.content
            categories = $cats
            macro = $macro
        }
    }
}

function Get-SnippetIndexById {
    param([string]$id)

    if ([string]::IsNullOrWhiteSpace($id)) { return -1 }
    for ($i = 0; $i -lt $script:snippets.Count; $i++) {
        if ([string]::Equals([string]$script:snippets[$i].id, $id, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $i
        }
    }
    return -1
}

function Save-Snippets {
    try {
        Ensure-SnippetState
        $json = $script:snippets | ConvertTo-Json -Depth 5
        return [bool](Write-FileSafely -path $script:snippetFile -content $json)
    } catch {
        Set-StatusText ("Textbausteine konnten nicht gespeichert werden: " + $_.Exception.Message)
        return $false
    }
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
    $searchTerm = if ($script:txtMainSearch) { $script:txtMainSearch.Text.Trim() } else { "" }

    # Bausteine alphabetisch sortieren für bessere Übersicht
    $sortedSnippets = $script:snippets | Sort-Object title

    foreach ($sn in $sortedSnippets) {
        $matchesCat = $true
        # 1. Prüfe Kategorie-Filter
        if ($selectedFilter -ne 'All') {
            $matchesCat = $false
            if ($sn.categories) {
                foreach ($c in $sn.categories) {
                    if ([string]$c -eq $selectedFilter) { $matchesCat = $true; break }
                }
            }
        }

        $matchesSearch = $true
        # 2. Prüfe Texteingabe in der Suche (durchsucht Titel, Kategorien und Inhalt)
        if (-not [string]::IsNullOrEmpty($searchTerm)) {
            $catString = if ($sn.categories) { $sn.categories -join ' ' } else { '' }
            if ($sn.title -notmatch [regex]::Escape($searchTerm) -and 
                $catString -notmatch [regex]::Escape($searchTerm) -and 
                $sn.content -notmatch [regex]::Escape($searchTerm)) {
                $matchesSearch = $false
            }
        }

        # Nur anzeigen, wenn beide Kriterien erfüllt sind
        if ($matchesCat -and $matchesSearch) {
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
    $dlg.Size = New-Object System.Drawing.Size(850, 600)
    $dlg.StartPosition = "CenterScreen"

    $splitDlg = New-Object System.Windows.Forms.SplitContainer
    $splitDlg.Dock = "Fill"
    $splitDlg.FixedPanel = "Panel1"
    $splitDlg.SplitterDistance = 300 # Breiter für die Kategorien-Anzeige
    $dlg.Controls.Add($splitDlg)

    # --- Suchfeld im Editor ---
    $pnlSearch = New-Object System.Windows.Forms.Panel
    $pnlSearch.Dock = "Top"
    $pnlSearch.Height = 45
    $pnlSearch.Padding = New-Object System.Windows.Forms.Padding(5)
    
    $lblSearch = New-Object System.Windows.Forms.Label
    $lblSearch.Text = "Suchen (Titel, Kat., Inhalt):"
    $lblSearch.Dock = "Top"
    $lblSearch.Height = 15
    $pnlSearch.Controls.Add($lblSearch)

    $script:txtSearchDlg = New-Object System.Windows.Forms.TextBox
    $script:txtSearchDlg.Dock = "Bottom"
    $pnlSearch.Controls.Add($script:txtSearchDlg)

    $splitDlg.Panel1.Controls.Add($pnlSearch)

    $script:snipList = New-Object System.Windows.Forms.ListBox
    $script:snipList.Dock = "Fill"
    $splitDlg.Panel1.Controls.Add($script:snipList)
    $script:snipList.BringToFront()
    # -------------------------------

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = "Fill"
    $layout.RowCount = 3
    $layout.ColumnCount = 1
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 180)))
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

    $script:txtSnippetTitle = New-Object System.Windows.Forms.TextBox
    $script:txtSnippetTitle.Location = New-Object System.Drawing.Point(0, 22)
    $script:txtSnippetTitle.Width = 490
    $script:txtSnippetTitle.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $pnlFields.Controls.Add($script:txtSnippetTitle)

    $lblCategoriesDlg = New-Object System.Windows.Forms.Label
    $lblCategoriesDlg.Text = "Kategorien / Tags (Komma-getrennt)"
    $lblCategoriesDlg.AutoSize = $true
    $lblCategoriesDlg.Location = New-Object System.Drawing.Point(0, 52)
    $pnlFields.Controls.Add($lblCategoriesDlg)

    $script:txtSnippetCategories = New-Object System.Windows.Forms.TextBox
    $script:txtSnippetCategories.Location = New-Object System.Drawing.Point(0, 70)
    $script:txtSnippetCategories.Width = 490
    $script:txtSnippetCategories.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $pnlFields.Controls.Add($script:txtSnippetCategories)

    $lblMacroDlg = New-Object System.Windows.Forms.Label
    $lblMacroDlg.Text = "Makro (optional, z.B. `$ob)"
    $lblMacroDlg.AutoSize = $true
    $lblMacroDlg.Location = New-Object System.Drawing.Point(0, 100)
    $pnlFields.Controls.Add($lblMacroDlg)

    $script:txtSnippetMacro = New-Object System.Windows.Forms.TextBox
    $script:txtSnippetMacro.Location = New-Object System.Drawing.Point(0, 118)
    $script:txtSnippetMacro.Width = 490
    $script:txtSnippetMacro.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $pnlFields.Controls.Add($script:txtSnippetMacro)

    $lblContentDlg = New-Object System.Windows.Forms.Label
    $lblContentDlg.Text = "Inhalt"
    $lblContentDlg.AutoSize = $true
    $lblContentDlg.Location = New-Object System.Drawing.Point(0, 148)
    $pnlFields.Controls.Add($lblContentDlg)

    $script:txtSnippetContent = New-Object System.Windows.Forms.TextBox
    $script:txtSnippetContent.Multiline = $true
    $script:txtSnippetContent.ScrollBars = "Vertical"
    $script:txtSnippetContent.Dock = "Fill"
    $layout.Controls.Add($script:txtSnippetContent, 0, 1)

    $pnlActionsDlg = New-Object System.Windows.Forms.FlowLayoutPanel
    $pnlActionsDlg.Dock = "Fill"
    $pnlActionsDlg.FlowDirection = "LeftToRight"
    $layout.Controls.Add($pnlActionsDlg, 0, 2)

    $btnNewSnip = New-Object System.Windows.Forms.Button; $btnNewSnip.Text = "Neu"
    $btnSaveSnip = New-Object System.Windows.Forms.Button; $btnSaveSnip.Text = "Speichern"
    $btnDeleteSnip = New-Object System.Windows.Forms.Button; $btnDeleteSnip.Text = "Löschen"
    $btnCloseDlg = New-Object System.Windows.Forms.Button; $btnCloseDlg.Text = "Schließen"
    $pnlActionsDlg.Controls.AddRange(@($btnNewSnip, $btnSaveSnip, $btnDeleteSnip, $btnCloseDlg))

    # Array für gefilterte Liste
    $script:dlgFilteredSnippets = @()

    $script:refreshSnipList = {
        Ensure-SnippetState
        $script:snipList.Items.Clear()
        $script:dlgFilteredSnippets = @()
        
        $searchTerm = $script:txtSearchDlg.Text.Trim()
        
        # Sortiere Bausteine alphabetisch nach Titel
        $sortedSnippets = $script:snippets | Sort-Object title

        foreach ($sn in $sortedSnippets) {
            $match = $true
            if (-not [string]::IsNullOrEmpty($searchTerm)) {
                $catString = if ($sn.categories) { $sn.categories -join ' ' } else { '' }
                if ($sn.title -notmatch [regex]::Escape($searchTerm) -and 
                    $catString -notmatch [regex]::Escape($searchTerm) -and 
                    $sn.content -notmatch [regex]::Escape($searchTerm)) {
                    $match = $false
                }
            }

            if ($match) {
                $script:dlgFilteredSnippets += $sn
                $displayCat = if ($sn.categories) { $sn.categories -join ', ' } else { "Allgemein" }
                [void]$script:snipList.Items.Add("$($sn.title) [$displayCat]")
            }
        }
    }

    $script:txtSearchDlg.Add_TextChanged({ & $script:refreshSnipList })

    $script:loadSelected = {
        if ($script:snipList.SelectedIndex -lt 0 -or $script:snipList.SelectedIndex -ge $script:dlgFilteredSnippets.Count) { return }

        $sel = $script:dlgFilteredSnippets[$script:snipList.SelectedIndex]
        if (-not $sel) { return }

        $script:txtSnippetTitle.Text = [string]$sel.title
        $script:txtSnippetContent.Text = [string]$sel.content
        $script:txtSnippetCategories.Text = if ($sel.categories) { (@($sel.categories) -join ', ') } else { '' }
        $script:txtSnippetMacro.Text = if ($sel.macro) { [string]$sel.macro } else { '' }
    }

    $script:snipList.Add_SelectedIndexChanged($script:loadSelected)

    $btnNewSnip.Add_Click({
        $script:txtSnippetTitle.Text = ''
        $script:txtSnippetContent.Text = ''
        $script:txtSnippetCategories.Text = ''
        $script:txtSnippetMacro.Text = ''
        $script:snipList.ClearSelected()
        $script:txtSearchDlg.Text = '' 
        $script:txtSnippetTitle.Focus()
    })

    $btnSaveSnip.Add_Click({
        # Die Auswahl vor der Normalisierung sichern. Ensure-SnippetState baut
        # die Objekte neu auf; ein Vergleich ueber Objektreferenzen ist deshalb
        # unzuverlaessig und war die Ursache dafuer, dass Aenderungen an
        # bestehenden Textbausteinen nicht gespeichert wurden.
        $selectedId = $null
        if ($script:snipList.SelectedIndex -ge 0 -and $script:snipList.SelectedIndex -lt $script:dlgFilteredSnippets.Count) {
            $selectedId = [string]$script:dlgFilteredSnippets[$script:snipList.SelectedIndex].id
        }

        Ensure-SnippetState

        $title = [string]$script:txtSnippetTitle.Text.Trim()
        $content = [string]$script:txtSnippetContent.Text
        $macro = [string]$script:txtSnippetMacro.Text.Trim()

        if ([string]::IsNullOrWhiteSpace($title) -or [string]::IsNullOrWhiteSpace($content)) {
            [System.Windows.Forms.MessageBox]::Show("Titel und Inhalt sind erforderlich.", "Hinweis")
            return
        }

        $cats = @()
        foreach ($part in ([string]$script:txtSnippetCategories.Text -split ',')) {
            $tag = $part.Trim()
            if (-not [string]::IsNullOrWhiteSpace($tag) -and ($cats -notcontains $tag)) { $cats += $tag }
        }
        if ($cats.Count -eq 0) { $cats = @('Allgemein') }

        $isNew = [string]::IsNullOrWhiteSpace($selectedId)
        $snippetId = if ($isNew) { New-SnippetId } else { $selectedId }
        $obj = [PSCustomObject]@{ id = $snippetId; title = $title; content = $content; categories = $cats; macro = $macro }

        $realIndex = -1
        $original = $null
        if (-not $isNew) {
            $realIndex = Get-SnippetIndexById -id $selectedId
            if ($realIndex -lt 0) {
                [System.Windows.Forms.MessageBox]::Show("Der ausgewählte Textbaustein wurde zwischenzeitlich verändert. Bitte erneut auswählen.", "Speichern", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                & $script:refreshSnipList
                return
            }
            $original = $script:snippets[$realIndex]
            $script:snippets[$realIndex] = $obj
        } else {
            [void]$script:snippets.Add($obj)
            $realIndex = $script:snippets.Count - 1
        }

        if (-not (Save-Snippets)) {
            if ($isNew) {
                $script:snippets.RemoveAt($realIndex)
            } else {
                $script:snippets[$realIndex] = $original
            }
            [System.Windows.Forms.MessageBox]::Show("Der Textbaustein konnte nicht auf dem Datenträger gespeichert werden.", "Speichern fehlgeschlagen", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            return
        }

        & $script:refreshSnipList

        Update-SnippetFilterOptions
        Refresh-SnippetSidebar
        Set-StatusText "Textbaustein gespeichert."
        [System.Windows.Forms.MessageBox]::Show("Textbaustein gespeichert.", "Gespeichert")
    })

    $btnDeleteSnip.Add_Click({
        if ($script:snipList.SelectedIndex -lt 0 -or $script:snipList.SelectedIndex -ge $script:dlgFilteredSnippets.Count) { return }

        $confirm = [System.Windows.Forms.MessageBox]::Show("Textbaustein löschen?", "Löschen", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $selectedId = [string]$script:dlgFilteredSnippets[$script:snipList.SelectedIndex].id
        Ensure-SnippetState
        $realIndex = Get-SnippetIndexById -id $selectedId
        if ($realIndex -lt 0) {
            [System.Windows.Forms.MessageBox]::Show("Der ausgewählte Textbaustein wurde nicht gefunden.", "Löschen", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            & $script:refreshSnipList
            return
        }

        $removed = $script:snippets[$realIndex]
        $script:snippets.RemoveAt($realIndex)
        if (-not (Save-Snippets)) {
            $script:snippets.Insert($realIndex, $removed)
            [System.Windows.Forms.MessageBox]::Show("Der Textbaustein konnte nicht auf dem Datenträger gelöscht werden.", "Löschen fehlgeschlagen", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            return
        }

        & $script:refreshSnipList
        Update-SnippetFilterOptions
        Refresh-SnippetSidebar
        Set-StatusText "Textbaustein gelöscht."

        $script:txtSnippetTitle.Text = ''
        $script:txtSnippetContent.Text = ''
        $script:txtSnippetCategories.Text = ''
        $script:txtSnippetMacro.Text = ''
    })

    $btnCloseDlg.Add_Click({ $script:textbausteinForm.Close() })

    $script:snipList.Add_DoubleClick({
        if ($script:snipList.SelectedIndex -lt 0 -or $script:snipList.SelectedIndex -ge $script:dlgFilteredSnippets.Count) { return }
        $sel = $script:dlgFilteredSnippets[$script:snipList.SelectedIndex]
        Insert-TextIntoActiveEditor -text ([string]$sel.content)
        Request-TempSessionSave
    })

    $dlg.Add_FormClosed({ $script:textbausteinForm = $null })

    & $script:refreshSnipList
    if ($script:snipList.Items.Count -gt 0) { $script:snipList.SelectedIndex = 0 }

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

    $script:rulesLst = New-Object System.Windows.Forms.ListBox
    $script:rulesLst.Dock = 'Fill'
    $pnl.Controls.Add($script:rulesLst)

    $grp = New-Object System.Windows.Forms.GroupBox
    $grp.Text = 'Regel hinzufügen / bearbeiten'
    $grp.Dock = 'Top'
    $grp.Height = 140
    $pnl.Controls.Add($grp)

    $script:rulesTxtK = New-Object System.Windows.Forms.TextBox
    $script:rulesTxtK.Location = New-Object System.Drawing.Point(10, 26)
    $script:rulesTxtK.Width = 470
    $grp.Controls.Add($script:rulesTxtK)

    $script:rulesCbS = New-Object System.Windows.Forms.ComboBox
    $script:rulesCbS.Location = New-Object System.Drawing.Point(10, 56)
    $script:rulesCbS.Width = 470
    $script:rulesCbS.Items.AddRange(@('bold','underline','italic','highlight','none'))
    $script:rulesCbS.SelectedIndex = 0
    $grp.Controls.Add($script:rulesCbS)

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

    $script:rulesCbFontR = New-Object System.Windows.Forms.ComboBox
    $script:rulesCbFontR.Dock = 'Bottom'
    $script:rulesCbFontR.Items.AddRange(@('Arial','Times New Roman','Verdana','Courier New','Tahoma'))
    $script:rulesCbFontR.Text = $script:globalFont
    $pnl.Controls.Add($script:rulesCbFontR)

    $btnSaveR = New-Object System.Windows.Forms.Button
    $btnSaveR.Text = 'Regeln + Font speichern'
    $btnSaveR.Dock = 'Bottom'
    $btnSaveR.Height = 36
    $pnl.Controls.Add($btnSaveR)

    $script:refreshRulesList = {
        $script:rulesLst.Items.Clear()
        foreach ($r in $script:rules) { [void]$script:rulesLst.Items.Add("$($r.style.ToUpper()) - '$($r.keyword)'") }
    }

    $btnAddR.Add_Click({
        if (-not [string]::IsNullOrWhiteSpace($script:rulesTxtK.Text)) {
            [void]$script:rules.Add(@{ keyword = $script:rulesTxtK.Text; style = $script:rulesCbS.Text })
            & $script:refreshRulesList
            $script:rulesTxtK.Text = ''
            $script:rulesTxtK.Focus()
        }
    })

    $btnDelR.Add_Click({
        if ($script:rulesLst.SelectedIndex -ge 0) {
            $script:rules.RemoveAt($script:rulesLst.SelectedIndex)
            & $script:refreshRulesList
        }
    })

    $btnSaveR.Add_Click({
        $script:globalFont = $script:rulesCbFontR.Text
        $export = @{ font = $script:globalFont; rules = $script:rules }
        $json = $export | ConvertTo-Json -Depth 3
        if (Write-FileSafely -path $script:configFile -content $json) {
            Set-StatusText 'Regeln und Schriftart gespeichert.'
            [System.Windows.Forms.MessageBox]::Show('Regeln und Schriftart gespeichert.', 'Gespeichert')
        } else {
            [System.Windows.Forms.MessageBox]::Show('Regeln und Schriftart konnten nicht gespeichert werden.', 'Speichern fehlgeschlagen', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    })

    $dlg.Add_FormClosed({ $script:rulesForm = $null })
    
    & $script:refreshRulesList
    $dlg.Show()
}

function Save-TempSession {
    if (-not $tabPatients) { return }

    $patients = @()
    foreach ($tab in $tabPatients.TabPages) {
        if ($tab.Controls.Count -eq 0) { continue }
        $editor = $tab.Controls[0]
        $patients += [PSCustomObject]@{
            name = $tab.Text
            text = $editor.Text
            rtf = $editor.Rtf
        }
    }

    $session = [PSCustomObject]@{
        activePatient = if ($tabPatients.SelectedTab) { $tabPatients.SelectedTab.Text } else { $null }
        patients = $patients
    }

    $json = $session | ConvertTo-Json -Depth 4
    if (Write-FileSafely -path $script:sessionFile -content $json) {
        $script:sessionDirty = $false
        Set-StatusText ("Gespeichert um " + (Get-Date -Format 'HH:mm:ss'))
    }
}

# Debounce: Statt bei JEDEM Tastendruck komplett zu serialisieren und auf die
# Festplatte zu schreiben (Hauptursache fuer Freezes, v.a. auf Netzlaufwerken),
# wird nur ein "dirty"-Flag gesetzt und 2 Sekunden nach der letzten Aenderung
# einmal gespeichert.
function Request-TempSessionSave {
    $script:sessionDirty = $true
    if ($script:saveDebounceTimer) {
        $script:saveDebounceTimer.Stop()
        $script:saveDebounceTimer.Start()
    }
}

function Backup-PatientSession {
    try {
        if (-not $tabPatients) { return $false }

        $patients = @()
        foreach ($tab in $tabPatients.TabPages) {
            if ($tab.Controls.Count -eq 0) { continue }
            $editor = $tab.Controls[0]
            $patients += [PSCustomObject]@{
                name = $tab.Text
                text = $editor.Text
                rtf = $editor.Rtf
            }
        }

        $session = [PSCustomObject]@{
            backupTime = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            activePatient = if ($tabPatients.SelectedTab) { $tabPatients.SelectedTab.Text } else { $null }
            patients = $patients
        }

        $backupDir = Join-Path $PSScriptRoot "backups"
        if (-not (Test-Path $backupDir)) {
            $null = New-Item -ItemType Directory -Path $backupDir -Force -ErrorAction Stop
        }

        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
        $backupFile = Join-Path $backupDir "formatterv2_backup_$timestamp.json"

        $json = $session | ConvertTo-Json -Depth 4
        if (-not (Write-FileSafely -path $backupFile -content $json)) { return $false }
        Set-StatusText "Backup erstellt: $backupFile"

        # Alte Backups aufraeumen: nur die letzten 50 behalten
        $oldBackups = Get-ChildItem -Path $backupDir -Filter 'formatterv2_backup_*.json' |
            Sort-Object Name -Descending | Select-Object -Skip 50
        foreach ($old in $oldBackups) {
            Remove-Item -Path $old.FullName -Force -ErrorAction SilentlyContinue
        }
        return $true
    } catch {
        Set-StatusText ("Fehler beim Backup: " + $_.Exception.Message)
        return $false
    }
}

function Add-PatientTab {
    param(
        [string]$name,
        [string]$text = "",
        [string]$rtf = "",
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

    if (-not [string]::IsNullOrWhiteSpace($rtf)) {
        try {
            $editor.Rtf = $rtf
        } catch {
            # Rueckwaertskompatibler Fallback bei beschaedigtem/alten Session-RTF.
            $editor.Text = $text
        }
    }

    $editor.Add_TextChanged({
        if (-not $script:isLoadingSession) {
            Request-TempSessionSave
        }
    })

    $editor.Add_KeyDown({
        param($sender, $e)

        $tb = [System.Windows.Forms.RichTextBox]$sender

        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter -and $tb.SelectionLength -eq 0) {
            $pos = $tb.SelectionStart
            $text = $tb.Text
            if ($pos -gt 0) {
                $wordStart = $pos - 1
                while ($wordStart -ge 0 -and -not [char]::IsWhiteSpace($text[$wordStart])) {
                    $wordStart--
                }
                $wordStart++ 
                $wordLen = $pos - $wordStart

                if ($wordLen -gt 0) {
                    $lastWord = $text.Substring($wordStart, $wordLen)
                    
                    if ($lastWord.Contains("$")) {
                        Ensure-SnippetState
                        $match = $script:snippets | Where-Object { 
                            -not [string]::IsNullOrEmpty($_.macro) -and 
                            $_.macro.Equals($lastWord, [System.StringComparison]::InvariantCultureIgnoreCase) 
                        } | Select-Object -First 1

                        if ($match) {
                            $tb.Select($wordStart, $wordLen)
                            $tb.SelectedText = $match.content
                            $e.SuppressKeyPress = $true
                            $e.Handled = $true
                            return
                        }
                    }
                }
            }
        }

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
                        $savedRtf = if ($p.PSObject.Properties.Name -contains 'rtf') { [string]$p.rtf } else { '' }
                        Add-PatientTab -name $p.name -text $p.text -rtf $savedRtf -switchToTab:$false | Out-Null
                    }
                    if ($session.activePatient) {
                        $active = $tabPatients.TabPages | Where-Object { $_.Text -eq $session.activePatient } | Select-Object -First 1
                        if ($active) { $tabPatients.SelectedTab = $active }
                    }
                }
            } catch {
                Set-StatusText ("Session konnte nicht geladen werden: " + $_.Exception.Message)
                $recoveryMessage = "Die Session-Datei bleibt bis zur nächsten Speicherung unverändert."
                try {
                    $recoveryFile = Join-Path $PSScriptRoot ("formatterv2_temp_session_corrupt_" + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + ".json")
                    Copy-Item -LiteralPath $script:sessionFile -Destination $recoveryFile -ErrorAction Stop
                    $recoveryMessage = "Eine Sicherung wurde erstellt: $recoveryFile"
                } catch {}
                [System.Windows.Forms.MessageBox]::Show("Die letzte Sitzung konnte nicht geladen werden.`r`n$recoveryMessage", "Session laden", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
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
$form.Text = "Neuro-KISIM-Formatter V1.3"
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

# Statusleiste (ersetzt den Konsolen-Output fuer Save-/Backup-Meldungen)
$statusStrip = New-Object System.Windows.Forms.StatusStrip
$script:statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$script:statusLabel.Text = "Bereit"
[void]$statusStrip.Items.Add($script:statusLabel)
$form.Controls.Add($statusStrip)

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
$lblFilter.Text = "Kategorie-Filter:"
$lblFilter.Dock = "Top"
$lblFilter.Height = 18
$pnlLeft.Controls.Add($lblFilter)

$cbSnippetFilter = New-Object System.Windows.Forms.ComboBox
$cbSnippetFilter.Dock = "Top"
$cbSnippetFilter.DropDownStyle = "DropDownList"
$pnlLeft.Controls.Add($cbSnippetFilter)

$lblMainSearch = New-Object System.Windows.Forms.Label
$lblMainSearch.Text = "Suchen (Titel, Inhalt):"
$lblMainSearch.Dock = "Top"
$lblMainSearch.Height = 18
$pnlLeft.Controls.Add($lblMainSearch)

$script:txtMainSearch = New-Object System.Windows.Forms.TextBox
$script:txtMainSearch.Dock = "Top"
$pnlLeft.Controls.Add($script:txtMainSearch)

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

# --- ToolTip für die Vorschau ---
$script:snippetToolTip = New-Object System.Windows.Forms.ToolTip
$script:snippetToolTip.UseFading = $true
$script:snippetToolTip.UseAnimation = $true

# === RIGHT PANEL ===
$pnlRight = $split.Panel2
$pnlRight.Padding = New-Object System.Windows.Forms.Padding(10)

$lblInput = New-Object System.Windows.Forms.Label
$lblInput.Text = "Input Text (Patient Tabs):"
$lblInput.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$lblInput.Dock = "Top"
$lblInput.Height = 25
$pnlRight.Controls.Add($lblInput)

$pnlFormatCopy = New-Object System.Windows.Forms.TableLayoutPanel
$pnlFormatCopy.Dock = "Bottom"
$pnlFormatCopy.Height = 55
$pnlFormatCopy.RowCount = 1
$pnlFormatCopy.ColumnCount = 2
[void]$pnlFormatCopy.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$pnlFormatCopy.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))

$btnFormat = New-Object System.Windows.Forms.Button
$btnFormat.Text = "FORMAT"
$btnFormat.Dock = "Fill"
$btnFormat.Margin = New-Object System.Windows.Forms.Padding(0, 0, 5, 0)
$btnFormat.BackColor = [System.Drawing.Color]::DodgerBlue
$btnFormat.ForeColor = [System.Drawing.Color]::White
$btnFormat.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$btnFormat.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnFormat.FlatStyle = "Flat"
$pnlFormatCopy.Controls.Add($btnFormat, 0, 0)

$btnCopy = New-Object System.Windows.Forms.Button
$btnCopy.Text = "COPY TO CLIPBOARD"
$btnCopy.Dock = "Fill"
$btnCopy.Margin = New-Object System.Windows.Forms.Padding(5, 0, 0, 0)
$btnCopy.BackColor = [System.Drawing.Color]::SeaGreen
$btnCopy.ForeColor = [System.Drawing.Color]::White
$btnCopy.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$btnCopy.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnCopy.FlatStyle = "Flat"
$pnlFormatCopy.Controls.Add($btnCopy, 1, 0)

$pnlRight.Controls.Add($pnlFormatCopy)

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

$btnBackupTab = New-Object System.Windows.Forms.Button
$btnBackupTab.Text = "Backup"
$btnBackupTab.Width = 90
$btnBackupTab.Height = 28
$btnBackupTab.Location = New-Object System.Drawing.Point(290, 6)
$pnlTabActions.Controls.Add($btnBackupTab)

$tabPatients = New-Object System.Windows.Forms.TabControl
$tabPatients.Dock = "Fill"
$tabPatients.Multiline = $true
$pnlRight.Controls.Add($tabPatients)
$tabPatients.BringToFront()

# --- 5. LOGIC & EVENTS ---

$btnSnippetEditor.Add_Click({ Show-TextbausteineDialog })
$btnRulesEditor.Add_Click({ Show-RulesEditor })

$cbSnippetFilter.Add_SelectedIndexChanged({ Refresh-SnippetSidebar })
$script:txtMainSearch.Add_TextChanged({ Refresh-SnippetSidebar })

$lstSnippetSidebar.Add_DoubleClick({
    $idx = $lstSnippetSidebar.SelectedIndex
    if ($idx -lt 0 -or $idx -ge $script:sidebarFilteredSnippets.Count) { return }
    $snippet = $script:sidebarFilteredSnippets[$idx]
    Insert-TextIntoActiveEditor -text ([string]$snippet.content)
    Request-TempSessionSave
})

# Rechtsklick für Vorschau (ToolTip)
$lstSnippetSidebar.Add_MouseDown({
    param($sender, $e)
    
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        
        $index = $lstSnippetSidebar.IndexFromPoint($e.Location)
        
        if ($index -ne [System.Windows.Forms.ListBox]::NoMatches) {
            $lstSnippetSidebar.SelectedIndex = $index
            $snippet = $script:sidebarFilteredSnippets[$index]
            $previewText = $snippet.content
            
            # Text auf max. 400 Zeichen kürzen
            if ($previewText.Length -gt 400) {
                $previewText = $previewText.Substring(0, 400) + "..."
            }
            
            # --- NEU: Automatischer Zeilenumbruch ---
            # Fügt ca. alle 60 Zeichen an einem Leerzeichen einen Umbruch ein
            $previewText = [regex]::Replace($previewText, "(.{1,60})(?:\s|$)", "`$1`n")
            
            # Popup anzeigen
            $script:snippetToolTip.Show($previewText, $lstSnippetSidebar, $e.Location.X + 15, $e.Location.Y + 15, 5000)
        }
    }
})

# Popup verstecken, wenn man die Liste mit der Maus verlässt
$lstSnippetSidebar.Add_MouseLeave({
    $script:snippetToolTip.Hide($lstSnippetSidebar)
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
$btnBackupTab.Add_Click({ 
    if (Backup-PatientSession) {
        [System.Windows.Forms.MessageBox]::Show("Backup wurde erfolgreich im Ordner 'backups' abgelegt.", "Backup erstellt")
    } else {
        [System.Windows.Forms.MessageBox]::Show("Das Backup konnte nicht erstellt werden.", "Backup fehlgeschlagen", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
})

$tabPatients.Add_SelectedIndexChanged({ Request-TempSessionSave })

$btnFormat.Add_Click({
    $editor = Get-ActiveEditor
    if (-not $editor) { return }

    $raw = $editor.Text
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    $selectionStart = $editor.SelectionStart
    $selectionLength = $editor.SelectionLength

    try {
        $editor.Rtf = Get-RTF -text $raw

        # Formatieren darf den Inhalt niemals verändern. Nach dem RTF-Roundtrip
        # wird deshalb der komplette Klartext verglichen. Bei einer Abweichung
        # wird sofort der unveränderte Ausgangstext wiederhergestellt und nichts
        # gespeichert.
        $beforeCheck = $raw -replace "`r`n", "`n" -replace "`r", "`n"
        $afterCheck = $editor.Text -replace "`r`n", "`n" -replace "`r", "`n"
        if ($afterCheck -cne $beforeCheck) {
            $editor.Text = $raw
            $editor.Select([Math]::Min($selectionStart, $editor.TextLength), [Math]::Min($selectionLength, [Math]::Max(0, $editor.TextLength - $selectionStart)))
            throw "Die RTF-Integritätsprüfung hat eine Textveränderung erkannt. Der Originaltext wurde wiederhergestellt."
        }

        $editor.Select([Math]::Min($selectionStart, $editor.TextLength), [Math]::Min($selectionLength, [Math]::Max(0, $editor.TextLength - $selectionStart)))
        Set-StatusText "Text formatiert."
        Save-TempSession
    } catch {
        [System.Windows.Forms.MessageBox]::Show(("Der Text konnte nicht formatiert werden: " + $_.Exception.Message), "Formatierung fehlgeschlagen", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
})

$btnCopy.Add_Click({
    $editor = Get-ActiveEditor
    if (-not $editor) { return }

    $raw = $editor.Text
    if ([string]::IsNullOrWhiteSpace($raw)) { return }

    try {
        # SetDataObject mit Retry (10 Versuche, 150ms): unter Citrix/RDP ist das
        # Clipboard oft kurz von einem anderen Prozess gesperrt - SetText ohne
        # Retry haengt dann oder wirft eine Exception.
        # Kopiert den aktuellen Zustand des Editors unveraendert. RTF wird fuer
        # formatierungsfaehige Ziele und Klartext als Fallback bereitgestellt.
        $dataObj = New-Object System.Windows.Forms.DataObject
        $dataObj.SetData([System.Windows.Forms.DataFormats]::Rtf, $editor.Rtf)
        $dataObj.SetData([System.Windows.Forms.DataFormats]::UnicodeText, $raw)
        [System.Windows.Forms.Clipboard]::SetDataObject($dataObj, $true, 10, 150)

        # Button-Feedback ueber Timer statt Start-Sleep (Start-Sleep blockiert
        # den UI-Thread und laesst die App eingefroren wirken)
        $btnCopy.Text = "COPIED SUCCESSFULLY!"
        $btnCopy.BackColor = [System.Drawing.Color]::ForestGreen
        $script:copyFeedbackTimer.Stop()
        $script:copyFeedbackTimer.Start()
        Set-StatusText "Text in die Zwischenablage kopiert."
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Zwischenablage ist blockiert (evtl. durch ein anderes Programm). Bitte erneut versuchen.", "Clipboard")
    }
})

$script:copyFeedbackTimer = New-Object System.Windows.Forms.Timer
$script:copyFeedbackTimer.Interval = 750
$script:copyFeedbackTimer.Add_Tick({
    $script:copyFeedbackTimer.Stop()
    $btnCopy.Text = "COPY TO CLIPBOARD"
    $btnCopy.BackColor = [System.Drawing.Color]::SeaGreen
})

$form.Add_FormClosing({
    param($sender, $e)
    if ($script:autoSaveTimer) { $script:autoSaveTimer.Stop() }
    if ($script:saveDebounceTimer) { $script:saveDebounceTimer.Stop() }
    if ($script:copyFeedbackTimer) { $script:copyFeedbackTimer.Stop() }

    # Fehler beim Speichern duerfen das Schliessen nicht blockieren
    try { Save-TempSession } catch {}
    try { [void](Backup-PatientSession) } catch {}
})

# Debounce-Timer: speichert einmalig 2s nach der letzten Textaenderung
$script:saveDebounceTimer = New-Object System.Windows.Forms.Timer
$script:saveDebounceTimer.Interval = 2000
$script:saveDebounceTimer.Add_Tick({
    $script:saveDebounceTimer.Stop()
    if ($script:sessionDirty) {
        try {
            Save-TempSession
        } catch {
            Set-StatusText ("[Autosave-Fehler] " + $_.Exception.Message)
        }
    }
})

# Sicherheitsnetz: speichert alle 30s, falls noch ungespeicherte Aenderungen da sind.
# WICHTIG: KEIN Write-Host/Clear-Host mehr im Timer! Wenn der Benutzer in das
# Konsolenfenster klickt, pausiert der QuickEdit-Modus jeden Konsolen-Output
# und die komplette GUI friert beim naechsten Autosave ein.
$script:autoSaveTimer = New-Object System.Windows.Forms.Timer
$script:autoSaveTimer.Interval = 30000
$script:autoSaveTimer.Add_Tick({
    try {
        if ($script:sessionDirty) {
            Save-TempSession
        }
    } catch {
        Set-StatusText ("[Autosave-Fehler] " + $_.Exception.Message)
    }
})

# --- Run ---
Update-SnippetFilterOptions
Refresh-SnippetSidebar
$form.Add_Shown({
    Load-TempSession
    if ($script:autoSaveTimer) { $script:autoSaveTimer.Start() }
    if ($script:startupWarnings.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show(($script:startupWarnings -join "`r`n"), "Hinweis beim Start", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
    }
    $editor = Get-ActiveEditor
    if ($editor) { $editor.Focus() }
})
$form.Add_Load({ $split.SplitterDistance = 320 })

Update-Console -statusMsg "Applikation gestartet und bereit..." -color 'Gray'

[void] $form.ShowDialog()
