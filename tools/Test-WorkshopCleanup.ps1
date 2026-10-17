# CS2 Workshop cleanup tests; every file and deletion stays inside a temporary fixture.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$bat=[IO.File]::ReadAllText((Join-Path $repo 'cafe.bat'))
$marker=$bat.IndexOf('# POWERSHELL_GUI',[StringComparison]::Ordinal)
if($marker -lt 0){throw 'Missing launcher PowerShell marker.'}
$source=$bat.Substring($bat.IndexOf("`n",$marker)+1)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw 'Launcher PowerShell failed to parse.'}
$wanted=@('ConvertFrom-CafeSteamVdfText','Get-CafeWorkshopManifestSnapshot','Get-CafeWorkshopDirectorySize',
    'Get-CafeWorkshopCleanupSnapshot','Remove-CafeWorkshopItems')
$definitions=@{}
foreach($function in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
    if($function.Name -in $wanted){$definitions[$function.Name]=$function.Extent.Text}
}
foreach($name in $wanted){if(-not $definitions.ContainsKey($name)){throw ('Missing function under test: '+$name)}}
foreach($name in $wanted){Invoke-Expression $definitions[$name]}

function Get-Process {
    [CmdletBinding()]
    param([string]$Name)
    if($Name -eq 'cs2' -and $script:TestRunningCS2){return @([pscustomobject]@{Id=900;ProcessName='cs2'})}
    return @()
}
function Write-Log { param([string]$Message,[string]$Level='INFO') }

function New-TestWorkshopLibrary {
    param([string]$Root,[string[]]$Subscribed=@('111111','333333'),[string[]]$Installed=@('111111','222222','333333'),
        [string]$NeedsDownload='0',[string]$NeedsUpdate='0',[string]$AppId='730',[string]$Subscriber='')
    $workshop=Join-Path $Root 'steamapps\workshop'
    $content=Join-Path $workshop 'content\730'
    [void](New-Item -ItemType Directory -Path $content -Force)
    foreach($id in $Installed){[void](New-Item -ItemType Directory -Path (Join-Path $content $id) -Force);[IO.File]::WriteAllText((Join-Path (Join-Path $content $id) 'map.vpk'),'fixture')}
    $detail=@()
    foreach($id in $Subscribed){
        $subscriberLine=if($Subscriber){'    "subscribedby" "'+$Subscriber+'"'}else{''}
        $detail+=@"
        "$id"
        {
            "manifest" "123456"
            "timeupdated" "1700000000"
$subscriberLine
        }
"@
    }
    $installedLines=@()
    foreach($id in $Installed){$installedLines+=@"
        "$id"
        {
            "size" "6"
            "manifest" "123456"
            "timeupdated" "1700000000"
        }
"@}
    $text=@"
"AppWorkshop"
{
    "appid" "$AppId"
    "NeedsDownload" "$NeedsDownload"
    "NeedsUpdate" "$NeedsUpdate"
    "WorkshopItemDetails"
    {
$($detail -join "`n")
    }
    "WorkshopItemsInstalled"
    {
$($installedLines -join "`n")
    }
}
"@
    [IO.File]::WriteAllText((Join-Path $workshop 'appworkshop_730.acf'),$text,[Text.Encoding]::UTF8)
    return $Root
}

$sandbox=Join-Path $env:TEMP ('CafeLauncher-WorkshopCleanup-'+[Guid]::NewGuid().ToString('N'))
try{
    $script:TestRunningCS2=$false
    # The parser accepts normal Valve KeyValues quoting and rejects duplicate or malformed structure.
    $parsed=ConvertFrom-CafeSteamVdfText -Text '"root" { "value" "a\\b" "child" { "id" "111111" } }'
    if($parsed.root.value -cne 'a\b' -or $parsed.root.child.id -cne '111111'){throw 'VDF parser did not decode a normal nested manifest correctly.'}
    $duplicateRejected=$false
    try{[void](ConvertFrom-CafeSteamVdfText -Text '"root" { "id" "1" "id" "2" }')}catch{$duplicateRejected=$true}
    if(-not $duplicateRejected){throw 'VDF parser accepted a duplicate key.'}
    $malformedRejected=$false
    try{[void](ConvertFrom-CafeSteamVdfText -Text '"root" { "id" "1"')}catch{$malformedRejected=$true}
    if(-not $malformedRejected){throw 'VDF parser accepted an unclosed object.'}

    $primary=New-TestWorkshopLibrary -Root (Join-Path $sandbox 'LibraryA')
    $snapshot=Get-CafeWorkshopCleanupSnapshot -LibraryRoots @($primary) -ActiveAccountID '123456'
    $subscribed=@($snapshot.Entries|Where-Object{$_.WorkshopID -eq '111111'}|Select-Object -First 1)
    $candidate=@($snapshot.Entries|Where-Object{$_.WorkshopID -eq '222222'}|Select-Object -First 1)
    if(-not $subscribed -or $subscribed[0].CanRemove -or $subscribed[0].Status -notlike 'Keep*'){throw 'A subscribed Workshop item was not protected.'}
    if(-not $candidate -or -not $candidate[0].CanRemove){throw 'An installed item absent from the active manifest was not offered as a cleanup candidate.'}
    if($candidate[0].Bytes -ne 7){throw 'Workshop item size estimate was incorrect.'}

    # A second library's subscribed copy protects that ID even if another library has an orphan folder.
    $second=New-TestWorkshopLibrary -Root (Join-Path $sandbox 'LibraryB') -Subscribed @('222222') -Installed @('222222')
    $multi=Get-CafeWorkshopCleanupSnapshot -LibraryRoots @($primary,$second) -ActiveAccountID '123456'
    $crossLibrary=@($multi.Entries|Where-Object{$_.WorkshopID -eq '222222'})
    if(@($crossLibrary|Where-Object{$_.CanRemove}).Count){throw ('Subscriptions='+($multi.Subscriptions -join ',')+'; per-library='+(($multi.Libraries|ForEach-Object{$_.LibraryRoot+' => '+($_.Subscriptions -join ',')+' trusted='+$_.Trusted}) -join '; ')+'; items='+(($crossLibrary|ForEach-Object{$_.LibraryRoot+': '+$_.Status+' (remove='+$_.CanRemove+')'}) -join '; '))}

    # An incomplete manifest in any library that contains CS2 Workshop state blocks every cleanup candidate.
    $unknownLibrary=Join-Path $sandbox 'UnknownLibrary'
    [void](New-Item -ItemType Directory -Path (Join-Path $unknownLibrary 'steamapps\workshop\content\730\444444') -Force)
    $incomplete=Get-CafeWorkshopCleanupSnapshot -LibraryRoots @($primary,$unknownLibrary) -ActiveAccountID '123456'
    if(@($incomplete.Entries|Where-Object{$_.CanRemove}).Count -or @($incomplete.Entries|Where-Object{$_.Status -like 'Unknown*'}).Count -lt 2){throw ('An incomplete library manifest did not block candidates across all libraries: '+(($incomplete.Entries|ForEach-Object{$_.WorkshopID+': '+$_.Status+' (remove='+$_.CanRemove+')'}) -join '; '))}

    # Missing, malformed, wrong-app, account-mismatched, or busy manifests never authorize deletion.
    $missingRoot=Join-Path $sandbox 'MissingManifest'
    [void](New-Item -ItemType Directory -Path (Join-Path $missingRoot 'steamapps\workshop\content\730\444444') -Force)
    $missing=Get-CafeWorkshopCleanupSnapshot -LibraryRoots @($missingRoot) -ActiveAccountID '123456'
    if(@($missing.Entries|Where-Object{$_.CanRemove}).Count -or @($missing.Entries|Where-Object{$_.Status -like 'Unknown*'}).Count -ne 1){throw 'Missing subscription state did not fail closed.'}

    $busy=New-TestWorkshopLibrary -Root (Join-Path $sandbox 'Busy') -NeedsDownload '1'
    $busyScan=Get-CafeWorkshopCleanupSnapshot -LibraryRoots @($busy) -ActiveAccountID '123456'
    if(@($busyScan.Entries|Where-Object{$_.CanRemove}).Count){throw 'Pending Steam downloads did not block cleanup.'}

    $downloading=New-TestWorkshopLibrary -Root (Join-Path $sandbox 'Downloading')
    [void](New-Item -ItemType Directory -Path (Join-Path $downloading 'steamapps\downloading\730') -Force)
    [IO.File]::WriteAllText((Join-Path $downloading 'steamapps\downloading\730\partial.tmp'),'partial')
    $downloadScan=Get-CafeWorkshopCleanupSnapshot -LibraryRoots @($downloading) -ActiveAccountID '123456'
    if(@($downloadScan.Entries|Where-Object{$_.CanRemove}).Count){throw 'An active Steam download directory did not block cleanup.'}

    $wrong=New-TestWorkshopLibrary -Root (Join-Path $sandbox 'WrongApp') -AppId '440'
    $wrongScan=Get-CafeWorkshopCleanupSnapshot -LibraryRoots @($wrong) -ActiveAccountID '123456'
    if(@($wrongScan.Entries|Where-Object{$_.CanRemove}).Count){throw 'A manifest for another Steam app authorized cleanup.'}

    $accountRoot=New-TestWorkshopLibrary -Root (Join-Path $sandbox 'WrongAccount') -Subscriber '999999'
    $accountScan=Get-CafeWorkshopCleanupSnapshot -LibraryRoots @($accountRoot) -ActiveAccountID '123456'
    if(@($accountScan.Entries|Where-Object{$_.CanRemove}).Count){throw 'A manifest identifying another account authorized cleanup.'}

    $badId=New-TestWorkshopLibrary -Root (Join-Path $sandbox 'BadId')
    $badIdManifest=Join-Path $badId 'steamapps\workshop\appworkshop_730.acf'
    $badIdText=[IO.File]::ReadAllText($badIdManifest).Replace('"111111"','"../../escape"')
    [IO.File]::WriteAllText($badIdManifest,$badIdText,[Text.Encoding]::UTF8)
    $badIdScan=Get-CafeWorkshopCleanupSnapshot -LibraryRoots @($badId) -ActiveAccountID '123456'
    if(@($badIdScan.Entries|Where-Object{$_.CanRemove}).Count){throw 'A malformed Workshop ID authorized cleanup.'}

    # A changed account, manifest, or unconfirmed call cannot remove fixture content.
    $removePath=Join-Path $primary 'steamapps\workshop\content\730\222222'
    $selectedCandidate=@($snapshot.Entries|Where-Object{$_.WorkshopID -eq '222222' -and $_.CanRemove}|Select-Object -First 1)
    $accountChanged=$false
    $differentAccount=Get-CafeWorkshopCleanupSnapshot -LibraryRoots @($primary) -ActiveAccountID '123457'
    try{Remove-CafeWorkshopItems -Preview $snapshot -FreshSnapshot $differentAccount -SelectedEntries $selectedCandidate -Confirmed}catch{$accountChanged=$_.Exception.Message -match 'account changed'}
    if(-not $accountChanged -or -not (Test-Path -LiteralPath $removePath -PathType Container)){throw 'Account-change verification did not refuse removal.'}

    $manifestChanged=$false
    $manifestPath=Join-Path $primary 'steamapps\workshop\appworkshop_730.acf'
    [IO.File]::AppendAllText($manifestPath,"`n// fixture change`n")
    $changedScan=Get-CafeWorkshopCleanupSnapshot -LibraryRoots @($primary) -ActiveAccountID '123456'
    try{Remove-CafeWorkshopItems -Preview $snapshot -FreshSnapshot $changedScan -SelectedEntries $selectedCandidate -Confirmed}catch{$manifestChanged=$_.Exception.Message -match 'data changed'}
    if(-not $manifestChanged -or -not (Test-Path -LiteralPath $removePath -PathType Container)){throw 'Manifest-change verification did not refuse removal.'}
    [IO.File]::WriteAllText($manifestPath,[IO.File]::ReadAllText((Join-Path (New-TestWorkshopLibrary -Root (Join-Path $sandbox 'Fresh')) 'steamapps\workshop\appworkshop_730.acf')),[Text.Encoding]::UTF8)
    $freshPreview=Get-CafeWorkshopCleanupSnapshot -LibraryRoots @($primary) -ActiveAccountID '123456'
    $unconfirmed=$false
    $selectedFresh=@($freshPreview.Entries|Where-Object{$_.WorkshopID -eq '222222' -and $_.CanRemove}|Select-Object -First 1)
    try{Remove-CafeWorkshopItems -Preview $freshPreview -FreshSnapshot $freshPreview -SelectedEntries $selectedFresh}catch{$unconfirmed=$_.Exception.Message -match 'explicit confirmation'}
    if(-not $unconfirmed -or -not (Test-Path -LiteralPath $removePath -PathType Container)){throw 'Removal without confirmation changed fixture files.'}

    $script:TestRunningCS2=$true
    $cs2Blocked=$false
    try{Remove-CafeWorkshopItems -Preview $freshPreview -FreshSnapshot $freshPreview -SelectedEntries $selectedFresh -Confirmed}catch{$cs2Blocked=$_.Exception.Message -match 'Close CS2'}
    $script:TestRunningCS2=$false
    if(-not $cs2Blocked -or -not (Test-Path -LiteralPath $removePath -PathType Container)){throw 'Running CS2 did not block cleanup.'}

    $outside=Join-Path $sandbox 'OutsideTarget'
    [void](New-Item -ItemType Directory -Path $outside -Force)
    [IO.File]::WriteAllText((Join-Path $outside 'keep.txt'),'keep')
    $outsideEntries=@($freshPreview.Entries|ForEach-Object{[pscustomobject]@{WorkshopID=$_.WorkshopID;LibraryRoot=$_.LibraryRoot;Path=$_.Path;Bytes=$_.Bytes;CanRemove=$_.CanRemove}})
    ($outsideEntries|Where-Object{$_.WorkshopID -eq '222222'}|Select-Object -First 1).Path=$outside
    $outsidePreview=[pscustomobject]@{AccountID=$freshPreview.AccountID;ManifestSignature=$freshPreview.ManifestSignature;Entries=$outsideEntries}
    $outsideBlocked=$false
    $outsideSelection=@($outsideEntries|Where-Object{$_.WorkshopID -eq '222222' -and $_.CanRemove}|Select-Object -First 1)
    try{Remove-CafeWorkshopItems -Preview $outsidePreview -FreshSnapshot $outsidePreview -SelectedEntries $outsideSelection -Confirmed}catch{$outsideBlocked=$_.Exception.Message -match 'outside the expected'}
    if(-not $outsideBlocked -or -not (Test-Path -LiteralPath (Join-Path $outside 'keep.txt'))){throw 'A path outside the selected Workshop ID root was not blocked.'}

    $removed=@(Remove-CafeWorkshopItems -Preview $freshPreview -FreshSnapshot $freshPreview -SelectedEntries $selectedFresh -Confirmed)
    if($removed.Count -ne 1 -or $removed[0].Status -ne 'Removed' -or (Test-Path -LiteralPath $removePath)){throw 'Confirmed fixture cleanup did not remove only the selected item.'}
    if(-not (Test-Path -LiteralPath (Join-Path $primary 'steamapps\workshop\content\730\111111') -PathType Container)){throw 'Cleanup removed a subscribed Workshop item.'}
    if(-not (Test-Path -LiteralPath (Join-Path $primary 'steamapps\workshop\appworkshop_730.acf') -PathType Leaf)){throw 'Cleanup modified the Steam Workshop manifest.'}

    # Duplicate IDs in different libraries remain independently selectable by their exact local path.
    $duplicatePrimary=New-TestWorkshopLibrary -Root (Join-Path $sandbox 'DuplicateA') -Installed @('222222')
    $duplicateSecondary=New-TestWorkshopLibrary -Root (Join-Path $sandbox 'DuplicateB') -Installed @('222222')
    $duplicateScan=Get-CafeWorkshopCleanupSnapshot -LibraryRoots @($duplicatePrimary,$duplicateSecondary) -ActiveAccountID '123456'
    $duplicateEntries=@($duplicateScan.Entries|Where-Object{$_.WorkshopID -eq '222222' -and $_.CanRemove})
    if($duplicateEntries.Count -ne 2){throw 'Duplicate local Workshop folders were not listed as independent candidates.'}
    $oneDuplicate=@($duplicateEntries|Where-Object{$_.LibraryRoot -eq $duplicatePrimary})
    [void](Remove-CafeWorkshopItems -Preview $duplicateScan -FreshSnapshot $duplicateScan -SelectedEntries $oneDuplicate -Confirmed)
    if((Test-Path -LiteralPath $oneDuplicate[0].Path) -or -not (Test-Path -LiteralPath ($duplicateEntries|Where-Object{$_.LibraryRoot -eq $duplicateSecondary}|Select-Object -First 1 -ExpandProperty Path))){throw 'Selecting one duplicate ID removed the wrong library copy or removed more than selected.'}

    Write-Host 'PASS: Steam VDF parsing, subscription protection, multi-library keep behavior, incomplete/stale/invalid state refusal, account/manifest rechecks, confirmation gate, path containment, and independently selected folder removal.'
}finally{
    if(Test-Path -LiteralPath $sandbox){Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue}
}
