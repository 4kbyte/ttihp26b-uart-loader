param()

$ErrorActionPreference = "Stop"
$Repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Build = Join-Path $Repo "build\physical"
$Support = Join-Path $Build "tools\tt-support-tools"
$Final = Join-Path $Build "work\src\runs\pnr\final"
$RunManifestPath = Join-Path $Build "work\run-manifest.json"
$Output = Join-Path $Build "precheck"
$Submission = Join-Path $Output "submission"
$Wheelhouse = Join-Path $Build "wheelhouse"
$Top = "tt_um_romd_uart_loader"
$SupportCommit = "01d5d2814fa9dd61e9d211e0b235a4a592a9316a"
$PdkCommit = "22f43352dd8219f9007eb659e422e0d5fe28c5fb"
$Image = "ghcr.io/librelane/librelane@sha256:ecabd075d0ddf6a2bd1cd4a32109c7dbb861ec007f7e4e423a9a081f8d23b8e2"
$PdkVolume = "ttihp26b-uart-loader-precheck-pdk"
$PythonVolume = "ttihp26b-uart-loader-precheck-python"

if ((git -C $Support rev-parse HEAD) -ne $SupportCommit) {
    throw "Pinned tt-support-tools checkout is unavailable"
}
if (-not (Test-Path $RunManifestPath)) {
    throw "Missing hardening manifest: $RunManifestPath"
}
$RunManifest = Get-Content $RunManifestPath -Raw | ConvertFrom-Json
$SourceCommit = $RunManifest.source_commit
if (-not $SourceCommit) { throw "Hardening manifest omits source_commit" }
$Tiles = $RunManifest.tiles
if (-not $Tiles) { throw "Hardening manifest omits tiles" }
$Gds = Join-Path $Final "gds\$Top.gds"
$Lef = Join-Path $Final "lef\$Top.lef"
$Netlist = Join-Path $Final "nl\$Top.nl.v"
foreach ($Artifact in @($Gds, $Lef, $Netlist)) {
    if (-not (Test-Path $Artifact)) { throw "Missing artifact: $Artifact" }
}
Remove-Item $Output -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $Submission | Out-Null
Copy-Item $Gds (Join-Path $Submission "$Top.gds")
Copy-Item $Lef (Join-Path $Submission "$Top.lef")
Copy-Item $Netlist (Join-Path $Submission "$Top.v")
$Info = git -C $Repo show "${SourceCommit}:info.yaml"
if ($LASTEXITCODE -ne 0) { throw "Cannot read info.yaml from $SourceCommit" }
$TileLines = @($Info | Select-String -Pattern "^\s*tiles:\s*")
if ($TileLines.Count -ne 1) { throw "Expected one project tiles entry in info.yaml" }
$Info = $Info -replace "^(\s*tiles:\s*).+$", ('${1}"' + $Tiles + '"')
[IO.File]::WriteAllLines((Join-Path $Submission "info.yaml"), [string[]]$Info,
    [Text.UTF8Encoding]::new($false))

docker volume create $PdkVolume | Out-Null
docker volume create $PythonVolume | Out-Null
docker run --rm --pull=never -v "${PdkVolume}:/pdk" $Image `
    ciel enable --pdk-root /pdk --pdk-family ihp-sg13g2 $PdkCommit
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

New-Item -ItemType Directory -Force $Wheelhouse | Out-Null
if (-not (Test-Path (Join-Path $Wheelhouse "klayout-0.30.8-*.whl"))) {
    python -m pip download -r (Join-Path $Support "precheck\requirements.txt") `
        --dest $Wheelhouse --only-binary=:all: --platform manylinux_2_28_x86_64 `
        --platform manylinux2014_x86_64 --python-version 311 --implementation cp `
        --abi cp311 --quiet
}
$Reports = Join-Path $Support "precheck\reports"
Remove-Item $Reports -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $Reports | Out-Null
$Bash = @'
nix-shell -p python311 python311Packages.pip --run \
  "python -m venv /venv && /venv/bin/pip install --no-index --find-links /wheels -q -r requirements.txt"
libstdcpp="$(dirname "$(find /nix/store -name libstdc++.so.6 -print -quit)")"
export LD_LIBRARY_PATH="${libstdcpp}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export PATH="/venv/bin:${PATH}"
nix-shell --run \
  "/venv/bin/python precheck.py --gds /submission/__TOP__.gds --tech ihp-sg13g2"
'@.Replace("__TOP__", $Top).Replace("`r", "")
docker run --rm --pull=never -v "${Support}:/tt" -v "${Submission}:/submission:ro" `
    -v "${Wheelhouse}:/wheels:ro" -v "${PdkVolume}:/pdk" `
    -v "${PythonVolume}:/venv" -w /tt/precheck -e PDK_ROOT=/pdk `
    -e PDK=ihp-sg13g2 $Image bash -lc $Bash
$ExitCode = $LASTEXITCODE
if (Test-Path $Reports) { Copy-Item $Reports (Join-Path $Output "reports") -Recurse }
[ordered]@{
    top = $Top; tiles = $Tiles; source_commit = $SourceCommit
    gds_sha256 = (Get-FileHash $Gds -Algorithm SHA256).Hash.ToLowerInvariant()
    netlist_sha256 = (Get-FileHash $Netlist -Algorithm SHA256).Hash.ToLowerInvariant()
    tt_support_tools_commit = $SupportCommit; precheck_pdk_commit = $PdkCommit
    librelane_image = $Image; exit_code = $ExitCode
} | ConvertTo-Json | Set-Content (Join-Path $Output "manifest.json")
exit $ExitCode
