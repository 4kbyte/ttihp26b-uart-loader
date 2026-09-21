param(
    [string]$SourceRef = "HEAD",
    [int]$Jobs = 8,
    [string]$Tiles = "2x2",
    [int]$TargetDensity = 70
)

$ErrorActionPreference = "Stop"
if ($TargetDensity -lt 1 -or $TargetDensity -gt 100) {
    throw "TargetDensity must be between 1 and 100"
}
$Repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Build = Join-Path $Repo "build\physical"
$Tools = Join-Path $Build "tools"
$Work = Join-Path $Build "work"
$Support = Join-Path $Tools "tt-support-tools"
$Action = Join-Path $Tools "tt-gds-action"
$SupportCommit = "01d5d2814fa9dd61e9d211e0b235a4a592a9316a"
$ActionCommit = "7ef3d03f2ca2e4550306636a7b762fe128b09995"
$Image = "ghcr.io/librelane/librelane@sha256:ecabd075d0ddf6a2bd1cd4a32109c7dbb861ec007f7e4e423a9a081f8d23b8e2"
$PdkVolume = "ttihp26b-uart-loader-pdk"
$Top = "tt_um_romd_uart_loader"
$Sources = @("uart.v", "uart_loader.v", "spi_sram.v", "project.v")

function Ensure-Clone([string]$Path, [string]$Url, [string]$Commit) {
    if (-not (Test-Path (Join-Path $Path ".git"))) {
        New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null
        git clone --quiet $Url $Path
    }
    if ((git -C $Path rev-parse HEAD) -ne $Commit) {
        git -C $Path fetch --quiet origin $Commit
        git -C $Path checkout --quiet --detach $Commit
    }
    if ((git -C $Path rev-parse HEAD) -ne $Commit) {
        throw "Dependency pin mismatch: $Path"
    }
}

Ensure-Clone $Support "https://github.com/TinyTapeout/tt-support-tools.git" $SupportCommit
Ensure-Clone $Action "https://github.com/TinyTapeout/tt-gds-action.git" $ActionCommit

$TileFile = Join-Path $Support "tech\ihp-sg13g2\tile_sizes.yaml"
$TileLine = Select-String -Path $TileFile -Pattern "^${Tiles}: `"([^`"]+)`"$"
if (-not $TileLine) { throw "Pinned support tools do not define $Tiles" }
$DieArea = $TileLine.Matches[0].Groups[1].Value
$Def = Join-Path $Support "tech\ihp-sg13g2\def\tt_block_${Tiles}_pgvdd.def"
if (-not (Test-Path $Def)) { throw "Pinned support tools lack the $Tiles DEF" }

Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force (Join-Path $Work "src"), (Join-Path $Work "tt") | Out-Null
foreach ($Source in $Sources) {
    $Content = git -C $Repo show "${SourceRef}:src/$Source"
    if ($LASTEXITCODE -ne 0) { throw "Cannot read src/$Source from $SourceRef" }
    [IO.File]::WriteAllLines((Join-Path $Work "src\$Source"), [string[]]$Content,
        [Text.UTF8Encoding]::new($false))
}
Copy-Item (Join-Path $Support "*") (Join-Path $Work "tt") -Recurse -Force

$ConfigContent = git -C $Repo show "${SourceRef}:src/config.json"
if ($LASTEXITCODE -ne 0) { throw "Cannot read src/config.json from $SourceRef" }
$Config = ($ConfigContent -join "`n") | ConvertFrom-Json -AsHashtable
$Config.DESIGN_NAME = $Top
$Config.VERILOG_FILES = @($Sources | ForEach-Object { "dir::$_" })
$Config.DIE_AREA = $DieArea
$Config.FP_DEF_TEMPLATE = "dir::../tt/tech/ihp-sg13g2/def/tt_block_${Tiles}_pgvdd.def"
$Config.PL_TARGET_DENSITY_PCT = $TargetDensity
$Config.VDD_PIN = "VPWR"
$Config.GND_PIN = "VGND"
$Config.RT_MAX_LAYER = "TopMetal1"
$Config | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $Work "src\config.json")

$SourceCommit = git -C $Repo rev-parse $SourceRef
$Manifest = [ordered]@{
    tiles = $Tiles; die_area_um = $DieArea; top = $Top
    target_density_pct = $TargetDensity
    source_commit = $SourceCommit; tt_gds_action_commit = $ActionCommit
    tt_support_tools_commit = $SupportCommit; librelane_image = $Image
    jobs = $Jobs
}
$Manifest | ConvertTo-Json | Set-Content (Join-Path $Work "run-manifest.json")

docker volume create $PdkVolume | Out-Null
docker run --rm --pull=never -v "${Work}:/work" -v "${PdkVolume}:/pdk" -w /work `
    $Image python -m librelane --pdk-root /pdk --pdk ihp-sg13g2 `
    --hide-progress-bar -j $Jobs --run-tag pnr --overwrite src/config.json
exit $LASTEXITCODE
