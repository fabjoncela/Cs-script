Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$src=[IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'cafe.bat'))
if($src -notmatch '(?s)Add-Type -ReferencedAssemblies @\(''System.Windows.Forms'',''System.Drawing''\) -TypeDefinition @''\r?\n(?<code>.*?)\r?\n''@') { throw 'Editor combo subclass C# definition not found' }
$code=$Matches['code']
Add-Type -ReferencedAssemblies @('System.Windows.Forms','System.Drawing') -TypeDefinition $code
if(-not [CafeEditorScrollComboBox].IsSubclassOf([System.Windows.Forms.ComboBox])) { throw 'Expected ComboBox subclass' }
if($src -notmatch '\$choice=New-Object CafeEditorScrollComboBox') { throw 'Profile editor must use custom combo' }
if($code -notmatch 'if \(this.DroppedDown\)' -or $code -notmatch 'base.OnMouseWheel\(e\)') { throw 'Open dropdown must retain native wheel behavior' }
if($code -notmatch 'AutoScrollPosition' -or $code -notmatch 'VerticalScroll.Visible') { throw 'Closed dropdown must scroll tab panel' }
$combo=New-Object CafeEditorScrollComboBox
try {
    $combo.DropDownStyle='DropDownList'
    [void]$combo.Items.AddRange([object[]]@('A','B','C'))
    $combo.SelectedIndex=1
    # Call the protected wheel override directly. With no parent, the event
    # must not modify selection (regression against native ComboBox).
    $method=[CafeEditorScrollComboBox].GetMethod('OnMouseWheel',[Reflection.BindingFlags]'Instance,NonPublic')
    $wheel=New-Object System.Windows.Forms.MouseEventArgs ([System.Windows.Forms.MouseButtons]::None,0,0,0,-120)
    $null=$method.Invoke($combo,@($wheel))
    if($combo.SelectedIndex -ne 1) { throw 'Closed dropdown selection changed under mouse wheel' }
} finally { $combo.Dispose() }
Write-Host 'PASS: custom editor combo compiles, closed-wheel ignores selection, open dropdown retains native handling.'
