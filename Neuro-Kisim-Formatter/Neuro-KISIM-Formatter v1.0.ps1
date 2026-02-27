<#
.SYNOPSIS
    KISIM Formatter v1.0
#>
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Collections

# --- 1. Fix DPI Scaling ---
try {
    $code = '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
    $win32 = Add-Type -MemberDefinition $code -Name "Win32" -Namespace Win32 -PassThru
    $null = $win32::SetProcessDPIAware()
} catch {}

# --- 2. Configuration & State ---
$script:configFile = Join-Path $PSScriptRoot "formatterv2_rules.json"
$script:rules = New-Object System.Collections.ArrayList
$script:globalFont = "Arial"

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
    [void]$script:rules.Add(@{keyword="$EEG vom *:$"; style="bold"}) # New Syntax Example
}

# --- 3. RTF Generation Logic ---
function Get-RTF {
    param($text)
    
    $rtfHeader = "{\rtf1\ansi\deff0{\fonttbl{\f0\fnil\fcharset0 $script:globalFont;}}"
    $rtfHeader += "{\colortbl ;\red255\green255\blue0;}"
    $rtfHeader += "\viewkind4\uc1\pard\lang1031\f0\fs22 " 

    $safeText = $text -replace "\\", "\\" -replace "\{", "\{" -replace "\}", "\}"
    $safeText = $safeText -replace "`r`n", "\par " -replace "`n", "\par "

    # Sort: Longest First
    $sortedRules = $script:rules | Sort-Object -Property @{Expression={$_.keyword.Length}} -Descending

    $tokenMap = @{}
    $tokenCounter = 0

    foreach ($rule in $sortedRules) {
        if (-not [string]::IsNullOrWhiteSpace($rule.keyword)) {
            
            $cleanKey = $rule.keyword
            $isWholeLine = $false

            # --- CHECK FOR WHOLE LINE SYNTAX ---
            # Option A: ^Word$ (Regex Style)
            if ($cleanKey.StartsWith("^") -and $cleanKey.EndsWith("$") -and $cleanKey.Length -gt 2) {
                $isWholeLine = $true
                $cleanKey = $cleanKey.Substring(1, $cleanKey.Length - 2) 
            }
            # Option B: $Word$ (Easy Style)
            elseif ($cleanKey.StartsWith("$") -and $cleanKey.EndsWith("$") -and $cleanKey.Length -gt 2) {
                $isWholeLine = $true
                $cleanKey = $cleanKey.Substring(1, $cleanKey.Length - 2) 
            }

            # --- WILDCARD PROCESSING ---
            $k = [Regex]::Escape($cleanKey)
            $k = $k -replace "\\\?", "."
            if ($k -match "\\\*$") { $k = $k -replace "\\\*$", "\S*" } # Greedy at end
            $k = $k -replace "\\\*", ".*?" # Lazy in middle

            # --- BUILD REGEX PATTERN ---
            if ($isWholeLine) {
                # Logic: Start of String OR Preceded by Newline -> Word -> End of String OR Followed by Newline
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

            # Replace with Token
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

    # Restore Tokens
    foreach ($key in $tokenMap.Keys) {
        $safeText = $safeText.Replace($key, $tokenMap[$key])
    }

    $finalRTF = $rtfHeader + $safeText + "}"
    return $finalRTF
}

# --- 4. GUI SETUP ---
$form = New-Object System.Windows.Forms.Form
$form.Text = "Neuro-KISIM-Formatter V1.0"
$form.Size = New-Object System.Drawing.Size(950, 650)
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
$lblInput.Text = "Input Text:"
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

$txtInput = New-Object System.Windows.Forms.RichTextBox
$txtInput.Dock = "Fill"
$txtInput.ScrollBars = "Both"
$txtInput.WordWrap = $true
$txtInput.Font = New-Object System.Drawing.Font("Segoe UI", 11) 
$pnlRight.Controls.Add($txtInput)
$txtInput.BringToFront()

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

$btnCopy.Add_Click({
    $raw = $txtInput.Text
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    $script:globalFont = $cbFont.Text
    
    $rtfData = Get-RTF -text $raw
    
    try {
        [System.Windows.Forms.Clipboard]::SetText($rtfData, [System.Windows.Forms.TextDataFormat]::Rtf)
        $txtInput.Rtf = $rtfData 
        
        $originalText = $btnCopy.Text
        $originalColor = $btnCopy.BackColor
        $btnCopy.Text = "COPIED SUCCESSFULLY!"
        $btnCopy.BackColor = [System.Drawing.Color]::SeaGreen
        $form.Refresh()
        Start-Sleep -Milliseconds 750
        $btnCopy.Text = $originalText
        $btnCopy.BackColor = $originalColor
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Error accessing clipboard.", "Error")
    }
})

# --- Run ---
Refresh-List
$form.Add_Shown({ $txtInput.Focus() })
$form.Add_Load({ $split.SplitterDistance = 300 })
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