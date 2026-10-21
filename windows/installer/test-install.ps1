# Installs the built setup silently for this user, checks the per-user layout, uninstalls it and
# checks that the recordings survive. CI runs it; on a PC: pwsh installer\test-install.ps1 <setup.exe>
# It removes an existing per-user Shepetal install and its Run value.
param([Parameter(Mandatory)] [string] $Setup)
$ErrorActionPreference = 'Stop'

$app = Join-Path $env:LOCALAPPDATA 'Programs\Shepetal'
$data = Join-Path $env:LOCALAPPDATA 'Shepetal'
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$settings = 'HKCU:\Software\Shepetal'
$lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Shepetal.lnk'
function Check($ok, $what) { if (-not $ok) { throw "FAIL: $what" }; "ok: $what" }
function RunValue { (Get-ItemProperty $run -ErrorAction SilentlyContinue).Shepetal }

$p = Start-Process $Setup '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -PassThru
Check ($p.ExitCode -eq 0) "setup exit code $($p.ExitCode)"
Check (Test-Path "$app\shepetal.exe") "shepetal.exe in $app (per user, no admin)"
Check (Test-Path $lnk) "Start menu entry $lnk"
Check ((RunValue) -eq "`"$app\shepetal.exe`"") "start at login: HKCU Run = $(RunValue)"

# A recording and a model where the app keeps them. The uninstaller must leave the recording
# (goal rule 4) and delete the model.
New-Item -ItemType Directory -Force "$data\audio", "$data\models" | Out-Null
Set-Content "$data\audio\installer-test.wav" 'RIFF'
Set-Content "$data\models\installer-test.bin" 'ggml'
# The tray's Recordings choice, as the app writes it. The uninstaller removes the settings.
New-Item -Force $settings | Out-Null
Set-ItemProperty $settings Retention 'delete_after_24h'

$p = Start-Process "$app\unins000.exe" '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -PassThru
Check ($p.ExitCode -eq 0) "uninstaller exit code $($p.ExitCode)"
# The uninstaller re-runs itself from %TEMP% and returns at once, so wait for it to finish.
for ($i = 0; $i -lt 60 -and ((Test-Path $app) -or (RunValue) -or (Test-Path $settings)); $i++) { Start-Sleep 1 }
Check (-not (Test-Path "$app\shepetal.exe")) 'uninstall removed shepetal.exe'
Check (-not (Test-Path $lnk)) 'uninstall removed the Start menu entry'
Check ($null -eq (RunValue)) 'uninstall removed the Run value'
Check (-not (Test-Path "$data\models")) 'uninstall removed the speech models'
Check (-not (Test-Path $settings)) 'uninstall removed the settings'
Check ((Get-Content "$data\audio\installer-test.wav") -eq 'RIFF') "recordings kept in $data"
Remove-Item "$data\audio\installer-test.wav"
