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
if($src -notmatch '\$wheelFilter=New-Object CafeProfileEditorWheelMessageFilter' -or $src -notmatch 'Application\]::AddMessageFilter\(\$wheelFilter\)' -or $src -notmatch 'Application\]::RemoveMessageFilter\(\$wheelFilter\)') { throw 'Profile editor must install and remove its scoped wheel message filter' }
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
$form=New-Object System.Windows.Forms.Form
$tabs=New-Object System.Windows.Forms.TabControl
$page=New-Object System.Windows.Forms.TabPage
$number=New-Object CafeEditorScrollNumericUpDown
try {
    $form.ClientSize=New-Object System.Drawing.Size(420,300)
    $tabs.Dock='Fill'
    $page.AutoScroll=$true
    $page.AutoScrollMinSize=New-Object System.Drawing.Size(800,800)
    $page.Text='Editor'
    [void]$tabs.TabPages.Add($page)
    $tabs.SelectedTab=$page
    $number.Location=New-Object System.Drawing.Point(20,20)
    $number.Minimum=0
    $number.Maximum=20
    $number.Value=7
    $page.Controls.Add($number)
    $form.Controls.Add($tabs)
    $form.ShowInTaskbar=$false
    $form.Opacity=0
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $form.CreateControl()
    $tabs.CreateControl()
    $page.CreateControl()
    $number.CreateControl()
    $filter=[CafeProfileEditorWheelMessageFilter]::new($tabs)
    $cursor=$number.PointToScreen([System.Drawing.Point]::new(2,2))
    $scrollBefore=-$page.AutoScrollPosition.Y
    $packedCoordinates=($cursor.X -band 0xffff) -bor (($cursor.Y -band 0xffff) -shl 16)
    $wheelMessage=[System.Windows.Forms.Message]::Create($number.Handle,0x020A,[IntPtr]::new([long](-120 -shl 16)),[IntPtr]::new([long]$packedCoordinates))
    $handled=$filter.PreFilterMessage([ref]$wheelMessage)
    if(-not $handled) { throw 'Wheel message over an editor input was not consumed by the tab filter' }
    if($number.Value -ne 7) { throw 'Consumed editor wheel message changed the focused numeric field' }
    if(-$page.AutoScrollPosition.Y -le $scrollBefore) { throw 'Consumed editor wheel message did not scroll the active tab' }
    if($filter.HandleWheel([System.Drawing.Point]::new(-10000,-10000),-120)) { throw 'Wheel message outside the editor tab was consumed' }
} finally { $form.Dispose() }
Write-Host 'PASS: editor wheel messages are intercepted at the tab level and controls retain their values.'
