Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$src=[IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'cafe.bat'))
if($src -notmatch '(?s)Add-Type -ReferencedAssemblies @\(''System.Windows.Forms'',''System.Drawing''\) -TypeDefinition @''\r?\n(?<code>.*?)\r?\n''@') { throw 'Editor combo subclass C# definition not found' }
$code=$Matches['code']
Add-Type -ReferencedAssemblies @('System.Windows.Forms','System.Drawing') -TypeDefinition $code
if(-not [CafeEditorScrollComboBox].IsSubclassOf([System.Windows.Forms.ComboBox])) { throw 'Expected ComboBox subclass' }
if(-not [CafeEditorScrollNumericUpDown].IsSubclassOf([System.Windows.Forms.NumericUpDown])) { throw 'Expected scroll-aware NumericUpDown subclass' }
if(-not [CafeEditorScrollTextBox].IsSubclassOf([System.Windows.Forms.TextBox])) { throw 'Expected scroll-aware TextBox subclass' }
if($src -notmatch '\$choice=New-Object CafeEditorScrollComboBox') { throw 'Profile editor must use custom combo' }
if($src -notmatch '\$numeric=New-Object CafeEditorScrollNumericUpDown') { throw 'Profile editor numeric fields must use scroll-aware control' }
if($src -notmatch '\$sens=New-Object CafeEditorScrollTextBox' -or $src -notmatch '\$crosshairShareCode=New-Object CafeEditorScrollTextBox' -or $src -notmatch '\$cfgFile=New-Object CafeEditorScrollTextBox') { throw 'Profile editor text fields must use scroll-aware control' }
if($src -notmatch '\$historyChoice=New-Object CafeEditorScrollComboBox') { throw 'Profile editor history dropdown must use custom combo' }
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
    $wheel=[System.Windows.Forms.MouseEventArgs]::new([System.Windows.Forms.MouseButtons]::None,0,0,0,-120)
    $null=$method.Invoke($combo,@($wheel))
    if($combo.SelectedIndex -ne 1) { throw 'Closed dropdown selection changed under mouse wheel' }
} finally { $combo.Dispose() }
$number=New-Object CafeEditorScrollNumericUpDown
try {
    $number.Minimum=0
    $number.Maximum=20
    $number.Value=7
    $method=[CafeEditorScrollNumericUpDown].GetMethod('OnMouseWheel',[Reflection.BindingFlags]'Instance,NonPublic')
    $null=$method.Invoke($number,@($wheel))
    if($number.Value -ne 7) { throw 'Numeric field value changed under mouse wheel' }
} finally { $number.Dispose() }
$text=New-Object CafeEditorScrollTextBox
try {
    $text.Text='preserve this value'
    $method=[CafeEditorScrollTextBox].GetMethod('OnMouseWheel',[Reflection.BindingFlags]'Instance,NonPublic')
    $null=$method.Invoke($text,@($wheel))
    if($text.Text -cne 'preserve this value') { throw 'Text field value changed under mouse wheel' }
} finally { $text.Dispose() }
Write-Host 'PASS: editor dropdowns, numeric fields, and text fields do not change values on a closed-control wheel event.'
