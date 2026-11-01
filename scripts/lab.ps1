#Requires -Version 5.1
<#
.SYNOPSIS
    LAB ONLY wrapper for legacy-web-hardening-lab: a fictional local hardening demonstration.
    Do not use with client data or production systems.

.DESCRIPTION
    The only Windows-facing entry point (REQ-OPS-001). It runs Docker Compose for this exact project
    (legacy-web-hardening-lab) and nothing else. Host prerequisites are Docker Desktop (Linux
    containers) and PowerShell; every HTTP, TLS, SQLite and backup check runs inside containers.

    Normal lifecycle: up, test, backup, verify-backup, migrate-dry-run, migrate-apply, rollback, down.
    "reset" is destructive and requires -ConfirmLabReset. It removes only this project's containers,
    networks and named volumes. It never prunes anything global.

.EXAMPLE
    .\scripts\lab.ps1 up
.EXAMPLE
    .\scripts\lab.ps1 reset -ConfirmLabReset
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('up', 'test', 'backup', 'verify-backup', 'migrate-status', 'migrate-dry-run', 'migrate-apply', 'rollback', 'down', 'reset')]
    [string]$Command,

    [switch]$ConfirmLabReset
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectName = 'legacy-web-hardening-lab'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ComposeFile = Join-Path $ProjectRoot 'docker-compose.yml'
$EvidenceDir = Join-Path $ProjectRoot 'artifacts\evidence'
# Built with [char]0x2014 so this script stays ASCII-only (Windows PowerShell 5.1 reads BOM-less files as ANSI).
$LabWarning = 'LAB ONLY ' + [char]0x2014 + ' fictional local hardening demonstration; do not use with client data or production systems.'
$AllowedBaseImages = @('nginx:1.30.6-alpine3.24', 'php:8.5.12-apache-trixie', 'alpine:3.24.3')
$ExpectedCommands = @('up', 'test', 'backup', 'verify-backup', 'migrate-status', 'migrate-dry-run', 'migrate-apply', 'rollback', 'down', 'reset')

$script:LogLines = New-Object 'System.Collections.Generic.List[string]'
$script:HostPassed = 0
$script:HostFailed = 0
$script:ExitCode = 0

function Write-Lab {
    param([AllowEmptyString()][string]$Text)
    Write-Host $Text
    $script:LogLines.Add($Text)
}

function Save-Evidence {
    param([string]$Name)
    if (-not (Test-Path -LiteralPath $EvidenceDir)) {
        New-Item -ItemType Directory -Path $EvidenceDir | Out-Null
    }
    [System.IO.File]::WriteAllLines((Join-Path $EvidenceDir ($Name + '.log')), $script:LogLines.ToArray())
}

# Runs a native command. stdout is captured (and echoed to the log); stderr goes straight to the
# console. Success is decided strictly by the exit code against an explicit allowlist.
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int[]]$AllowedExitCodes = @(0),
        [switch]$Silent
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # native stderr is informational; the exit code decides
    try {
        $output = @(& $Exe @Arguments)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    $lines = @($output | ForEach-Object { [string]$_ })
    if (-not $Silent) {
        foreach ($line in $lines) { Write-Lab $line }
    }
    if ($AllowedExitCodes -notcontains $code) {
        throw ("{0} {1} failed with exit code {2}" -f $Exe, ($Arguments -join ' '), $code)
    }
    return [pscustomobject]@{ ExitCode = $code; Lines = $lines }
}

function Invoke-Compose {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int[]]$AllowedExitCodes = @(0),
        [switch]$Silent
    )
    $base = @('compose', '--project-name', $ProjectName, '--project-directory', $ProjectRoot, '--file', $ComposeFile)
    return Invoke-Native -Exe 'docker' -Arguments ($base + $Arguments) -AllowedExitCodes $AllowedExitCodes -Silent:$Silent
}

function Get-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Add-Check {
    param([string]$Id, [bool]$Ok, [string]$Description)
    if ($Ok) {
        $script:HostPassed++
        Write-Lab "PASS $Id $Description"
    } else {
        $script:HostFailed++
        Write-Lab "FAIL $Id $Description"
    }
}

function Assert-DockerReady {
    $info = Invoke-Native -Exe 'docker' -Arguments @('info', '--format', '{{.OSType}}') -AllowedExitCodes @(0, 1) -Silent
    if ($info.ExitCode -ne 0) {
        throw 'Docker Desktop is not reachable. Start Docker Desktop (Linux containers) and retry.'
    }
    $osType = ($info.Lines -join '').Trim()
    if ($osType -ne 'linux') {
        throw "Docker reports OSType '$osType'. Switch Docker Desktop to Linux containers yourself and retry."
    }
}

function Test-EdgeRunning {
    $ps = Invoke-Compose -Arguments @('ps', '--status', 'running', '--quiet', 'edge') -Silent
    return (@($ps.Lines | Where-Object { $_.Trim() -ne '' }).Count -gt 0)
}

function Get-PortListeners {
    try {
        return @(Get-NetTCPConnection -LocalPort 8443 -State Listen -ErrorAction Stop)
    } catch {
        return @()
    }
}

function Assert-PortAvailable {
    $listeners = @(Get-PortListeners)
    if ($listeners.Count -gt 0 -and -not (Test-EdgeRunning)) {
        throw 'Host port 8443 is already in use by another process. Free it yourself (do not stop unrelated processes blindly), then retry.'
    }
}

function Assert-LabRunning {
    if (-not (Test-EdgeRunning)) {
        throw 'The lab is not running. Run .\scripts\lab.ps1 up first.'
    }
}

function Get-ComposeConfig {
    $config = Invoke-Compose -Arguments @('--profile', 'tools', 'config', '--format', 'json') -Silent
    return (($config.Lines -join "`n") | ConvertFrom-Json)
}

function Get-StateLine {
    param([string[]]$Lines)
    $state = @($Lines | Where-Object { $_ -match '^STATE ' })
    if ($state.Count -eq 0) { return '' }
    return $state[-1]
}

function Invoke-TesterHealth {
    param([string]$Id)
    $health = Invoke-Compose -Arguments @('run', '--rm', '-T', 'tester', 'health', $Id) -AllowedExitCodes @(0, 1)
    if ($health.ExitCode -ne 0) {
        throw "$Id failed: /health through the edge is not healthy."
    }
}

# ---------------------------------------------------------------------------------------------
# Host-side checks for "test" (Docker CLI and PowerShell only; no host curl/OpenSSL/PHP)
# ---------------------------------------------------------------------------------------------
function Test-ComposeConfiguration {
    $cfg = Get-ComposeConfig
    $services = Get-Prop $cfg 'services'
    $names = @($services.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)

    Add-Check 'V-CFG-01' (((Get-Prop $cfg 'name') -eq $ProjectName) -and (($names -join ',') -eq 'backup,edge,migrator,origin,tester')) `
        ("docker compose config is valid; project '{0}'; services: {1}" -f (Get-Prop $cfg 'name'), ($names -join ', '))

    $published = @()
    foreach ($name in $names) {
        foreach ($port in @(Get-Prop (Get-Prop $services $name) 'ports' | Where-Object { $null -ne $_ })) {
            $published += [pscustomobject]@{
                Service = $name
                HostIp = [string](Get-Prop $port 'host_ip')
                Published = [string](Get-Prop $port 'published')
                Target = [string](Get-Prop $port 'target')
            }
        }
    }
    $portOk = ($published.Count -eq 1) -and ($published[0].Service -eq 'edge') -and ($published[0].HostIp -eq '127.0.0.1') `
        -and ($published[0].Published -eq '8443') -and ($published[0].Target -eq '443')
    $portText = ($published | ForEach-Object { '{0} {1}:{2}->{3}' -f $_.Service, $_.HostIp, $_.Published, $_.Target }) -join '; '
    Add-Check 'V-CFG-02' $portOk "exactly one published port: $portText"

    $origin = Get-Prop $services 'origin'
    $originNets = @((Get-Prop $origin 'networks').PSObject.Properties | ForEach-Object { $_.Name })
    $originNet = Get-Prop (Get-Prop $cfg 'networks') 'origin_net'
    $ipamConfig = @(Get-Prop (Get-Prop $originNet 'ipam') 'config')
    $subnet = if ($ipamConfig.Count -gt 0) { [string](Get-Prop $ipamConfig[0] 'subnet') } else { '' }
    $ips = @{}
    foreach ($svc in @('edge', 'origin', 'tester')) {
        $ips[$svc] = [string](Get-Prop (Get-Prop (Get-Prop (Get-Prop $services $svc) 'networks') 'origin_net') 'ipv4_address')
    }
    $cfg3 = ($null -eq (Get-Prop $origin 'ports')) -and (($originNets -join ',') -eq 'origin_net') `
        -and ((Get-Prop $originNet 'internal') -eq $true) -and ($subnet -eq '172.28.0.0/24') `
        -and ($ips['edge'] -eq '172.28.0.2') -and ($ips['origin'] -eq '172.28.0.10') -and ($ips['tester'] -eq '172.28.0.20')
    Add-Check 'V-CFG-03' $cfg3 ("origin: no ports, networks=[{0}]; origin_net internal={1} subnet={2}; edge={3} origin={4} tester={5}" -f `
        ($originNets -join ','), (Get-Prop $originNet 'internal'), $subnet, $ips['edge'], $ips['origin'], $ips['tester'])

    $froms = @()
    foreach ($dockerfile in @(Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'docker') -Recurse -File -Filter 'Dockerfile')) {
        foreach ($line in [System.IO.File]::ReadAllLines($dockerfile.FullName)) {
            if ($line -match '^\s*FROM\s+(\S+)') { $froms += $Matches[1] }
        }
    }
    $imagesOk = $true
    foreach ($name in $names) {
        $image = [string](Get-Prop (Get-Prop $services $name) 'image')
        if ($image -notmatch '^legacy-web-hardening-lab/(edge|origin|tester|backup):local$') { $imagesOk = $false }
    }
    $fromOk = ($froms.Count -eq 4) -and (@($froms | Where-Object { $AllowedBaseImages -notcontains $_ }).Count -eq 0) `
        -and (@($froms | Where-Object { $_ -match 'latest' }).Count -eq 0)
    Add-Check 'V-CFG-04' ($fromOk -and $imagesOk) ("pinned base images: {0}; service images are explicit local tags; no 'latest'" -f (($froms | Sort-Object -Unique) -join ', '))

    $bindMounts = 0
    foreach ($name in $names) {
        foreach ($volume in @(Get-Prop (Get-Prop $services $name) 'volumes' | Where-Object { $null -ne $_ })) {
            if ((Get-Prop $volume 'type') -eq 'bind') { $bindMounts++ }
        }
    }
    $originState = @(Get-Prop $origin 'volumes' | Where-Object { $null -ne $_ -and (Get-Prop $_ 'target') -eq '/var/lib/lab/state' })
    $originRo = ($originState.Count -eq 1) -and ((Get-Prop $originState[0] 'read_only') -eq $true)
    $cfg5 = ((Get-Prop (Get-Prop $services 'backup') 'network_mode') -eq 'none') `
        -and ((Get-Prop (Get-Prop $services 'migrator') 'network_mode') -eq 'none') `
        -and ($bindMounts -eq 0) -and $originRo -and ($null -eq (Get-Prop (Get-Prop $services 'tester') 'ports'))
    Add-Check 'V-CFG-05' $cfg5 ("helpers scoped: backup/migrator network_mode=none; host bind mounts={0}; origin state mount read-only={1}; tester has no ports" -f $bindMounts, $originRo)
}

function Get-ComposePs {
    $ps = Invoke-Compose -Arguments @('ps', '--format', 'json') -Silent
    $text = ($ps.Lines -join "`n").Trim()
    if ($text -eq '') { return @() }
    if ($text.StartsWith('[')) { return @($text | ConvertFrom-Json) }
    return @($ps.Lines | Where-Object { $_.Trim() -ne '' } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Test-RuntimeExposure {
    $containers = @(Get-ComposePs)
    $edge = @($containers | Where-Object { (Get-Prop $_ 'Service') -eq 'edge' })
    $origin = @($containers | Where-Object { (Get-Prop $_ 'Service') -eq 'origin' })
    $originPublished = @()
    if ($origin.Count -eq 1) {
        $originPublished = @(@(Get-Prop $origin[0] 'Publishers') | Where-Object { $null -ne $_ -and [int](Get-Prop $_ 'PublishedPort') -ne 0 })
    }
    $portLine = ((Invoke-Compose -Arguments @('port', 'edge', '443') -Silent).Lines -join '').Trim()
    $runOk = ($edge.Count -eq 1) -and ((Get-Prop $edge[0] 'State') -eq 'running') -and ($origin.Count -eq 1) `
        -and ((Get-Prop $origin[0] 'State') -eq 'running') -and ($originPublished.Count -eq 0) -and ($portLine -eq '127.0.0.1:8443')
    $originHealth = if ($origin.Count -eq 1) { Get-Prop $origin[0] 'Health' } else { 'missing' }
    Add-Check 'V-RUN-01' $runOk ("docker compose ps: edge running, origin running ({0}); origin published host ports={1}; 'port edge 443' = {2}" -f `
        $originHealth, $originPublished.Count, $portLine)

    $listeners = @(Get-PortListeners)
    $addresses = @($listeners | ForEach-Object { [string]$_.LocalAddress } | Sort-Object -Unique)
    $nonLoopback = @($addresses | Where-Object { $_ -ne '127.0.0.1' -and $_ -ne '::1' })
    Add-Check 'V-RUN-02' (($addresses.Count -gt 0) -and ($nonLoopback.Count -eq 0)) ("host listeners on 8443: {0} (loopback only)" -f ($addresses -join ', '))
}

function Test-ProbeAbsentFromOrigin {
    param([string[]]$TesterLines)
    $probe = @($TesterLines | Where-Object { $_ -match '^PROBE bad=([0-9a-f]+) good=([0-9a-f]+)$' })
    if ($probe.Count -ne 1) {
        Add-Check 'V-EDGE-10' $false 'tester did not report the Host probe tokens'
        return
    }
    $null = $probe[0] -match '^PROBE bad=([0-9a-f]+) good=([0-9a-f]+)$'
    $bad = $Matches[1]
    $good = $Matches[2]
    $logs = (Invoke-Compose -Arguments @('logs', '--no-log-prefix', '--no-color', 'origin') -Silent).Lines -join "`n"
    $goodSeen = $logs.Contains($good)
    $badSeen = $logs.Contains($bad)
    Add-Check 'V-EDGE-10' ($goodSeen -and -not $badSeen) ("origin access log: allowlisted-Host probe present={0}; unexpected-Host probe present={1} (must be False)" -f $goodSeen, $badSeen)
}

function Test-WrapperDiscipline {
    $strict = $false
    try { $null = $script:labStrictModeProbeThatIsNeverAssigned } catch { $strict = $true }
    $eap = (Get-Variable -Name ErrorActionPreference -Scope Script).Value
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$null, [ref]$null)
    $commandParam = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Command' })
    $validateSet = @($commandParam | ForEach-Object { $_.Attributes } | Where-Object { $_.TypeName.Name -eq 'ValidateSet' })
    $values = @($validateSet | ForEach-Object { $_.PositionalArguments } | ForEach-Object { $_.Value })
    $testerDockerfile = [System.IO.File]::ReadAllText((Join-Path $ProjectRoot 'docker\tester\Dockerfile'))
    $containerized = ($testerDockerfile -match '(?m)^FROM alpine:3\.24\.3') -and ($testerDockerfile -match 'ENTRYPOINT \["/usr/local/bin/run-acceptance"\]')
    $ok = $strict -and ($eap -eq 'Stop') -and (($values -join ',') -eq ($ExpectedCommands -join ',')) -and $containerized
    Add-Check 'V-OPS-01' $ok ("StrictMode Latest active={0}; ErrorActionPreference={1}; commands=[{2}]; acceptance runner is containerized={3}" -f `
        $strict, $eap, ($values -join ','), $containerized)
}

function Get-ProjectVolumes {
    $volumes = Invoke-Native -Exe 'docker' -Arguments @('volume', 'ls', '--filter', "label=com.docker.compose.project=$ProjectName", '--format', '{{.Name}}') -Silent
    return @($volumes.Lines | Where-Object { $_.Trim() -ne '' } | Sort-Object)
}

function Test-ResetRequiresFlag {
    $before = @(Get-ProjectVolumes)
    $child = Invoke-Native -Exe 'powershell.exe' -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, 'reset') `
        -AllowedExitCodes @(0, 1, 2, 3) -Silent
    $after = @(Get-ProjectVolumes)
    $mentionsFlag = (($child.Lines -join "`n") -match '-ConfirmLabReset')
    $ok = ($child.ExitCode -eq 2) -and $mentionsFlag -and ($before.Count -gt 0) -and (($before -join ',') -eq ($after -join ','))
    Add-Check 'V-OPS-03' $ok ("'reset' without -ConfirmLabReset exited {0}, printed remediation={1}; project volumes unchanged ({2})" -f `
        $child.ExitCode, $mentionsFlag, ($after -join ', '))
}

function Test-ProjectHygiene {
    # The repository's own top-level .git (version-control metadata) is excluded from the scan.
    # Any other .git directory (nested repository), .runtime or node_modules is still flagged.
    $repoGitPrefix = (Join-Path $ProjectRoot '.git') + [System.IO.Path]::DirectorySeparatorChar
    $ignoreCase = [System.StringComparison]::OrdinalIgnoreCase
    $files = @(Get-ChildItem -LiteralPath $ProjectRoot -Recurse -Force -File | Where-Object {
            -not $_.FullName.StartsWith($repoGitPrefix, $ignoreCase)
        })
    $secretLike = @($files | Where-Object {
            $_.Name -match '\.(key|pem|crt|p12|pfx)$' -or $_.Name -match '\.sqlite' -or $_.Name -match '\.tar\.gz$' -or
            $_.Name -eq '.env' -or $_.Name -like '.env.*'
        })
    $badDirs = @(Get-ChildItem -LiteralPath $ProjectRoot -Recurse -Force -Directory | Where-Object {
            -not ($_.FullName + [System.IO.Path]::DirectorySeparatorChar).StartsWith($repoGitPrefix, $ignoreCase) -and
            (@('.runtime', '.git', 'node_modules') -contains $_.Name)
        })
    $artifactsRoot = Join-Path $ProjectRoot 'artifacts'
    $evidencePrefix = (Join-Path $artifactsRoot 'evidence') + [System.IO.Path]::DirectorySeparatorChar
    $artifactExtras = @($files | Where-Object { $_.FullName.StartsWith($artifactsRoot + [System.IO.Path]::DirectorySeparatorChar) } | Where-Object {
            -not ($_.FullName -eq (Join-Path $artifactsRoot 'README.md')) -and
            -not ($_.FullName.StartsWith($evidencePrefix) -and $_.Name -like '*.log')
        })
    $ok = ($secretLike.Count -eq 0) -and ($badDirs.Count -eq 0) -and ($artifactExtras.Count -eq 0)
    Add-Check 'V-HYG-01' $ok ("project tree: secret/data-like files={0}; runtime/VCS dirs={1}; unexpected artifacts={2}" -f `
        $secretLike.Count, $badDirs.Count, $artifactExtras.Count)
}

function Test-Documentation {
    $readme = [System.IO.File]::ReadAllText((Join-Path $ProjectRoot 'README.md'), [System.Text.Encoding]::UTF8)
    Add-Check 'V-DOC-01' ($readme.Contains($LabWarning)) 'README.md contains the exact lab-only warning'

    $headings = @('Architecture', 'Trust boundaries', 'Prerequisites', 'Quick start', 'What this lab demonstrates',
        'What this lab does not demonstrate', 'Tests', 'Troubleshooting', 'Safe shutdown', 'Destructive reset',
        'Rollback', 'Before adapting elsewhere')
    $missing = @($headings | Where-Object { $readme -notmatch ('(?m)^##\s+' + [regex]::Escape($_) + '\s*$') })
    $label = $readme.Contains('Cloudflare-style edge/origin separation and header sanitation only')
    $claims = '(?i)(production[- ]ready|compliant|certified|fully secure|cloudflare[- ]protected)'
    $negation = "(?i)\b(not|no|never|without|nor|isn't|doesn't|does not|is not)\b"
    $unnegated = @($readme -split "`r?`n" | Where-Object { $_ -match $claims -and $_ -notmatch $negation })
    Add-Check 'V-DOC-02' (($missing.Count -eq 0) -and $label -and ($unnegated.Count -eq 0)) ("README sections missing={0}; Cloudflare-style label present={1}; un-negated claims={2}" -f `
        $missing.Count, $label, $unnegated.Count)
}

# ---------------------------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------------------------
function Invoke-Up {
    Assert-DockerReady
    Assert-PortAvailable
    Invoke-Compose -Arguments @('--progress', 'quiet', '--profile', 'tools', 'build') | Out-Null
    $init = Invoke-Compose -Arguments @('run', '--rm', '-T', 'migrator', 'init')
    Invoke-Compose -Arguments @('up', '-d', '--wait', '--wait-timeout', '180', 'edge', 'origin') | Out-Null
    $cfg = Get-ComposeConfig
    $originState = @(Get-Prop (Get-Prop (Get-Prop $cfg 'services') 'origin') 'volumes' | Where-Object { $null -ne $_ -and (Get-Prop $_ 'target') -eq '/var/lib/lab/state' })
    $originRo = ($originState.Count -eq 1) -and ((Get-Prop $originState[0] 'read_only') -eq $true)
    $fixture = @($init.Lines | Where-Object { $_ -match '^FIXTURE (seeded|verified-existing): marker=LAB_BACKUP_FIXTURE=v1 items=3 schema_version=[12] integrity=ok$' })
    if (($fixture.Count -ne 1) -or -not $originRo) {
        Write-Lab "FAIL V-DATA-01 fixture line present=$($fixture.Count -eq 1); origin state mount read-only=$originRo"
        throw 'V-DATA-01 failed.'
    }
    Write-Lab ("PASS V-DATA-01 synthetic fixture ready ({0}); origin mounts legacy_state read-only" -f ($fixture[0] -replace '^FIXTURE ', ''))
    Invoke-Compose -Arguments @('run', '--rm', '-T', 'tester', 'wait') | Out-Null
    Write-Lab 'UP OK: open https://localhost:8443/ (self-signed certificate: a browser warning is expected)'
}

function Invoke-Test {
    Assert-LabRunning
    Test-ComposeConfiguration
    $tester = Invoke-Compose -Arguments @('run', '--rm', '-T', 'tester', 'all') -AllowedExitCodes @(0, 1)
    Test-ProbeAbsentFromOrigin -TesterLines $tester.Lines
    Test-RuntimeExposure
    Test-WrapperDiscipline
    Test-ResetRequiresFlag
    Test-ProjectHygiene
    Test-Documentation

    Write-Lab ("SUMMARY host passed={0} failed={1}" -f $script:HostPassed, $script:HostFailed)
    $summary = @($tester.Lines | Where-Object { $_ -match '^SUMMARY tester passed=(\d+) failed=(\d+)$' })
    $testerPassed = 0
    $testerFailed = 1
    if ($summary.Count -eq 1) {
        $null = $summary[0] -match '^SUMMARY tester passed=(\d+) failed=(\d+)$'
        $testerPassed = [int]$Matches[1]
        $testerFailed = [int]$Matches[2]
    }
    if (($tester.ExitCode -ne 0) -or ($testerFailed -ne 0) -or ($script:HostFailed -ne 0)) {
        throw ("Acceptance checks failed: tester failed={0}, host failed={1}. See the FAIL lines above." -f $testerFailed, $script:HostFailed)
    }
    Write-Lab ("TEST OK: {0} acceptance checks passed (tester {1}, host {2})" -f ($testerPassed + $script:HostPassed), $testerPassed, $script:HostPassed)
}

function Invoke-Backup {
    Invoke-Compose -Arguments @('run', '--rm', '-T', 'backup', 'create') | Out-Null
    $gate = Invoke-Compose -Arguments @('run', '--rm', '-T', 'migrator', 'gate-check') -AllowedExitCodes @(0, 3)
    if ($gate.ExitCode -ne 3) {
        Write-Lab 'FAIL V-BAK-02 gate did not refuse apply before the new backup was verified'
        throw 'V-BAK-02 failed.'
    }
    Write-Lab 'PASS V-BAK-02 verified-backup gate refuses apply until this new backup is verified (exit 3, remediation printed)'
    Write-Lab 'NEXT: .\scripts\lab.ps1 verify-backup'
}

function Invoke-VerifyBackup {
    Invoke-Compose -Arguments @('run', '--rm', '-T', 'backup', 'verify') | Out-Null
    $gate = Invoke-Compose -Arguments @('run', '--rm', '-T', 'migrator', 'gate-check') -AllowedExitCodes @(0, 3)
    if ($gate.ExitCode -ne 0) {
        Write-Lab 'FAIL V-BAK-05 gate did not pass after verification'
        throw 'V-BAK-05 failed.'
    }
    Write-Lab 'PASS V-BAK-05 verification evidence written; verified-backup gate now passes'
}

function Invoke-MigrateApply {
    $first = Invoke-Compose -Arguments @('run', '--rm', '-T', 'migrator', 'apply') -AllowedExitCodes @(0, 3)
    if ($first.ExitCode -eq 3) {
        throw 'The verified-backup gate refused apply. Follow the REMEDIATION line above (backup, then verify-backup).'
    }
    $second = Invoke-Compose -Arguments @('run', '--rm', '-T', 'migrator', 'apply')
    $noop = (@($second.Lines | Where-Object { $_ -match '^ALREADY APPLIED' }).Count -eq 1)
    $same = ((Get-StateLine $first.Lines) -ne '') -and ((Get-StateLine $first.Lines) -eq (Get-StateLine $second.Lines))
    if (-not ($noop -and $same)) {
        Write-Lab "FAIL V-MIG-04 second apply no-op=$noop state unchanged=$same"
        throw 'V-MIG-04 failed.'
    }
    Write-Lab 'PASS V-MIG-04 re-running apply is a no-op (ALREADY APPLIED; schema version and live sha256 unchanged)'
    Invoke-TesterHealth -Id 'V-MIG-05'
}

function Invoke-Rollback {
    $first = Invoke-Compose -Arguments @('run', '--rm', '-T', 'migrator', 'rollback')
    $rolledBack = (@($first.Lines | Where-Object { $_ -match '^ROLLED BACK' }).Count -eq 1)
    Invoke-TesterHealth -Id 'V-RB-02'
    $second = Invoke-Compose -Arguments @('run', '--rm', '-T', 'migrator', 'rollback')
    $noop = (@($second.Lines | Where-Object { $_ -match '^NOTHING TO ROLL BACK' }).Count -eq 1)
    $same = ((Get-StateLine $first.Lines) -ne '') -and ((Get-StateLine $first.Lines) -eq (Get-StateLine $second.Lines))
    if (-not ($noop -and $same)) {
        Write-Lab "FAIL V-RB-03 second rollback no-op=$noop state unchanged=$same"
        throw 'V-RB-03 failed.'
    }
    Write-Lab 'PASS V-RB-03 re-running rollback is a no-op (NOTHING TO ROLL BACK; live sha256 unchanged)'
    if ($rolledBack) {
        $gate = Invoke-Compose -Arguments @('run', '--rm', '-T', 'migrator', 'gate-check') -AllowedExitCodes @(0, 3)
        if ($gate.ExitCode -ne 3) {
            Write-Lab 'FAIL V-RB-04 gate still passes although the live fixture changed after the verified backup'
            throw 'V-RB-04 failed.'
        }
        Write-Lab 'PASS V-RB-04 gate refuses a new apply until a fresh backup is verified (live fixture changed by rollback)'
    } else {
        Write-Lab 'SKIP V-RB-04 no migration was rolled back in this run (nothing changed)'
    }
}

function Invoke-Reset {
    if (-not $ConfirmLabReset) {
        Write-Lab 'REFUSED: reset is destructive. It deletes this lab''s fixture and backup volumes.'
        Write-Lab 'REMEDIATION: re-run as: .\scripts\lab.ps1 reset -ConfirmLabReset'
        $script:ExitCode = 2
        return
    }
    $before = @(Get-ProjectVolumes)
    Invoke-Compose -Arguments @('--profile', 'tools', 'down', '--volumes', '--remove-orphans') | Out-Null
    $after = @(Get-ProjectVolumes)
    Write-Lab ("RESET OK: removed this project's containers, networks and named volumes ({0}); remaining project volumes: {1}" -f `
        ($before -join ', '), $after.Count)
}

try {
    Write-Lab ("== lab.ps1 {0} | project {1} | LAB ONLY - fictional local hardening demonstration ==" -f $Command, $ProjectName)
    switch ($Command) {
        'up' { Invoke-Up }
        'test' { Invoke-Test }
        'backup' { Invoke-Backup }
        'verify-backup' { Invoke-VerifyBackup }
        'migrate-status' { Invoke-Compose -Arguments @('run', '--rm', '-T', 'migrator', 'status') | Out-Null }
        'migrate-dry-run' { Invoke-Compose -Arguments @('run', '--rm', '-T', 'migrator', 'dry-run') | Out-Null }
        'migrate-apply' { Invoke-MigrateApply }
        'rollback' { Invoke-Rollback }
        'down' {
            Invoke-Compose -Arguments @('--profile', 'tools', 'down', '--remove-orphans') | Out-Null
            Write-Lab 'DOWN OK: containers and networks removed; named volumes kept (use reset -ConfirmLabReset to delete them)'
        }
        'reset' { Invoke-Reset }
    }
} catch {
    Write-Lab ('ERROR: ' + $_.Exception.Message)
    $script:ExitCode = 1
}

Save-Evidence -Name $Command
exit $script:ExitCode
