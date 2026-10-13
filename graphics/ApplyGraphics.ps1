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
function Get-CS2ModeGraphicsPreset {
    param([string]$ModeName)
    if($ModeName -notin @('FabMode','ArliMode','BrileMode','ArmlMode','OliMode')){throw 'Invalid graphics mode name.'}
    $url="https://raw.githubusercontent.com/fabjoncela/Cs-script/main/graphics/$ModeName.json"
    $cache=Join-Path $env:LOCALAPPDATA ("CafeLauncher\graphics-cache\"+$ModeName+'.json')
    $local=Join-Path (Split-Path -Parent $env:CAFE_SCRIPT) ("graphics\"+$ModeName+'.json')
    try{
        [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $preset=Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 10 -Headers @{'Cache-Control'='no-cache'} -ErrorAction Stop
        if($preset.ProfileName -cne $ModeName -or [int]$preset.SchemaVersion -ne 1){throw 'Preset profile/schema mismatch.'}
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
    foreach($field in @($Settings.Keys)){
        if(-not $rules.Contains($field)){continue}
        if($SkipDisplay -and $field -in @('Width','Height','RefreshHz')){
            $skipped.Add($field+' (unsupported display mode)');continue
        }
        $match=Find-CS2VideoSetting -Text $modified -Key $rules[$field].Key
        if($null -eq $match){$skipped.Add($field+' (not present in this CS2 version)');continue}
        $v=$match.Groups['value']
        $modified=$modified.Remove($v.Index,$v.Length).Insert($v.Index,[string]$Settings[$field])
        $applied.Add($field)
    }
    if($Settings.Contains('RefreshHz') -and -not $SkipDisplay -and $applied.Contains('RefreshHz')){
        $m=Find-CS2VideoSetting -Text $modified -Key 'setting.refreshrate_denominator'
        if($null -eq $m){throw 'Missing refresh denominator key; refusing a partial refresh update.'}
        $v=$m.Groups['value']
        $modified=$modified.Remove($v.Index,$v.Length).Insert($v.Index,'1')
    }
    return [pscustomobject]@{Text=$modified;Applied=@($applied);Skipped=@($skipped);Changed=($modified -cne $Text)}
}
function Apply-CS2ModeGraphics {
    param([string]$ModeName)
    Write-Log ("Clicked: Apply Graphics "+$ModeName)
    try{
        if(Get-Process -Name cs2 -ErrorAction SilentlyContinue){throw 'CS2 is running. Close it before applying graphics.'}
        $preset=Get-CS2ModeGraphicsPreset -ModeName $ModeName
        $settings=ConvertTo-VideoGraphicsSettings -Preset $preset
        if($settings.Count -eq 0){throw 'Graphics preset has no values selected.'}
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
            $hz=if($settings.Contains('RefreshHz')){[int]$settings['RefreshHz']}else{0}
            if(-not ('FabDisplayNative' -as [type]) -or -not [FabDisplayNative]::IsAdvertisedMode($w,$h,$hz)){
                $skipDisplay=$true
                Write-Log ("DISPLAY1 does not advertise "+$w+'x'+$h+'@'+$hz+'Hz; preserving resolution and refresh.') 'WARN'
            }
        }
        if($settings.Contains('NvidiaReflex')){
            $gpu=@(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue|Where-Object {$_.Name -match 'NVIDIA'}).Count -gt 0
            if(-not $gpu){
                [void]$settings.Remove('NvidiaReflex')
                Write-Log 'No NVIDIA GPU detected; preserving NVIDIA Reflex.' 'WARN'
            }
        }
        $edit=Update-CS2VideoGraphicsText -Text $before -Settings $settings -SkipDisplay:$skipDisplay
        foreach($skipped in $edit.Skipped){Write-Log ("Skipped graphics key: "+$skipped) 'WARN'}
        if($edit.Applied.Count -eq 0){throw 'No compatible video setting keys found; nothing changed.'}
        if(-not $edit.Changed){Write-Log ($ModeName+' graphics already match; no file write.');return}
        if(Get-Process -Name cs2 -ErrorAction SilentlyContinue){throw 'CS2 started during preparation; original file kept.'}
        $backupFolder=Join-Path $env:LOCALAPPDATA ("CafeLauncher\graphics-backups\"+$active.AccountID)
        if(-not (Test-Path -LiteralPath $backupFolder)){[void](New-Item -ItemType Directory -Path $backupFolder -Force)}
        $backup=Join-Path $backupFolder ("cs2_video-"+$ModeName+'-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.txt')
        $temp=Join-Path (Split-Path -Parent $active.Path) ('cs2_video.cafe-'+[Guid]::NewGuid().ToString('N')+'.tmp')
        Copy-Item -LiteralPath $active.Path -Destination $backup -ErrorAction Stop
        try{
            [IO.File]::WriteAllText($temp,$edit.Text,$encoding)
            if(Get-Process -Name cs2 -ErrorAction SilentlyContinue){throw 'CS2 restarted during preparation; original video file kept.'}
            [IO.File]::Replace($temp,$active.Path,$null)
            if([IO.File]::ReadAllText($active.Path,$encoding) -cne $edit.Text){throw 'Video file verification failed.'}
        }catch{
            try{Copy-Item -LiteralPath $backup -Destination $active.Path -Force -ErrorAction Stop}
            catch{Write-Log ('CRITICAL: manually restore video from '+$backup) 'ERROR'}
            throw
        }finally{Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}
        Write-Log ("Applied "+$edit.Applied.Count+' graphics keys for '+$ModeName+' (Steam '+$active.AccountID+'). Backup: '+$backup)
        [void][System.Windows.Forms.MessageBox]::Show(
            ($ModeName+' graphics applied. Launch CS2 to use them.'+[Environment]::NewLine+
             'Backup: '+$backup),'CS2 Graphics Applied','OK','Information')
    }catch{
        Write-Log ("Apply Graphics failed for "+$ModeName+': '+$_.Exception.Message) 'ERROR'
        [void][System.Windows.Forms.MessageBox]::Show(
            ('Could not apply '+$ModeName+' graphics:'+[Environment]::NewLine+$_.Exception.Message+
             [Environment]::NewLine+'Original video settings were not intentionally changed. Check LIVE LOGS.'),
            'CS2 Graphics Not Applied','OK','Warning')
    }
}
