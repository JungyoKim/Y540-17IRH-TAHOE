# fetch-efi-kexts.ps1 [-Efi <path to EFI>] -- Windows version of fetch-efi-kexts.sh: download the three OCLP Modern Wireless
# kexts (Apple binaries, not shipped in this repository), check their SHA-256 and unpack them into EFI\OC\Kexts.
param([string]$Efi = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'EFI'))
$ErrorActionPreference = 'Stop'
$k = Join-Path $Efi 'OC\Kexts'
if (-not (Test-Path $k)) { throw "no $k" }
$u = 'https://raw.githubusercontent.com/dortania/OpenCore-Legacy-Patcher/3.0.0-rc.3/payloads/Kexts/Wifi'
$t = Join-Path $env:TEMP ('y540-oclp-' + [guid]::NewGuid())
New-Item -ItemType Directory $t | Out-Null
$list = @(
  @('IOSkywalkFamily-v1.2.0.zip', '1e12b7ef42f55b39ea54ada97b46331220668b2c48a28656e9875c5145fe2479', 'IOSkywalkFamily.kext'),
  @('IO80211FamilyLegacy-v1.0.0.zip', 'e681dcc76a2cd2cea4b0ad5f27a3c816055fde3cdccd890dd10a3e2c84e96d93', 'IO80211FamilyLegacy.kext'),
  @('AirPortBrcmNIC-Tahoe-v1.0.0.zip', '04edd7127ce096f5de9f8112af6d06744f27e5bc659e3d6516408755cb9af032', 'AirPortBrcmNIC-Tahoe.kext'))
foreach ($i in $list) {
  $zip = Join-Path $t $i[0]
  Invoke-WebRequest -UseBasicParsing -Uri "$u/$($i[0])" -OutFile $zip
  if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLower() -ne $i[1]) { throw "$($i[0]): checksum mismatch" }
  $x = Join-Path $t ($i[2] + '.x')
  Expand-Archive -Path $zip -DestinationPath $x -Force
  $src = Join-Path $x $i[2]
  $dst = Join-Path $k $i[2]
  if (Test-Path $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
  Copy-Item -LiteralPath $src -Destination $dst -Recurse
  "ok  $($i[2])"
}
Remove-Item -LiteralPath $t -Recurse -Force
