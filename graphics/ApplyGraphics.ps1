# CafeLauncher CS2 video-only module. Loaded manually by Apply Graphics.
# Never execute a profile, run CS2, or edit Steam localconfig.vdf.
function Get-VideoGraphicsRules {
    return [ordered]@{
        Width=@{Key='setting.defaultres';Min=640;Max=7680}
        Height=@{Key='setting.defaultresheight';Min=480;Max=4320}
        RefreshHz=@{Key='setting.refreshrate_numerator';Min=24;Max=600}
        AspectRatioMode=@{Key='setting.aspectratiomode';Allowed=@(0,1,2)}
        Fullscreen=@{Key='setting.fullscreen';Allowed=@(0,1)}
        MSAASamples=@{Key='setting.msaa_samples';Allowed=@(0,2,4,8,16)}
        ShadowQuality=@{Key='setting.videocfg_shadow_quality';Allowed=@(0,1,2,3)}
        DynamicShadows=@{Key='setting.videocfg_dynamic_shadows';Allowed=@(0,1)}
        TextureDetail=@{Key='setting.videocfg_texture_detail';Allowed=@(0,1,2,3)}
        ShaderQuality=@{Key='setting.shaderquality';Allowed=@(0,1,2)}
        ParticleDetail=@{Key='setting.videocfg_particle_detail';Allowed=@(0,1,2,3)}
        AmbientOcclusion=@{Key='setting.videocfg_ao_detail';Allowed=@(0,1,2,3)}
        HDRDetail=@{Key='setting.videocfg_hdr_detail';Allowed=@(-1,0,1,2,3)}
        NvidiaReflex=@{Key='setting.r_low_latency';Allowed=@(0,1,2)}
        TextureFiltering=@{Key='setting.r_texturefilteringquality';Allowed=@(0,1,2,3,4,5)}
        FSRDetail=@{Key='setting.videocfg_fsr_detail';Allowed=@(0,1,2,3,4)}
        VSync=@{Key='setting.mat_vsync';Allowed=@(0,1)}
        CMAA=@{Key='setting.r_csgo_cmaa_enable';Allowed=@(0,1)}
    }
}
function ConvertTo-VideoGraphicsSettings {
    param($Preset)
    $rules=Get-VideoGraphicsRules
    if ($null -eq $Preset -or $null -eq $Preset.Settings -or $Preset.Settings -isnot [pscustomobject]) {
        throw 'Graphics preset must contain a JSON Settings object.'
    }
    $settings=[ordered]@{}
    foreach($property in $Preset.Settings.PSObject.Properties){
        if(-not $rules.Contains($property.Name)){
            Write-Log ("Unknown graphics field ignored: "+$property.Name) 'WARN'
            continue
        }
        if($null -eq $property.Value){continue}
        $raw=[string]$property.Value
        if($property.Value -is [bool] -or $raw -notmatch '^-?[0-9]+$'){
            throw ("Non-integer graphics value: "+$property.Name)
        }
        $v=0
        if(-not [int]::TryParse($raw,[ref]$v)){throw ("Graphics value too large: "+$property.Name)}
        $rule=$rules[$property.Name]
        if(($rule.ContainsKey('Allowed') -and $v -notin $rule.Allowed) -or
           ($rule.ContainsKey('Min') -and $v -lt $rule.Min) -or
           ($rule.ContainsKey('Max') -and $v -gt $rule.Max)){
            throw ("Unsupported graphics value for "+$property.Name+": "+$v)
        }
        $settings[$property.Name]=$v
    }
    if($settings.Contains('Width') -xor $settings.Contains('Height')){
        throw 'Specify both Width and Height or leave both null for the current resolution.'
    }
    return ,$settings
}
function Assert-CS2GraphicsDisplayPolicy {
    param($Preset)
    $policy=if($Preset.PSObject.Properties['DisplayPolicy']){[string]$Preset.DisplayPolicy}else{
        if($Preset.ProfileName -ceq 'BrileMode'){'PreserveCurrent'}else{'ApplyPreset'}
    }
    if($policy -notin @('ApplyPreset','PreserveCurrent')){throw ('Unknown graphics display policy: '+$policy)}
    if($policy -eq 'PreserveCurrent'){
        foreach($field in @('Width','Height','RefreshHz','AspectRatioMode','Fullscreen')){
            $property=$Preset.Settings.PSObject.Properties[$field]
            if($property -and $null -ne $property.Value){
                throw ('PreserveCurrent display policy cannot set '+$field+'.')
            }
        }
    }
    $refreshPolicy=if($Preset.PSObject.Properties['RefreshPolicy'] -and $Preset.RefreshPolicy){[string]$Preset.RefreshPolicy}else{'Highest'}
    if($refreshPolicy -notin @('Highest','Exact')){throw ('Unknown graphics refresh policy: '+$refreshPolicy)}
    if($refreshPolicy -eq 'Exact' -and (-not $Preset.Settings.PSObject.Properties['RefreshHz'] -or $null -eq $Preset.Settings.RefreshHz)){
        throw 'Exact refresh policy requires a RefreshHz value.'
    }
    $scalingMode=if($Preset.PSObject.Properties['ScalingMode'] -and $null -ne $Preset.ScalingMode){[int]$Preset.ScalingMode}else{2}
    if($scalingMode -notin @(2,3,5)){throw ('Unsupported NVIDIA scaling mode: '+$scalingMode)}
    return $policy
}
function Get-CS2ModeGraphicsPreset {
    param([string]$ModeName)
    if($ModeName -notin @('FabMode','ArliMode','BrileMode','ArmlMode','OliMode')){throw 'Invalid graphics mode name.'}
    $url="https://raw.githubusercontent.com/fabjoncela/Cs-script/main/graphics/$ModeName.json"
    $cache=Join-Path $env:LOCALAPPDATA ("CafeLauncher\graphics-cache\"+$ModeName+'.json')
    $local=Join-Path (Split-Path -Parent $env:CAFE_SCRIPT) ("graphics\"+$ModeName+'.json')
    # An explicitly saved local customization wins until the user syncs it.
    # This lets the editor's Save Locally button work offline and prevents the
    # next online Apply Graphics click from silently replacing those edits.
    $profileSettingsPath=Join-Path $env:LOCALAPPDATA 'CafeLauncher\profiles.json'
    if(Test-Path -LiteralPath $profileSettingsPath -PathType Leaf){
        try{
            $savedProfiles=Get-Content -LiteralPath $profileSettingsPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
            $savedProfile=$savedProfiles.PSObject.Properties[$ModeName]
            $pendingProperty=if($savedProfile){$savedProfile.Value.PSObject.Properties['SyncPending']}else{$null}
            $graphicsProperty=if($savedProfile){$savedProfile.Value.PSObject.Properties['GraphicsSettings']}else{$null}
            if($savedProfile -and $pendingProperty -and [bool]$pendingProperty.Value -and $graphicsProperty -and $graphicsProperty.Value){
                $preset=$graphicsProperty.Value
                if($preset.ProfileName -cne $ModeName -or [int]$preset.SchemaVersion -ne 1){throw 'Local graphics profile/schema mismatch.'}
                [void](Assert-CS2GraphicsDisplayPolicy -Preset $preset)
                [void](ConvertTo-VideoGraphicsSettings -Preset $preset)
                Write-Log ("Using unsynced local "+$ModeName+" graphics customization.")
                return $preset
            }
        }catch{throw ("Could not safely read local graphics state; refusing to replace it with a cloud preset. "+$_.Exception.Message)}
    }
    try{
        [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $preset=Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 10 -Headers @{'Cache-Control'='no-cache'} -ErrorAction Stop
        if($preset.ProfileName -cne $ModeName -or [int]$preset.SchemaVersion -ne 1){throw 'Preset profile/schema mismatch.'}
        [void](Assert-CS2GraphicsDisplayPolicy -Preset $preset)
        [void](ConvertTo-VideoGraphicsSettings -Preset $preset)
        try{
            $dir=Split-Path -Parent $cache
            if(-not (Test-Path -LiteralPath $dir)){[void](New-Item -Path $dir -ItemType Directory -Force)}
            [IO.File]::WriteAllText($cache,($preset|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
        }catch{Write-Log ("Graphics cache warning: "+$_.Exception.Message) 'WARN'}
        Write-Log ("Loaded independent "+$ModeName+" graphics preset from GitHub.")
        return $preset
    }catch{Write-Log ("Graphics download unavailable: "+$_.Exception.Message) 'WARN'}
    foreach($file in @($cache,$local)){
        if(-not (Test-Path -LiteralPath $file -PathType Leaf)){continue}
        try{
            $preset=Get-Content -LiteralPath $file -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
            if($preset.ProfileName -cne $ModeName -or [int]$preset.SchemaVersion -ne 1){throw 'Preset profile/schema mismatch.'}
            [void](Assert-CS2GraphicsDisplayPolicy -Preset $preset)
            [void](ConvertTo-VideoGraphicsSettings -Preset $preset)
            Write-Log ("Using offline graphics preset: "+$file) 'WARN'
            return $preset
        }catch{Write-Log ("Invalid offline graphics preset: "+$_.Exception.Message) 'WARN'}
    }
    throw ("No valid "+$ModeName+" graphics preset; connect to GitHub once to cache it.")
}
function Get-ActiveSteamCS2Video {
    $reg=Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam\ActiveProcess' -ErrorAction Stop
    if($null -eq $reg.ActiveUser){throw 'Steam ActiveUser registry value missing. Sign in to Steam.'}
    $id=[long]$reg.ActiveUser
    if($id -lt 0){$id+=4294967296}
    if($id -le 0 -or $id -gt 4294967295){throw 'No active signed-in Steam account identified.'}
    $steam=Get-SteamExecutable
    if(-not $steam){throw 'Steam installation not found.'}
    $video=Join-Path (Split-Path -Parent $steam) ("userdata\"+$id+"\730\local\cfg\cs2_video.txt")
    if(-not (Test-Path -LiteralPath $video -PathType Leaf)){
        throw ("Missing cs2_video.txt for signed-in account "+$id+" at "+$video+". Launch CS2 once and save video settings.")
    }
    return [pscustomobject]@{Path=$video;AccountID=[string]$id}
}
function Find-CS2VideoSetting {
    param([string]$Text,[string]$Key)
    $pattern='(?m)^(?<before>[ \t]*"{0}"[ \t]+")(?<value>[^"\r\n]*)(?<after>"[ \t]*(?://[^\r\n]*)?\r?)$' -f [regex]::Escape($Key)
    $matches=[regex]::Matches($Text,$pattern)
    if($matches.Count -gt 1){throw ("Duplicate CS2 video setting: "+$Key)}
    if($matches.Count -eq 0){return $null}
    return $matches[0]
}
function Update-CS2VideoGraphicsText {
    param([string]$Text,[System.Collections.IDictionary]$Settings,[switch]$SkipDisplay)
    if($Text -notmatch '(?m)^[ \t]*"video.cfg"[ \t]*\r?$' -or
       $Text -notmatch '(?m)^[ \t]*\{[ \t]*\r?$' -or
       $Text -notmatch '(?m)^[ \t]*\}[ \t]*\r?$'){
        throw 'Unrecognized cs2_video.txt format; refusing to edit.'
    }
    $rules=Get-VideoGraphicsRules
    $modified=$Text
    $applied=New-Object 'System.Collections.Generic.List[string]'
    $skipped=New-Object 'System.Collections.Generic.List[string]'
    $changedFields=New-Object 'System.Collections.Generic.List[string]'
    foreach($field in @($Settings.Keys)){
        if(-not $rules.Contains($field)){continue}
        if($SkipDisplay -and $field -in @('Width','Height','RefreshHz','AspectRatioMode','Fullscreen')){
            $skipped.Add($field+' (unsupported display mode)');continue
        }
        $match=Find-CS2VideoSetting -Text $modified -Key $rules[$field].Key
        if($null -eq $match){$skipped.Add($field+' (not present in this CS2 version)');continue}
        $v=$match.Groups['value']
        $newValue=[string]$Settings[$field]
        if($v.Value -cne $newValue){$changedFields.Add($field)}
        $modified=$modified.Remove($v.Index,$v.Length).Insert($v.Index,$newValue)
        $applied.Add($field)
    }
    if($Settings.Contains('RefreshHz') -and -not $SkipDisplay -and $applied.Contains('RefreshHz')){
        $m=Find-CS2VideoSetting -Text $modified -Key 'setting.refreshrate_denominator'
        if($null -eq $m){throw 'Missing refresh denominator key; refusing a partial refresh update.'}
        $v=$m.Groups['value']
        if($v.Value -cne '1' -and -not $changedFields.Contains('RefreshHz')){$changedFields.Add('RefreshHz')}
        $modified=$modified.Remove($v.Index,$v.Length).Insert($v.Index,'1')
    }
    return [pscustomobject]@{Text=$modified;Applied=@($applied);Skipped=@($skipped);ChangedFields=@($changedFields);Changed=($modified -cne $Text)}
}

function Format-CS2GraphicsResultSummary {
    param([string]$ProfileName,[string]$AccountID,[string[]]$Applied,[string[]]$Skipped,
          [string[]]$ChangedFields,[string]$DisplaySummary,[string]$ScalingSummary,
          [string]$BackupPath,[bool]$FileChanged,[bool]$ScalingVerified)
    $lines=New-Object 'System.Collections.Generic.List[string]'
    $appliedItems=@($Applied|Where-Object{-not [string]::IsNullOrWhiteSpace([string]$_)})
    $skippedItems=@($Skipped|Where-Object{-not [string]::IsNullOrWhiteSpace([string]$_)})
    $changedItems=@($ChangedFields|Where-Object{-not [string]::IsNullOrWhiteSpace([string]$_)})
    $warning=($skippedItems.Count -gt 0 -or -not $ScalingVerified)
    $lines.Add($(if($warning){'Completed with warnings.'}else{'Completed successfully.'}))
    $lines.Add(('Profile: '+$ProfileName+' (Steam account '+$AccountID+')'))
    $lines.Add($(if($FileChanged){'CS2 video file: updated and read-back verified.'}else{'CS2 video file: supported settings already matched; no write needed.'}))
    $lines.Add(('Applied/confirmed ('+$appliedItems.Count+'): '+$(if($appliedItems.Count){$appliedItems -join ', '}else{'none'})))
    $lines.Add(('Changed ('+$changedItems.Count+'): '+$(if($changedItems.Count){$changedItems -join ', '}else{'none'})))
    $lines.Add(('Skipped ('+$skippedItems.Count+'): '+$(if($skippedItems.Count){$skippedItems -join '; '}else{'none'})))
    $lines.Add(('Display: '+$DisplaySummary))
    $lines.Add(('NVIDIA scaling: '+$ScalingSummary))
    if($BackupPath){$lines.Add(('Backup: '+$BackupPath))}
    return ($lines -join [Environment]::NewLine)
}
# Save a verified video update with two backups:
# - permanent copy in CafeLauncher/graphics-backups for user recovery
# - same-directory recovery copy required by .NET Framework File.Replace.
# Never use null as File.Replace's third argument on Windows PowerShell 5.1.
function Save-CS2VideoFileWithBackup {
    param([Parameter(Mandatory=$true)][string]$VideoPath,
          [Parameter(Mandatory=$true)][string]$ExpectedAccountID,
          [Parameter(Mandatory=$true)][string]$UpdatedText,
          [Parameter(Mandatory=$true)][System.Text.Encoding]$Encoding,
          [Parameter(Mandatory=$true)][string]$BackupPath)
    if ([string]::IsNullOrWhiteSpace($VideoPath) -or
        [string]::IsNullOrWhiteSpace($BackupPath) -or
        -not (Test-Path -LiteralPath $VideoPath -PathType Leaf)) {
        throw 'Graphics update paths invalid. No video changes made.'
    }
    $parent=Split-Path -Parent $VideoPath
    $id=[guid]::NewGuid().ToString('N')
    $temp=Join-Path $parent ('cs2_video.cafe-'+$id+'.tmp')
    $swapBackup=Join-Path $parent ('cs2_video.cafe-'+$id+'.bak')
    $replaced=$false
    $safeToRemoveSwap=$false
    # Steam can change accounts while the launcher remains open. Validate the
    # destination again at the last write boundary, not only during discovery.
    $active=Get-ActiveSteamCS2Video
    if($active.AccountID -cne $ExpectedAccountID -or
       -not [string]::Equals([IO.Path]::GetFullPath($active.Path),[IO.Path]::GetFullPath($VideoPath),[StringComparison]::OrdinalIgnoreCase)){
        throw 'The active Steam account changed during graphics preparation. No video settings were written.'
    }
    # The permanent backup is written before any replacement attempt.
    Copy-Item -LiteralPath $VideoPath -Destination $BackupPath -ErrorAction Stop
    try {
        [IO.File]::WriteAllText($temp,$UpdatedText,$Encoding)
        if (Get-Process -Name cs2 -ErrorAction SilentlyContinue) {
            throw 'CS2 started while preparing graphics. Original video file kept.'
        }
        $active=Get-ActiveSteamCS2Video
        if($active.AccountID -cne $ExpectedAccountID -or
           -not [string]::Equals([IO.Path]::GetFullPath($active.Path),[IO.Path]::GetFullPath($VideoPath),[StringComparison]::OrdinalIgnoreCase)){
            throw 'The active Steam account changed immediately before graphics replacement. Original video file kept.'
        }
        # File.Replace requires a LEGAL, NON-NULL third path on Windows.
        # Keep it next to the target for same-volume atomic replacement.
        [IO.File]::Replace($temp,$VideoPath,$swapBackup)
        $replaced=$true
        if ([IO.File]::ReadAllText($VideoPath,$Encoding) -cne $UpdatedText) {
            throw 'Video file verification failed after replace.'
        }
        $safeToRemoveSwap=$true
    } catch {
        # If a replacement happened, recover from the permanent original backup.
        if ($replaced -or (Test-Path -LiteralPath $swapBackup -PathType Leaf)) {
            try {
                Copy-Item -LiteralPath $BackupPath -Destination $VideoPath -Force -ErrorAction Stop
                $safeToRemoveSwap=$true
                Write-Log ('Graphics write failed; original video file restored from '+$BackupPath) 'WARN'
            } catch {
                Write-Log ('CRITICAL: graphics rollback failed; restore manually using '+$BackupPath) 'ERROR'
            }
        }
        throw
    } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        if ($safeToRemoveSwap) {
            Remove-Item -LiteralPath $swapBackup -Force -ErrorAction SilentlyContinue
        }
    }
}

function Apply-CS2ModeGraphics {
    param([string]$ModeName)
    Write-Log ("Clicked: Apply Graphics "+$ModeName)
    try{
        if(Get-Process -Name cs2 -ErrorAction SilentlyContinue){throw 'CS2 is running. Close it before applying graphics.'}
        $preset=Get-CS2ModeGraphicsPreset -ModeName $ModeName
        $displayPolicy=Assert-CS2GraphicsDisplayPolicy -Preset $preset
        $refreshPolicy=if($preset.PSObject.Properties['RefreshPolicy'] -and $preset.RefreshPolicy){[string]$preset.RefreshPolicy}else{'Highest'}
        $scalingMode=if($preset.PSObject.Properties['ScalingMode'] -and $null -ne $preset.ScalingMode){[int]$preset.ScalingMode}else{2}
        $settings=ConvertTo-VideoGraphicsSettings -Preset $preset
        if($settings.Count -eq 0){throw 'Graphics preset has no values selected.'}
        $displaySummary=if($displayPolicy -eq 'PreserveCurrent'){'preserved by this profile policy.'}else{'not changed by this preset.'}
        $hardwareSkipped=New-Object 'System.Collections.Generic.List[string]'
        if($displayPolicy -eq 'PreserveCurrent'){
            Write-Log ($ModeName+' display policy: preserving the current CS2 resolution, refresh and fullscreen/aspect settings; only graphics-quality fields will change.')
        }
        $active=Get-ActiveSteamCS2Video
        $bytes=[IO.File]::ReadAllBytes($active.Path)
        if($bytes.Length -lt 16 -or $bytes.Length -gt 1048576){throw 'cs2_video.txt size is unexpected.'}
        $encoding=New-Object Text.UTF8Encoding($false,$true);$bom=0
        if($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191){
            $encoding=New-Object Text.UTF8Encoding($true,$true);$bom=3
        }elseif($bytes[0] -eq 255 -and $bytes[1] -eq 254){
            $encoding=New-Object Text.UnicodeEncoding($false,$true,$true);$bom=2
        }elseif($bytes[0] -eq 254 -and $bytes[1] -eq 255){
            $encoding=New-Object Text.UnicodeEncoding($true,$true,$true);$bom=2
        }
        $before=$encoding.GetString($bytes,$bom,$bytes.Length-$bom)
        $skipDisplay=$false
        if($settings.Contains('Width') -or $settings.Contains('RefreshHz')){
            if($settings.Contains('Width')){$w=[int]$settings['Width']}else{
                $m=Find-CS2VideoSetting $before 'setting.defaultres'
                if(-not $m -or $m.Groups['value'].Value -notmatch '^\d+$'){throw 'Cannot verify existing resolution width.'}
                $w=[int]$m.Groups['value'].Value
            }
            if($settings.Contains('Height')){$h=[int]$settings['Height']}else{
                $m=Find-CS2VideoSetting $before 'setting.defaultresheight'
                if(-not $m -or $m.Groups['value'].Value -notmatch '^\d+$'){throw 'Cannot verify existing resolution height.'}
                $h=[int]$m.Groups['value'].Value
            }
            $refreshNumerator=Find-CS2VideoSetting $before 'setting.refreshrate_numerator'
            $refreshDenominator=Find-CS2VideoSetting $before 'setting.refreshrate_denominator'
            if($null -eq $refreshNumerator -or $null -eq $refreshDenominator){
                $skipDisplay=$true
                $displaySummary='fallback: CS2 video config lacks refresh numerator/denominator; existing resolution, refresh, and display mode were preserved.'
                Write-Log $displaySummary 'WARN'
            }else{
                $requestedHz=if($settings.Contains('RefreshHz')){[int]$settings['RefreshHz']}else{0}
                $hz=0
                $modeFound=$false
                if('FabDisplayNative' -as [type]){
                    if($refreshPolicy -eq 'Exact' -and $requestedHz -ge 24){
                        $modeFound=[FabDisplayNative]::IsAdvertisedMode($w,$h,$requestedHz)
                        if($modeFound){$hz=$requestedHz}
                    }else{
                        $hz=[FabDisplayNative]::GetHighestRefreshForResolution($w,$h)
                        $modeFound=$hz -ge 24
                    }
                }
                if($modeFound -and $hz -ge 24){
                    $settings['RefreshHz']=$hz
                    $displaySummary=('applied '+$w+'x'+$h+' @ '+$hz+' Hz ('+$refreshPolicy+' refresh policy).')
                    if($refreshPolicy -eq 'Exact'){
                        Write-Log ("CS2 display mode "+$w+'x'+$h+": applying selected refresh "+$hz+'Hz (Exact).')
                    }elseif($requestedHz -gt 0 -and $requestedHz -ne $hz){
                        Write-Log ("CS2 display mode "+$w+'x'+$h+": using highest advertised refresh "+$hz+'Hz instead of preset '+$requestedHz+'Hz.')
                    }else{
                        Write-Log ("CS2 display mode "+$w+'x'+$h+": using highest advertised refresh "+$hz+'Hz.')
                    }
                }else{
                    $skipDisplay=$true
                    if($refreshPolicy -eq 'Exact'){
                        if('FabDisplayNative' -as [type]){
                            $highestAtResolution=[FabDisplayNative]::GetHighestRefreshForResolution($w,$h)
                            if($highestAtResolution -ge 24){
                                $displaySummary=('fallback: DISPLAY1 supports '+$w+'x'+$h+' but not the requested exact '+$requestedHz+' Hz; highest advertised is '+$highestAtResolution+' Hz. Existing display settings were preserved.')
                            }else{
                                $displaySummary=('fallback: DISPLAY1 does not advertise CS2 resolution '+$w+'x'+$h+'; existing resolution, refresh, and display mode were preserved.')
                            }
                        }else{
                            $displaySummary=('fallback: display modes could not be queried; existing resolution, refresh, and display mode were preserved.')
                        }
                    }else{
                        if('FabDisplayNative' -as [type]){
                            $displaySummary=('fallback: DISPLAY1 has no supported progressive refresh mode at CS2 resolution '+$w+'x'+$h+'; existing resolution, refresh, and display mode were preserved.')
                        }else{
                            $displaySummary=('fallback: display modes could not be queried; existing resolution, refresh, and display mode were preserved.')
                        }
                    }
                    Write-Log $displaySummary 'WARN'
                }
            }
        }
        if($settings.Contains('NvidiaReflex')){
            $gpu=@(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue|Where-Object {$_.Name -match 'NVIDIA'}).Count -gt 0
            if(-not $gpu){
                [void]$settings.Remove('NvidiaReflex')
                $hardwareSkipped.Add('NvidiaReflex (no NVIDIA GPU detected; current value preserved)')
                Write-Log 'No NVIDIA GPU detected; preserving NVIDIA Reflex.' 'WARN'
            }
        }
        $edit=Update-CS2VideoGraphicsText -Text $before -Settings $settings -SkipDisplay:$skipDisplay
        $displayKeySkips=@($edit.Skipped|Where-Object{$_ -match '^(Width|Height|RefreshHz|AspectRatioMode|Fullscreen) '})
        if(-not $skipDisplay -and $displayKeySkips.Count -gt 0){
            $displaySummary+=(' CS2 video config did not contain: '+(($displayKeySkips|ForEach-Object{($_ -split ' ',2)[0]}) -join ', ')+'.')
        }
        foreach($skipped in $edit.Skipped){Write-Log ("Skipped graphics key: "+$skipped) 'WARN'}
        if($edit.Applied.Count -eq 0){throw 'No compatible video setting keys found; nothing changed.'}
        $backup=$null
        if($edit.Changed){
            if(Get-Process -Name cs2 -ErrorAction SilentlyContinue){throw 'CS2 started during preparation; original file kept.'}
            $backupFolder=Join-Path $env:LOCALAPPDATA ("CafeLauncher\graphics-backups\"+$active.AccountID)
            if(-not (Test-Path -LiteralPath $backupFolder)){[void](New-Item -ItemType Directory -Path $backupFolder -Force)}
            $backup=Join-Path $backupFolder ("cs2_video-"+$ModeName+'-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.txt')
            Save-CS2VideoFileWithBackup -VideoPath $active.Path -ExpectedAccountID $active.AccountID -UpdatedText $edit.Text -Encoding $encoding -BackupPath $backup
        }else{Write-Log ($ModeName+' CS2 video settings already match; no file write.')}
        if('FabNvApi' -as [type]){
            $scalingReport=''
            $scalingVerified=[FabNvApi]::TrySetGpuScalingMode($scalingMode,[ref]$scalingReport)
            if($scalingVerified){Write-Log $scalingReport}
            else{Write-Log ('CS2 graphics saved, but NVIDIA scaling was not verified: '+$scalingReport) 'WARN'}
        }else{
            $scalingVerified=$false
            $scalingReport='could not be changed because NVAPI is unavailable.'
            Write-Log ('CS2 graphics saved; NVIDIA scaling '+$scalingReport) 'WARN'
        }
        if($edit.Changed){Write-Log ("Applied "+$edit.Applied.Count+' graphics keys for '+$ModeName+' (Steam '+$active.AccountID+'). Backup: '+$backup)}
        else{Write-Log ("Verified/applied NVIDIA scaling mode for "+$ModeName+' (Steam '+$active.AccountID+').')}
        $allSkipped=@($edit.Skipped)+@($hardwareSkipped.ToArray())
        $appliedDetails=@($edit.Applied | ForEach-Object { $field=[string]$_; $field+'='+[string]$settings[$field] })
        $summary=Format-CS2GraphicsResultSummary -ProfileName $ModeName -AccountID $active.AccountID `
            -Applied $appliedDetails -Skipped $allSkipped -ChangedFields @($edit.ChangedFields) `
            -DisplaySummary $displaySummary -ScalingSummary $scalingReport -BackupPath $backup `
            -FileChanged ([bool]$edit.Changed) -ScalingVerified ([bool]$scalingVerified)
        $graphicsRun='Graphics '+$ModeName
        if(Get-Command Set-RunOutcome -ErrorAction SilentlyContinue){
            $graphicsState=if($allSkipped.Count -gt 0 -or $displaySummary -match '^fallback:'){'FALLBACK'}else{'APPLIED'}
            Set-RunOutcome -Run $graphicsRun -Setting 'CS2 video settings' `
                -Requested ($settings.Keys -join ', ') -Target ('Steam account '+$active.AccountID) `
                -Status $graphicsState -Actual ($appliedDetails -join ', ') `
                -Detail (($displaySummary)+$(if($allSkipped.Count){' Skipped: '+($allSkipped -join '; ')}else{''}))
            Set-RunOutcome -Run $graphicsRun -Setting 'NVIDIA scaling' -Requested ([string]$scalingMode) `
                -Target ('Display for Steam account '+$active.AccountID) -Status $(if($scalingVerified){'APPLIED'}else{'FAILED'}) `
                -Actual $scalingReport -Detail $scalingReport
        }
        foreach($summaryLine in ($summary -split '\r?\n')){
            if(-not [string]::IsNullOrWhiteSpace($summaryLine)){
                $summaryLevel=if($summaryLine -eq 'Completed with warnings.'){'WARN'}else{'INFO'}
                Write-Log ('Apply Graphics | '+$summaryLine) $summaryLevel
            }
        }
        [void][System.Windows.Forms.MessageBox]::Show(
            ($summary+[Environment]::NewLine+[Environment]::NewLine+'Launch CS2 to use the video settings.'),
            'CS2 Graphics Result','OK',$(if($allSkipped.Count -gt 0 -or -not $scalingVerified){'Warning'}else{'Information'}))
    }catch{
        Write-Log ("Apply Graphics failed for "+$ModeName+': '+$_.Exception.Message) 'ERROR'
        [void][System.Windows.Forms.MessageBox]::Show(
            ('Could not apply '+$ModeName+' graphics:'+[Environment]::NewLine+$_.Exception.Message+
             [Environment]::NewLine+'Original video settings were not intentionally changed. Check LIVE LOGS.'),
            'CS2 Graphics Not Applied','OK','Warning')
    }
}
