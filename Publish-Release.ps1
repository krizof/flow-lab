param(
 [Parameter(Mandatory=$true)][string]$Exe,
 [Parameter(Mandatory=$true)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
 [Parameter(Mandatory=$true)][string]$NotesFile,
 [ValidateSet('normal','important')][string]$Importance='normal',
 [switch]$PrepareOnly
)
$ErrorActionPreference='Stop'
$repo='krizof/flow-lab'
$exePath=(Resolve-Path -LiteralPath $Exe).Path
$notesPath=(Resolve-Path -LiteralPath $NotesFile).Path
if([Reflection.AssemblyName]::GetAssemblyName($exePath).Version.ToString(3) -ne $Version){throw 'EXE version does not match release version'}
$stage=Join-Path $PSScriptRoot ('artifacts/v'+$Version)
$null=New-Item -ItemType Directory -Path $stage -Force
$binary=Join-Path $stage 'Flow-Lab.exe'
Copy-Item -LiteralPath $exePath -Destination $binary -Force
foreach($name in @('START-HERE.txt','THIRD-PARTY.txt')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $stage $name) -Force}
$notes=[IO.File]::ReadAllText($notesPath)
if($Importance -eq 'important'){$notes="<!-- flow-lab:important -->`n`n"+$notes}
$publishNotes=Join-Path $stage 'release-notes.txt'
[IO.File]::WriteAllText($publishNotes,$notes,(New-Object Text.UTF8Encoding($false)))
$zip=Join-Path $stage ('Flow-Lab-'+$Version+'-win-x64.zip')
Compress-Archive -LiteralPath @($binary,(Join-Path $stage 'START-HERE.txt'),(Join-Path $stage 'THIRD-PARTY.txt'),$publishNotes) -DestinationPath $zip -Force
$sha=Join-Path $stage 'SHA256SUMS.txt'
$lines=foreach($file in @($binary,$zip)){(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()+'  '+[IO.Path]::GetFileName($file)}
[IO.File]::WriteAllText($sha,($lines -join "`n")+"`n",(New-Object Text.UTF8Encoding($false)))
if($PrepareOnly){Write-Output ('Prepared: '+$stage);return}
$command=Get-Command gh -ErrorAction SilentlyContinue
$gh=if($command){$command.Source}else{Join-Path $env:ProgramFiles 'GitHub CLI/gh.exe'}
if(!(Test-Path -LiteralPath $gh)){throw 'GitHub CLI (gh) is required for publishing'}
$tag='v'+$Version
$existing=& $gh release view $tag --repo $repo --json isDraft 2>$null
if($LASTEXITCODE -eq 0){if(!($existing | ConvertFrom-Json).isDraft){throw 'Published release already exists. Use a new version; existing releases are not overwritten.'}}
else{
 & $gh release create $tag --repo $repo --draft --target main --title ('Flow Lab '+$Version) --notes-file $publishNotes
 if($LASTEXITCODE -ne 0){throw 'Could not create draft release'}
}
& $gh release edit $tag --repo $repo --title ('Flow Lab '+$Version) --notes-file $publishNotes
if($LASTEXITCODE -ne 0){throw 'Could not update draft release notes'}
& $gh release upload $tag $binary $zip $sha --repo $repo --clobber
if($LASTEXITCODE -ne 0){throw 'Upload failed; draft retained'}
$draftJson=& $gh release view $tag --repo $repo --json databaseId,isDraft
if($LASTEXITCODE -ne 0){throw 'Could not locate uploaded draft'}
$draft=$draftJson | ConvertFrom-Json
if(!$draft.isDraft){throw 'Release is no longer a draft; publish aborted'}
$releaseJson=& $gh api ('repos/'+$repo+'/releases/'+$draft.databaseId)
if($LASTEXITCODE -ne 0){throw 'Could not verify uploaded release'}
$release=$releaseJson | ConvertFrom-Json
$asset=@($release.assets | Where-Object name -eq 'Flow-Lab.exe')
$expected='sha256:'+(Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash.ToLowerInvariant()
if($asset.Count -ne 1 -or $asset[0].digest -ne $expected -or $asset[0].size -ne (Get-Item -LiteralPath $binary).Length){throw 'GitHub digest/size mismatch; release left as draft'}
& $gh release edit $tag --repo $repo --draft=false --latest
if($LASTEXITCODE -ne 0){throw 'Publish failed; inspect the draft on GitHub'}
Write-Output ('Published: https://github.com/'+$repo+'/releases/tag/'+$tag)
