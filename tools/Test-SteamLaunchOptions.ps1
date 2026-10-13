# In-memory Steam VDF regression test. Never reads/writes a real Steam account.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$lines=[IO.File]::ReadAllLines((Join-Path (Split-Path -Parent $PSScriptRoot) 'cafe.bat'))
$marker=[Array]::IndexOf($lines,'# POWERSHELL_GUI')
if($marker -lt 0){throw 'Missing embedded PowerShell marker.'}
$code=[string]::Join([Environment]::NewLine,[string[]]$lines[($marker+1)..($lines.Length-1)])
$t=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseInput($code,[ref]$t,[ref]$errors)
if(@($errors).Count){throw ('Launcher parse failure: '+$errors[0].Message)}
$matches=@($ast.FindAll({param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Update-CS2LaunchOptionsVdfText'},$true))
if($matches.Count -ne 1){throw 'Expected exactly one Steam VDF updater function.'}
Invoke-Expression $matches[0].Extent.Text

$vdf=@'
"UserLocalConfigStore"
{
  "Software"
  {
    "Valve"
    {
      "Steam"
      {
        "apps"
        {
          "570"
          {
            "LaunchOptions" "-novid"
          }
          "730"
          {
            "LastPlayed" "123"
            "LaunchOptions" "-fullscreen +exec old.cfg -novid"
          }
        }
      }
    }
  }
}
'@
$updated=Update-CS2LaunchOptionsVdfText -Content $vdf -CfgName 'arli.cfg'
if($updated -notmatch '\+exec arli\.cfg' -or $updated -match '\+exec old\.cfg'){throw 'Old CS2 exec was not replaced.'}
if($updated -notmatch 'LaunchOptions"\s*"-fullscreen\s+-novid\s+\+exec arli\.cfg"'){throw 'Other Steam flags were lost.'}
if($updated -notmatch '"570"\s*\{\s*"LaunchOptions"\s*"-novid"'){throw 'Unrelated Steam app was changed.'}
if((Update-CS2LaunchOptionsVdfText -Content $updated -CfgName 'arli.cfg') -cne $updated){throw 'Same-profile update must be idempotent.'}
$switched=Update-CS2LaunchOptionsVdfText -Content $updated -CfgName 'oli.cfg'
if($switched -notmatch '\+exec oli\.cfg' -or $switched -match '\+exec arli\.cfg'){throw 'Switching between profiles failed.'}
$withoutApp=$vdf -replace '(?s)\s+"730"\s*\{.*?"LaunchOptions"\s*"-fullscreen \+exec old\.cfg -novid"\s*\}',''
$inserted=Update-CS2LaunchOptionsVdfText -Content $withoutApp -CfgName 'fab.cfg'
if($inserted -notmatch '"730"\s*\{\s*"LaunchOptions"\s*"\+exec fab\.cfg"'){throw 'New CS2 game section was not added.'}
$failed=$false
try{[void](Update-CS2LaunchOptionsVdfText -Content $vdf -CfgName 'bad.cfg && cmd.exe')}catch{$failed=$true}
if(-not $failed){throw 'Unsafe CFG filenames should be rejected.'}
Write-Host 'PASS: Steam CS2 VDF preserves other games and flags, replaces +exec, switches profiles, and is idempotent.'
