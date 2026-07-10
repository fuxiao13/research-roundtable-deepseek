[CmdletBinding()]
param(
    [string]$ReviewPacketPath,

    [string]$CompressedReviewPacketPath,

    [string]$CompressionStrategy = '',

    [string]$UserIdeasPath,

    [string]$OutputDirectory = (Join-Path (Get-Location).Path '.roundtable\reviews'),

    [string]$DataRoot = (Join-Path $HOME '.research-roundtable-deepseek'),

    [ValidateSet('DocumentNormal', 'DocumentDeep', 'ExperimentNormal', 'ExperimentDeep')]
    [string]$Mode = 'DocumentNormal',

    [ValidateSet('Initial', 'CodexDraftCheck')]
    [string]$Stage = 'Initial',

    [string]$CodexDraftPath,

    [string]$ReadOnlyProjectPath,

    [string]$DeepSeekPacketPath,

    [string]$IssueLedgerPath,

    [string]$IssueLifecycleUpdatesPath,

    [string]$AuthorizationRecordPath,

    [ValidateRange(1, 168)]
    [int]$IsolationCacheHours = 24,

    [ValidateRange(0, 1000000)]
    [int]$MaximumInputCharacters = 0,

    [ValidateRange(0, 1000000)]
    [int]$ExpectedReviewCharacters = 0,

    [ValidateRange(65536, 16777216)]
    [int]$MaxRawOutputBytes = 1048576,

    [ValidateRange(0.01, 100)]
    [double]$MaximumReviewerBudgetUsd = 0,

    [ValidateRange(0, 3600)]
    [int]$ReviewerTimeoutSeconds = 0,

    [switch]$ValidateOnly,

    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$skillRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$scriptVersion = '1.3-deepseek-v4-pro'

function Get-TextSha256 {
    param([Parameter(Mandatory)][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Get-CommandVersionText {
    param([Parameter(Mandatory)][string]$Executable)
    try {
        $info = Get-Item -LiteralPath $Executable
        "$($info.VersionInfo.FileVersion)|$($info.Length)|$($info.LastWriteTimeUtc.Ticks)"
    } catch { 'unknown' }
}

function Test-PacketPreflight {
    param([string]$Text, [string]$Type)
    $required = if ($Type -eq 'Plan') {
        @('Research objective','Method novelty claim','Baselines and comparison methods','Expected evidence and success metrics','Dataset / experiment source','Ground truth and label definition','Statistical test / repeated trials','Leakage control','Failure criteria','Cost and hardware constraints')
    } elseif ($Type -eq 'Procedure') {
        @('Procedure objective','Hardware / software / environment','Step-by-step procedure','Required inputs','Required outputs','Parameters to freeze before execution','Data recording requirements','Safety and equipment risks','Failure handling / fallback path','Stop conditions','Reproducibility requirements')
    } elseif ($Type -eq 'Experiment') {
        @('Research objective','Acceptance criteria from the plan','Program and environment summary','Codex experiment flow','Exact commands','Exit state','Decisive metrics','Ground truth and label definition','Baseline / control evidence','Repeated trials or statistical analysis','Data leakage controls','Safety and stop conditions','Codex diagnosis','Remaining uncertainties')
    } else { @() }
    $critical = switch ($Type) {
        'Plan' {@('Ground truth and label definition','Expected evidence and success metrics','Baselines and comparison methods','Statistical test / repeated trials','Leakage control')}
        'Procedure' {@('Required inputs','Required outputs','Data recording requirements','Safety and equipment risks','Data leakage / ground-truth leakage controls','Stop conditions','Reproducibility requirements')}
        default {@('Ground truth and label definition','Decisive metrics','Baseline / control evidence','Repeated trials or statistical analysis','Data leakage controls','Safety and stop conditions','Codex diagnosis')}
    }
    $missing = @(); $criticalMissing = @()
    $placeholder = '^(?i:x|tbd|n/?a|none|todo|to be determined)$'
    $chinesePlaceholders = @([string][char]0x5F85 + [char]0x5B9A, [string][char]0x5F85 + [char]0x8865 + [char]0x5145, [string][char]0x65E0, [string][char]0x672A + [char]0x77E5, [string][char]0x8BF7 + [char]0x586B + [char]0x5199)
    $headings = [regex]::Matches($Text, '(?m)^##[ \t]+(?<title>[^\r\n]+)[ \t]*$')
    foreach ($name in $required) {
        $headingIndex = -1
        for ($index = 0; $index -lt $headings.Count; $index++) {
            $title = $headings[$index].Groups.Item('title').Value.Trim()
            if ($title.StartsWith($name, [StringComparison]::OrdinalIgnoreCase)) {
                $headingIndex = $index
                break
            }
        }
        if ($headingIndex -lt 0) {
            $missing += $name
            continue
        }
        $bodyStart = $headings[$headingIndex].Index + $headings[$headingIndex].Length
        $bodyEnd = if ($headingIndex + 1 -lt $headings.Count) { $headings[$headingIndex + 1].Index } else { $Text.Length }
        $body = $Text.Substring($bodyStart, $bodyEnd - $bodyStart).Trim()
        if ([string]::IsNullOrWhiteSpace($body) -or $body -match $placeholder -or $body -in $chinesePlaceholders -or $body.Length -lt 4) { $missing += $name }
    }
    $criticalMissing = @($missing | Where-Object { $_ -in $critical })
    $status = if ($criticalMissing.Count -gt 0 -or ($required.Count -gt 0 -and $missing.Count -ge [math]::Ceiling($required.Count * 0.4))) { 'blocked' } elseif ($missing.Count -gt 0) { 'warning' } else { 'passed' }
    [pscustomobject]@{ Status = $status; Missing = $missing; CriticalMissing=$criticalMissing }
}

function Get-IsolationFingerprint {
    param([string]$Reviewer,[string]$CliPath,[string]$CliVersion,[string]$PromptHash)
    Get-TextSha256 "$Reviewer|$CliPath|$CliVersion|$PromptHash|plan|tools-disabled|bare|strict-mcp|no-chrome|empty-random-sandbox|$scriptVersion|$env:USERNAME"
}

function Get-CachedIsolation {
    param([string]$CachePath,[string]$Fingerprint,[int]$Hours)
    if (-not (Test-Path -LiteralPath $CachePath)) { return $null }
    try {
        $item = Get-Content -LiteralPath $CachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $age = ((Get-Date) - [datetime]$item.timestamp).TotalHours
        if ($item.status -eq 'passed' -and $item.fingerprint -eq $Fingerprint -and $age -ge 0 -and $age -lt $Hours) {
            return [pscustomobject]@{ Status='passed'; Error=''; Cached=$true; AgeHours=[math]::Round($age,2) }
        }
    } catch {}
    $null
}

function Save-IsolationCache {
    param([string]$CachePath,[string]$Fingerprint,[string]$Status)
    New-Item -ItemType Directory -Path (Split-Path $CachePath -Parent) -Force | Out-Null
    [ordered]@{timestamp=(Get-Date).ToString('o');fingerprint=$Fingerprint;status=$Status} |
        ConvertTo-Json | Set-Content -LiteralPath $CachePath -Encoding UTF8
}

function Read-Utf8File {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "$Label is not a valid file: $resolved"
    }
    Get-Content -LiteralPath $resolved -Raw -Encoding UTF8
}

function Get-EvidenceFileSet {
    param([string]$Packet,[string]$ProjectRoot)
    $items=[Collections.Generic.List[object]]::new(); $inList=$false
    foreach($line in ($Packet -split "`r?`n")) {
        if($line -match '^\s*evidence_files\s*:\s*$'){$inList=$true;continue}
        if($inList -and $line -match '^\s*-\s*(?<p>[^#\r\n]+)'){
            $relative=$Matches.p.Trim().Trim('"',"'")
            if($relative -match '(^|[\\/])(\.git|\.roundtable|node_modules|\.venv|venv|__pycache__|dist|build|coverage)([\\/]|$)'){throw "evidence_files may not include ignored path: $relative"}
            $full=(Join-Path $ProjectRoot $relative); $resolved=(Resolve-Path -LiteralPath $full -ErrorAction Stop).Path
            if(-not (Test-Path -LiteralPath $resolved -PathType Leaf) -or (Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Invalid evidence file: $relative"}
            if(-not $resolved.StartsWith($ProjectRoot.TrimEnd('\')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw "Evidence file escapes project root: $relative"}
            $text=Read-Utf8File $resolved 'Evidence file'; $items.Add([pscustomobject]@{relative_path=$relative;full_path=$resolved;sha256=(Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant();characters=$text.Length})
            continue
        }
        if($inList -and $line -match '^\S'){break}
    }
    if($items.Count -gt 6){throw 'evidence_files may contain at most 6 files.'}
    if((@($items|Measure-Object characters -Sum).Sum) -gt 25000){throw 'evidence_files exceed the 25000-character budget.'}
    $items
}

function Invoke-IsolatedProcess {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][AllowEmptyString()][string]$InputText,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][ValidateRange(1, 3600)][int]$TimeoutSeconds,
        [hashtable]$Environment = @{}
    )
    New-Item -ItemType Directory -Path $WorkingDirectory -Force | Out-Null
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.Arguments = $Arguments
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($key in $Environment.Keys) {
        $startInfo.EnvironmentVariables[$key] = [string]$Environment[$key]
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "$Name could not be started." }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.Write($InputText)
    $process.StandardInput.Close()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill($true) } catch { try { $process.Kill() } catch {} }
        try { $process.WaitForExit() } catch {}
        throw 'timeout'
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
        $safeError = if ($stderr.Length -gt 2000) { $stderr.Substring(0, 2000) } else { $stderr }
        throw "$Name failed with exit code $($process.ExitCode): $safeError"
    }
    if ([string]::IsNullOrWhiteSpace($stdout)) { throw "$Name returned no output." }
    $stdout.Trim()
}

function Test-ReviewerIsolation {
    param(
        [Parameter(Mandatory)][ValidateSet('DeepSeek')][string]$Reviewer,
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )
    $smoke = 'Isolation smoke test. Do not read files, inspect directories, call tools, or run commands. Based only on this text, output exactly ISOLATED_OK.'
    try {
        $output = Invoke-IsolatedProcess -Name 'DeepSeek isolation test' -Executable $Executable `
            -Arguments '-p --permission-mode plan --tools "" --bare --strict-mcp-config --disable-slash-commands --no-chrome --no-session-persistence --output-format text' `
            -InputText $smoke -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds
        $cleanOutput = $output.Trim() -replace '^\s*[-*`\u2022]+\s*', '' -replace '\s*[-*`]+\s*$', ''
        if ($cleanOutput.Trim() -ceq 'ISOLATED_OK') {
            [pscustomobject]@{ Status = 'passed'; Error = '' }
        } else {
            [pscustomobject]@{ Status = 'failed'; Error = "Unexpected isolation response: $output" }
        }
    } catch {
        [pscustomobject]@{ Status = 'failed'; Error = $_.Exception.Message }
    }
}

function Convert-ReviewOutput {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][ValidateSet('D')][string]$Prefix,
        [Parameter(Mandatory)][string]$Mode
    )
    if ($Text.Trim() -eq 'NO_MATERIAL_CHANGE') {
        return [pscustomobject]@{
            Status = 'valid'; Normalized = ''; ValidCount = 0; UnparsedCount = 0
        }
    }
    $valid = [Collections.Generic.List[string]]::new()
    $unparsed = [Collections.Generic.List[string]]::new()
    $seenIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $categories = @('engineering_feasibility','scientific_validity','statistical_validity','publication_viability','execution_risk','safety','reproducibility','data_integrity')
    $blockingEffects = @('blocks_execution','blocks_publication','presentation_only','non_blocking_improvement')
    $lineNumber = 0
    foreach ($line in ($Text -split "`r?`n")) {
        $lineNumber++
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        try { $item = $trimmed | ConvertFrom-Json -ErrorAction Stop } catch { $item = $null }
        $reason = ''
        if (-not $item) { $reason='invalid_json' }
        elseif (-not $item.id -or -not $item.severity -or -not $item.category -or -not $item.blocking_effect -or -not $item.anchor -or -not $item.evidence -or -not $item.action) { $reason='missing_required_field' }
        elseif ($item.id -notmatch "^$Prefix\d+$") { $reason='invalid_id' }
        elseif (-not $seenIds.Add([string]$item.id)) { $reason='duplicate_id' }
        elseif ($item.severity -notin @('MUST_FIX','RECOMMENDED')) { $reason='invalid_severity' }
        elseif ($Mode -like '*Normal' -and $item.severity -ne 'MUST_FIX') { $reason='mode_disallows_recommended' }
        elseif ($item.category -notin $categories) { $reason='invalid_category' }
        elseif ($item.blocking_effect -notin $blockingEffects) { $reason='invalid_blocking_effect' }
        elseif (([string]$item.anchor).Trim().Length -lt 2 -or ([string]$item.evidence).Trim().Length -lt 4 -or ([string]$item.action).Trim().Length -lt 4) { $reason='insufficient_content' }
        if ($reason) { $unparsed.Add(([ordered]@{type='UNPARSED_REVIEW_ITEM';reason=$reason;raw_line_reference=$lineNumber;raw=$trimmed}|ConvertTo-Json -Compress)); continue }
        $record = [ordered]@{id=[string]$item.id;reviewer='deepseek_v4_pro';severity=[string]$item.severity;category=[string]$item.category;blocking_effect=[string]$item.blocking_effect;anchor=[string]$item.anchor;evidence=[string]$item.evidence;action=[string]$item.action;related_issue_id=if($item.related_issue_id){[string]$item.related_issue_id}else{''};raw_line_reference=$lineNumber}
        $valid.Add(($record | ConvertTo-Json -Compress))
    }
    $status = if ($valid.Count -gt 0 -and $unparsed.Count -eq 0) {
        'valid'
    } elseif ($valid.Count -gt 0) {
        'partially_valid'
    } else {
        'invalid'
    }
    $normalizedLines = @($valid) + @($unparsed)
    [pscustomobject]@{
        Status = $status
        Normalized = ($normalizedLines -join [Environment]::NewLine)
        ValidCount = $valid.Count
        UnparsedCount = $unparsed.Count
    }
}

function New-ReviewerState {
    param([bool]$Enabled, [string]$ReviewStage = '')
    [ordered]@{
        enabled = $Enabled
        review_stage = $ReviewStage
        completed = $false
        isolation_status = if ($Enabled) { 'skipped' } else { 'skipped' }
        isolation_cached = $false
        isolation_cache_age_hours = 0
        isolation_fingerprint = ''
        format_status = 'skipped'
        raw_output_path = ''
        normalized_output_path = ''
        output_characters = 0
        output_too_long = $false
        raw_output_saved = $false
        review_cache_hit = $false
        review_cache_key = ''
        review_cache_source = ''
        incomplete_status = ''
        error = ''
        timeout_seconds = 0
    }
}

function Save-ReviewerResult {
    param(
        [Parameter(Mandatory)][string]$ReviewerName,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$Output,
        [Parameter(Mandatory)][string]$ReviewDirectory,
        [Parameter(Mandatory)][int]$ExpectedCharacters,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State
    )
    $rawPath = Join-Path $ReviewDirectory "$ReviewerName-review.raw.md"
    [IO.File]::WriteAllText($rawPath, $Output + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    $parsed = Convert-ReviewOutput -Text $Output -Prefix $Prefix -Mode $Mode
    $normalizedPath = Join-Path $ReviewDirectory "$ReviewerName-review.normalized.jsonl"
    [IO.File]::WriteAllText($normalizedPath, $parsed.Normalized + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    $State.completed = $true
    $State.format_status = $parsed.Status
    $State.raw_output_path = $rawPath
    $State.normalized_output_path = $normalizedPath
    $State.output_characters = $Output.Length
    $State.output_too_long = ($Output.Length -gt $ExpectedCharacters)
    $State.raw_output_saved = $true
    if ($State.output_too_long -and $parsed.Status -eq 'invalid') {
        $State.incomplete_status = 'REVIEW_INCOMPLETE_OUTPUT_TOO_LONG'
    }
}

function Restore-ReviewCache {
    param([string]$CacheDirectory,[string]$ReviewerName,[string]$ReviewDirectory,[System.Collections.IDictionary]$State)
    $metaPath = Join-Path $CacheDirectory 'meta.json'
    $rawSource = Join-Path $CacheDirectory 'review.raw.md'
    $normalizedSource = Join-Path $CacheDirectory 'review.normalized.jsonl'
    if (-not (Test-Path $metaPath) -or -not (Test-Path $rawSource) -or -not (Test-Path $normalizedSource)) { return $false }
    try {
        $meta = Get-Content $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $rawTarget = Join-Path $ReviewDirectory "$ReviewerName-review.raw.md"
        $normalizedTarget = Join-Path $ReviewDirectory "$ReviewerName-review.normalized.jsonl"
        Copy-Item $rawSource $rawTarget -Force
        Copy-Item $normalizedSource $normalizedTarget -Force
        $State.completed=$true;$State.isolation_status='passed';$State.format_status=$meta.format_status
        $State.raw_output_path=$rawTarget;$State.normalized_output_path=$normalizedTarget
        $State.output_characters=$meta.output_characters;$State.raw_output_saved=$true
        $State.review_cache_hit=$true;$State.review_cache_source=$CacheDirectory
        return $true
    } catch { return $false }
}

function Save-ReviewCache {
    param([string]$CacheDirectory,[System.Collections.IDictionary]$State)
    if ($State.format_status -ne 'valid' -or -not $State.completed -or $State.incomplete_status) { return }
    New-Item -ItemType Directory -Path $CacheDirectory -Force | Out-Null
    Copy-Item $State.raw_output_path (Join-Path $CacheDirectory 'review.raw.md') -Force
    Copy-Item $State.normalized_output_path (Join-Path $CacheDirectory 'review.normalized.jsonl') -Force
    [ordered]@{format_status=$State.format_status;output_characters=$State.output_characters;timestamp=(Get-Date).ToString('o')} |
        ConvertTo-Json | Set-Content (Join-Path $CacheDirectory 'meta.json') -Encoding UTF8
}

function Get-AdjudicationStatus {
    param($DeepSeekState)
    $enabled = @(@($DeepSeekState) | Where-Object { $_.enabled })
    $usable = @($enabled | Where-Object {
        $_.completed -and $_.isolation_status -eq 'passed' -and $_.format_status -in @('valid', 'partially_valid')
    })
    if ($usable.Count -eq 0) { return 'failed' }
    if ($usable.Count -lt $enabled.Count -or ($usable | Where-Object { $_.format_status -ne 'valid' })) { return 'partial' }
    'completed'
}

function Invoke-SelfTest {
    $validText = '{"id":"D1","severity":"MUST_FIX","category":"scientific_validity","blocking_effect":"blocks_publication","anchor":"S1","evidence":"Evidence is specific","action":"Apply a concrete correction"}'
    $valid = Convert-ReviewOutput -Text $validText -Prefix D -Mode DocumentNormal
    if ($valid.Status -ne 'valid' -or $valid.ValidCount -ne 1) { throw 'Valid format test failed.' }
    $partialText = '{"id":"D1","severity":"MUST_FIX","category":"scientific_validity","blocking_effect":"blocks_publication","anchor":"S2","evidence":"Specific causal flaw","action":"Add a control"}' + "`nGeneral summary"
    $partial = Convert-ReviewOutput -Text $partialText -Prefix D -Mode DocumentNormal
    if ($partial.Status -ne 'partially_valid' -or $partial.UnparsedCount -ne 1) { throw 'Partial format test failed.' }
    $duplicateText = '{"id":"D1","severity":"MUST_FIX","category":"scientific_validity","blocking_effect":"blocks_publication","anchor":"S1","evidence":"First specific issue","action":"Apply first fix"}' + "`n" + '{"id":"D1","severity":"MUST_FIX","category":"scientific_validity","blocking_effect":"blocks_publication","anchor":"S2","evidence":"Second specific issue","action":"Apply second fix"}'
    $duplicate = Convert-ReviewOutput -Text $duplicateText -Prefix D -Mode DocumentNormal
    if ($duplicate.Status -ne 'partially_valid' -or $duplicate.UnparsedCount -ne 1) {
        throw 'Duplicate identifier test failed.'
    }
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ("roundtable-selftest-{0}" -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporary -Force | Out-Null
    try {
        $state = New-ReviewerState $true
        $state.isolation_status = 'passed'
        $large = '{"id":"D1","severity":"MUST_FIX","category":"scientific_validity","blocking_effect":"blocks_publication","anchor":"S1","evidence":"' + ('E' * 20000) + '","action":"Apply correction"}'
        Save-ReviewerResult -ReviewerName deepseek -Prefix D -Output $large -ReviewDirectory $temporary `
            -ExpectedCharacters 100 -Mode DocumentNormal -State $state
        $raw = Get-Content -LiteralPath $state.raw_output_path -Raw -Encoding UTF8
        if ($raw.Length -lt $large.Length -or -not $state.output_too_long) { throw 'Raw output preservation test failed.' }
        $failed = New-ReviewerState $true
        $failed.error = 'mock failure'
        if ((Get-AdjudicationStatus -DeepSeekState $failed) -ne 'failed') { throw 'DeepSeek failure status test failed.' }
        $manifestTestPath = Join-Path $temporary 'roundtable-manifest.json'
        $manifestTest = [ordered]@{
            timestamp = (Get-Date).ToString('o')
            review_type = 'Procedure'
            mode = 'DocumentNormal'
            packet_sha256 = ('0' * 64)
            reviewers = [ordered]@{ deepseek_v4_pro = $state }
            adjudication_status = 'completed'
            authorization_status = 'pending'
        }
        $manifestTest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestTestPath -Encoding UTF8
        $manifestRoundTrip = Get-Content -LiteralPath $manifestTestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($manifestRoundTrip.adjudication_status -ne 'completed' -or
            $manifestRoundTrip.authorization_status -ne 'pending') {
            throw 'Manifest round-trip test failed.'
        }
        $isolationPath = Join-Path $temporary 'isolation.json'
        if (Get-CachedIsolation $isolationPath 'fp1' 24) { throw 'Isolation cold-cache test failed.' }
        Save-IsolationCache $isolationPath 'fp1' 'passed'
        if (-not (Get-CachedIsolation $isolationPath 'fp1' 24)) { throw 'Isolation cache-hit test failed.' }
        if (Get-CachedIsolation $isolationPath 'changed-prompt-fp' 24) { throw 'Isolation fingerprint invalidation failed.' }
        $reviewCache = Join-Path $temporary 'review-cache-key'
        Save-ReviewCache $reviewCache $state
        $restored = New-ReviewerState $true
        if (-not (Restore-ReviewCache $reviewCache 'deepseek-cached' $temporary $restored) -or -not $restored.review_cache_hit) {
            throw 'Exact review cache-hit test failed.'
        }
        if (Test-Path (Join-Path $temporary 'changed-packet-key')) { throw 'Packet cache invalidation test failed.' }
        $preflightBlocked = Test-PacketPreflight '# Plan Review Packet' 'Plan'
        if ($preflightBlocked.Status -ne 'blocked') { throw 'Preflight blocked test failed.' }
        $experimentBlocked = Test-PacketPreflight '# Experiment review packet' 'Experiment'
        if ($experimentBlocked.Status -ne 'blocked') { throw 'Experiment preflight blocked test failed.' }
        $experimentPacket = @'
## Research objective
objective
## Acceptance criteria from the plan
criteria
## Program and environment summary
environment
## Codex experiment flow
workflow
## Exact commands
commands
## Exit state
completed
## Decisive metrics
metrics
## Ground truth and label definition
truth
## Baseline / control evidence
control
## Repeated trials or statistical analysis
trials
## Data leakage controls
controls
## Safety and stop conditions
safety stop
## Codex diagnosis
diagnosis
## Remaining uncertainties
uncertainties
'@
        $experimentPassed = Test-PacketPreflight $experimentPacket 'Experiment'
        if ($experimentPassed.Status -ne 'passed') { throw 'Experiment preflight pass test failed.' }
        $invalidReview = Convert-ReviewOutput 'free-form summary only' D DocumentNormal
        if ($invalidReview.Status -ne 'invalid') { throw 'Invalid normalized fallback test failed.' }
        $ledgerTest = Join-Path $temporary 'roundtable-issue-ledger.jsonl'
        $ledgerItem = [ordered]@{issue_id='ISSUE-001';status='open';severity='MUST_FIX';issue='test issue'}
        [IO.File]::WriteAllText($ledgerTest, ($ledgerItem|ConvertTo-Json -Compress)+[Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        $ledgerOpen = @(Get-Content $ledgerTest -Encoding UTF8 | ForEach-Object {$_|ConvertFrom-Json} | Where-Object {$_.status -eq 'open' -and $_.severity -eq 'MUST_FIX'}).Count
        if ($ledgerOpen -ne 1) { throw 'Issue ledger unresolved tracking test failed.' }
        $timeoutObserved = $false
        try {
            Invoke-IsolatedProcess -Name 'timeout self-test' `
                -Executable (Join-Path $PSHOME 'powershell.exe') `
                -Arguments '-NoProfile -Command "Start-Sleep -Seconds 2; Write-Output done"' `
                -InputText '' -WorkingDirectory $temporary -TimeoutSeconds 1 | Out-Null
        } catch {
            $timeoutObserved = ($_.Exception.Message -eq 'timeout')
        }
        if (-not $timeoutObserved) { throw 'Reviewer timeout test failed.' }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
    Write-Output 'SELF_TEST_PASS: format validation'
    Write-Output 'SELF_TEST_PASS: full raw output preservation'
    Write-Output 'SELF_TEST_PASS: one-reviewer partial degradation'
    Write-Output 'SELF_TEST_PASS: manifest generation and round-trip'
    Write-Output 'SELF_TEST_PASS: isolation cache cold, hit, and fingerprint invalidation'
    Write-Output 'SELF_TEST_PASS: exact review cache hit and packet-key invalidation'
    Write-Output 'SELF_TEST_PASS: preflight blocked without reviewer'
    Write-Output 'SELF_TEST_PASS: experiment packet preflight completeness'
    Write-Output 'SELF_TEST_PASS: invalid normalized output requires raw fallback'
    Write-Output 'SELF_TEST_PASS: issue ledger tracks unresolved MUST_FIX'
    Write-Output 'SELF_TEST_PASS: reviewer process timeout and termination'
    Write-Output 'SELF_TEST_PASS: authorization default is pending by design'
}

if ($SelfTest) {
    Invoke-SelfTest
    return
}

if (-not $ReviewPacketPath) { throw 'ReviewPacketPath is required unless -SelfTest is used.' }
if ($Stage -eq 'CodexDraftCheck' -and -not $CodexDraftPath) {
    throw 'CodexDraftPath is required for the CodexDraftCheck stage.'
}
if ($Stage -eq 'Initial' -and $CodexDraftPath) {
    throw 'CodexDraftPath is only valid for the CodexDraftCheck stage.'
}
$readOnlyProjectRoot = ''
$readOnlyProjectFingerprint = ''
$evidenceFiles=@()
if ($ReadOnlyProjectPath) {
    $readOnlyProjectRoot = (Resolve-Path -LiteralPath $ReadOnlyProjectPath -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $readOnlyProjectRoot -PathType Container)) {
        throw "ReadOnlyProjectPath is not a directory: $readOnlyProjectRoot"
    }
    $evidenceFiles=@(Get-EvidenceFileSet -Packet $probe -ProjectRoot $readOnlyProjectRoot)
    $readOnlyProjectFingerprint=Get-TextSha256 (($evidenceFiles|ForEach-Object{"$($_.relative_path)|$($_.sha256)"}) -join "`n")
}

$probe = Read-Utf8File -Path $ReviewPacketPath -Label 'Review packet'
$typeMatch = [regex]::Match($probe, '(?im)^\s*type\s*:\s*(plan|procedure|experiment)\s*$')
if (-not $typeMatch.Success) { throw 'Review packet must explicitly declare `type: plan`, `type: procedure`, or `type: experiment`.' }
$ReviewType = (Get-Culture).TextInfo.ToTitleCase($typeMatch.Groups[1].Value.ToLowerInvariant())
if (($Mode -like 'Document*' -and $ReviewType -eq 'Experiment') -or ($Mode -like 'Experiment*' -and $ReviewType -ne 'Experiment')) {
    throw "Mode $Mode is incompatible with packet type $($typeMatch.Groups[1].Value)."
}

$modeSettings = @{
    DocumentNormal = @{
        OutputLimit = 12000
        ModelBudgetUsd = 1.00
        DraftAllowance = 6000
        TimeoutSeconds = 300
        ReviewInstruction = 'DOCUMENT NORMAL: Report every MUST_FIX finding and nothing else. Be compact; do not summarize or praise.'
    }
    DocumentDeep = @{
        OutputLimit = 24000
        ModelBudgetUsd = 3.00
        DraftAllowance = 10000
        TimeoutSeconds = 600
        ReviewInstruction = 'DOCUMENT DEEP: Perform a deep audit. Report every MUST_FIX and every material RECOMMENDED finding, including cross-field contradictions, missing controls, reproducibility gaps, and publication risks.'
    }
    ExperimentNormal = @{
        OutputLimit = 14000
        ModelBudgetUsd = 1.50
        DraftAllowance = 7000
        TimeoutSeconds = 300
        ReviewInstruction = 'EXPERIMENT NORMAL: Report every MUST_FIX finding and nothing else. Focus on execution validity, debugging, evidence, reproducibility, and safety.'
    }
    ExperimentDeep = @{
        OutputLimit = 26000
        ModelBudgetUsd = 4.00
        DraftAllowance = 11000
        TimeoutSeconds = 600
        ReviewInstruction = 'EXPERIMENT DEEP: Perform a deep audit of the execution record, debugging choices, controls, metrics, reproducibility, safety, and proposed changes. Report every MUST_FIX and every material RECOMMENDED finding.'
    }
}
$inputLimits = @{
    Plan = @{ DocumentNormal = 8000; DocumentDeep = 16000 }
    Procedure = @{ DocumentNormal = 9000; DocumentDeep = 17000 }
    Experiment = @{ ExperimentNormal = 10000; ExperimentDeep = 18000 }
}
$settings = $modeSettings[$Mode]
if ($MaximumInputCharacters -eq 0) { $MaximumInputCharacters = $inputLimits[$ReviewType][$Mode] }
if ($ExpectedReviewCharacters -eq 0) { $ExpectedReviewCharacters = $settings.OutputLimit }
if ($MaximumReviewerBudgetUsd -eq 0) { $MaximumReviewerBudgetUsd = $settings.ModelBudgetUsd }
if ($ReviewerTimeoutSeconds -eq 0) { $ReviewerTimeoutSeconds = $settings.TimeoutSeconds }
$ReviewerInputLimit = $MaximumInputCharacters + $(if ($Stage -eq 'CodexDraftCheck') { $settings.DraftAllowance } else { 0 })

$originalPacketPath = (Resolve-Path -LiteralPath $ReviewPacketPath).Path
$originalPacketHash = (Get-FileHash -LiteralPath $originalPacketPath -Algorithm SHA256).Hash.ToLowerInvariant()
$packetPathUsed = $originalPacketPath
$packet = Read-Utf8File -Path $packetPathUsed -Label 'Review packet'
$ideas = if ($UserIdeasPath) { Read-Utf8File -Path $UserIdeasPath -Label 'User ideas' } else { '' }
$codexDraft = if ($CodexDraftPath) { Read-Utf8File -Path $CodexDraftPath -Label 'Codex provisional recommendation' } else { '' }
if ($Stage -eq 'CodexDraftCheck' -and [string]::IsNullOrWhiteSpace($codexDraft)) {
    throw 'CodexDraftPath is empty. Supply Codex’s provisional recommendation before requesting DeepSeek review.'
}

$material = "===== REVIEW TYPE =====`r`n$ReviewType`r`n`r`nBEGIN UNTRUSTED PACKET`r`n$packet`r`nEND UNTRUSTED PACKET`r`n"
if (-not [string]::IsNullOrWhiteSpace($ideas)) {
    $material += "`r`nBEGIN UNTRUSTED USER IDEAS`r`n$ideas`r`nEND UNTRUSTED USER IDEAS`r`n"
}
if ($material.Length -gt $MaximumInputCharacters) {
    if (-not $CompressedReviewPacketPath) {
        throw "Review input has $($material.Length) characters, exceeding $MaximumInputCharacters. Create a compressed packet that preserves source anchors and decisive evidence, then pass -CompressedReviewPacketPath and -CompressionStrategy. The original packet was not truncated."
    }
    if ([string]::IsNullOrWhiteSpace($CompressionStrategy)) {
        throw 'CompressionStrategy is required with CompressedReviewPacketPath.'
    }
    $packetPathUsed = (Resolve-Path -LiteralPath $CompressedReviewPacketPath).Path
    $packet = Read-Utf8File -Path $packetPathUsed -Label 'Compressed review packet'
    $material = "===== REVIEW TYPE =====`r`n$ReviewType`r`n`r`nBEGIN UNTRUSTED COMPRESSED PACKET`r`n$packet`r`nEND UNTRUSTED COMPRESSED PACKET`r`n"
    if (-not [string]::IsNullOrWhiteSpace($ideas)) {
        $material += "`r`nBEGIN UNTRUSTED USER IDEAS`r`n$ideas`r`nEND UNTRUSTED USER IDEAS`r`n"
    }
    if ($material.Length -gt $MaximumInputCharacters) {
        throw "Compressed review input still exceeds $MaximumInputCharacters characters. It was not truncated."
    }
}
$effectivePacketHash = (Get-FileHash -LiteralPath $packetPathUsed -Algorithm SHA256).Hash.ToLowerInvariant()
$originalPacketCharacters = (Read-Utf8File -Path $originalPacketPath -Label 'Original packet').Length
$compressionEnabled = ($packetPathUsed -ne $originalPacketPath)
$compressionRatio = if ($originalPacketCharacters -gt 0) { [math]::Round($packet.Length / $originalPacketCharacters, 4) } else { 1 }
$preflight = Test-PacketPreflight -Text $packet -Type $ReviewType
if ($Mode -like '*Deep' -and $compressionEnabled -and $preflight.Status -ne 'passed') {
    $packetPathUsed = $originalPacketPath
    $packet = Read-Utf8File -Path $originalPacketPath -Label 'Original packet fallback'
    $material = "===== REVIEW TYPE =====`r`n$ReviewType`r`n`r`nBEGIN UNTRUSTED PACKET`r`n$packet`r`nEND UNTRUSTED PACKET`r`n"
    if ($material.Length -gt $MaximumInputCharacters) {
        throw 'Deep compressed packet failed preflight and the full-packet fallback exceeds the input limit. Supply a complete anchor-preserving compressed packet or explicitly accept degraded coverage.'
    }
    $effectivePacketHash = $originalPacketHash
    $compressionEnabled = $false
    $compressionRatio = 1
    $preflight = Test-PacketPreflight -Text $packet -Type $ReviewType
}

if ($preflight.Status -eq 'blocked' -and -not $ValidateOnly) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $reviewDirectory = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) $timestamp
    New-Item -ItemType Directory -Path $reviewDirectory -Force | Out-Null
    $manifestPath = Join-Path $reviewDirectory 'roundtable-manifest.json'
    [ordered]@{
        timestamp=(Get-Date).ToString('o');review_type=$ReviewType;mode=$Mode;review_stage=$Stage;review_scope='complete_packet'
        preflight_status='blocked';reviewers_called=$false;missing_required_fields=$preflight.Missing
        original_packet_sha256=$originalPacketHash;compressed_packet_sha256=$effectivePacketHash
        compression_enabled=$compressionEnabled;original_characters=$originalPacketCharacters
        compressed_characters=$packet.Length;compression_ratio=$compressionRatio
        project_read_access=[bool]$readOnlyProjectRoot;project_read_fingerprint=$readOnlyProjectFingerprint
        lean_must_fix_only=($Mode -like '*Normal');auto_format_retry=$false
        codex_read_raw=$false;codex_read_raw_reason='';authorization_status='pending'
        cost_saving_features=@('preflight_block')
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Write-Output 'PRECHECK_BLOCKED'
    Write-Output "Missing required fields: $($preflight.Missing -join '; ')"
    Write-Output "Manifest: $manifestPath"
    return
}

$deepseekMaterial = $material
if ($DeepSeekPacketPath) {
    $focused = Read-Utf8File -Path $DeepSeekPacketPath -Label 'DeepSeek-specific packet'
    $deepseekMaterial = "===== REVIEW TYPE =====`r`n$ReviewType`r`nBEGIN UNTRUSTED FOCUSED PACKET`r`n$focused`r`nEND UNTRUSTED FOCUSED PACKET"
    if (-not [string]::IsNullOrWhiteSpace($ideas)) {
        $deepseekMaterial += "`r`nBEGIN UNTRUSTED USER IDEAS`r`n$ideas`r`nEND UNTRUSTED USER IDEAS`r`n"
    }
    if ($deepseekMaterial.Length -gt $MaximumInputCharacters) {
        throw "DeepSeek-focused input has $($deepseekMaterial.Length) characters, exceeding $MaximumInputCharacters. Supply a smaller anchor-preserving focused packet; it was not truncated."
    }
}
if ($Stage -eq 'CodexDraftCheck') {
    $deepseekMaterial += "`r`nBEGIN UNTRUSTED CODEX DRAFT`r`n$codexDraft`r`nEND UNTRUSTED CODEX DRAFT`r`n"
    if ($deepseekMaterial.Length -gt $ReviewerInputLimit) {
        throw "Codex-draft check input has $($deepseekMaterial.Length) characters, exceeding $ReviewerInputLimit. Supply a shorter Codex recommendation or a smaller anchor-preserving focused packet; it was not truncated."
    }
}
$deepseekPacketHash = Get-TextSha256 $deepseekMaterial

$typeInstruction = switch ($ReviewType) {
    Plan { 'PLAN: Independently audit research question, novelty, falsifiability, baselines, leakage controls, ablations, statistics, validation, constraints, minimum publishable result, and downgrade path. Do not execute or edit.' }
    Procedure { 'PROCEDURE: Decide whether the supplied procedure is directly executable. Audit missing or misordered steps, frozen parameters, records, reproducibility, safety, leakage, stop conditions, and fallback paths. Do not execute or edit.' }
    Experiment { 'EXPERIMENT: Audit Codex execution record, debugging choices, logs summarized in the packet, controls, reproducibility, leakage, metrics, diagnosis, and proposed changes. Do not execute or edit.' }
}
$scopeInstruction = 'Review every item in the supplied packet. If it is a focused packet, assess only that packet and do not claim coverage of omitted source material.'
$projectAccessInstruction = if ($readOnlyProjectRoot) {
    'PROJECT READ ACCESS: The working directory contains only the packet evidence_files whitelist. Use Read only on those files. Do not Glob or Grep for additional files, scan directories, or request unlisted files through tools. If another file is needed, state its exact relative path and reason in a finding; Codex may add it to a later packet.'
} else {
    'PACKET-ONLY ACCESS: Do not inspect files or directories. Use only the supplied review packet.'
}
$stageInstruction = if ($Stage -eq 'Initial') {
    'INITIAL ASSISTANT REVIEW: Independently inspect the shared requirement or execution record and give Codex evidence-based review findings. Do not assume Codex has made a decision.'
} else {
    'CODEX-DRAFT CHECK: Read the shared requirement or execution record and Codex’s provisional recommendation. Report only material omissions, unsupported decisions, conflicts, unsafe changes, or verification gaps in Codex’s recommendation. Do not repeat items Codex handled correctly. Do not rewrite or modify the recommendation.'
}
$anchorInstruction = 'Cite supplied source anchors (for example S1/S3) in the second field whenever possible. An unanchored finding is allowed only when the packet itself makes the issue explicit.'
$corePrompt = Read-Utf8File -Path (Join-Path $skillRoot 'references\core-readonly-rules.txt') -Label 'Core readonly prompt'
$formatPrompt = Read-Utf8File -Path (Join-Path $skillRoot 'references\review-format-rules.txt') -Label 'Review format prompt'
$deepseekRole = Read-Utf8File -Path (Join-Path $skillRoot 'references\deepseek-role-short.txt') -Label 'DeepSeek role prompt'
$modePromptFile = switch($ReviewType){Plan{'plan-mode-rules.txt'}Procedure{'procedure-mode-rules.txt'}default{'experiment-mode-rules.txt'}}
$taskModePrompt = Read-Utf8File -Path (Join-Path $skillRoot "references\$modePromptFile") -Label 'Task mode prompt'
$standardExtra = ''
$deepseekPrompt = "$corePrompt`n$deepseekRole`n$formatPrompt`n$taskModePrompt`n$standardExtra"
$deepseekInput = "$deepseekPrompt`r`n$typeInstruction`r`n$scopeInstruction`r`n$projectAccessInstruction`r`n$stageInstruction`r`n$anchorInstruction`r`nMODEL OUTPUT BUDGET: keep the complete JSONL response within about $ExpectedReviewCharacters characters.`r`n$($settings.ReviewInstruction)`r`n$deepseekMaterial"

$claudeWrapper = (Get-Command claude.cmd -ErrorAction Stop).Source
$claudeCommand = Join-Path (Split-Path $claudeWrapper -Parent) 'node_modules\@anthropic-ai\claude-code\bin\claude.exe'
if (-not (Test-Path -LiteralPath $claudeCommand -PathType Leaf)) {
    throw "Claude Code native executable was not found: $claudeCommand"
}
$dataRootFull = [IO.Path]::GetFullPath($DataRoot)
$outputRootFull = [IO.Path]::GetFullPath($OutputDirectory)
$sandboxRoot = Join-Path $dataRootFull 'sandbox'
$cacheRoot = Join-Path $dataRootFull 'cache'
$isolationCacheRoot = Join-Path $cacheRoot 'isolation'
$reviewCacheRoot = Join-Path $cacheRoot 'reviews'
$reviewerArguments = if ($readOnlyProjectRoot) {
    ('-p --permission-mode plan --tools "Read,Glob,Grep" --bare --strict-mcp-config --disable-slash-commands --no-chrome --no-session-persistence --max-budget-usd ' + $MaximumReviewerBudgetUsd + ' --output-format text')
} else {
    ('-p --permission-mode plan --tools "" --bare --strict-mcp-config --disable-slash-commands --no-chrome --no-session-persistence --max-budget-usd ' + $MaximumReviewerBudgetUsd + ' --output-format text')
}
$permissionsPolicyVersion = 'readonly-policy-v2'
$deepseekPromptHash = Get-TextSha256 $deepseekInput
$deepseekCliVersion = Get-CommandVersionText $claudeCommand
$deepseekFingerprint = Get-IsolationFingerprint DeepSeek $claudeCommand $deepseekCliVersion $deepseekPromptHash
$ideasHash = if($ideas){Get-TextSha256 $ideas}else{''}
$deepseekReviewKey = Get-TextSha256 "$deepseekInput|$reviewerArguments|$deepseekCliVersion|deepseek_v4_pro|$permissionsPolicyVersion|$Mode|$Stage|$effectivePacketHash|$ideasHash|$readOnlyProjectFingerprint|$scriptVersion"

if ($ValidateOnly) {
    Write-Output 'Roundtable validation passed.'
    Write-Output "Review type: $ReviewType"
    Write-Output "Mode: $Mode"
    Write-Output "Stage: $Stage"
    Write-Output "Reviewer input characters: $($deepseekMaterial.Length)"
    Write-Output "Reviewer input limit: $ReviewerInputLimit"
    Write-Output "Project read access: $([bool]$readOnlyProjectRoot)"
    Write-Output "Original packet SHA256: $originalPacketHash"
    Write-Output "Effective packet SHA256: $effectivePacketHash"
    Write-Output "Preflight: $($preflight.Status)"
    Write-Output 'Reviewer coverage: DeepSeek v4 Pro only'
    Write-Output "Reviewer timeout seconds: $ReviewerTimeoutSeconds"
    return
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reviewDirectory = Join-Path $outputRootFull $timestamp
New-Item -ItemType Directory -Path $reviewDirectory -Force | Out-Null
$deepseekState = New-ReviewerState $true $Stage
$deepseekState.timeout_seconds = $ReviewerTimeoutSeconds

$deepseekState.isolation_fingerprint = $deepseekFingerprint
$deepseekState.review_cache_key = $deepseekReviewKey
$reviewerResultName = if ($Stage -eq 'Initial') { 'deepseek-initial' } else { 'deepseek-codex-draft' }
$deepseekSandbox = Join-Path $sandboxRoot ("deepseek-{0}" -f [guid]::NewGuid().ToString('N'))
$evidenceSandbox=Join-Path $sandboxRoot ("evidence-{0}" -f [guid]::NewGuid().ToString('N'))
if($readOnlyProjectRoot){foreach($file in $evidenceFiles){$target=Join-Path $evidenceSandbox $file.relative_path;New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force|Out-Null;Copy-Item -LiteralPath $file.full_path -Destination $target -Force}}
$reviewerWorkingDirectory = if ($readOnlyProjectRoot) { $evidenceSandbox } else { $deepseekSandbox }
try {
    $isolationCachePath = Join-Path $isolationCacheRoot 'deepseek.json'
    $isolation = Get-CachedIsolation -CachePath $isolationCachePath -Fingerprint $deepseekFingerprint -Hours $IsolationCacheHours
    if ($isolation) {
        $deepseekState.isolation_cached = $true
        $deepseekState.isolation_cache_age_hours = $isolation.AgeHours
    } else {
        $isolation = Test-ReviewerIsolation -Reviewer DeepSeek -Executable $claudeCommand `
            -WorkingDirectory $deepseekSandbox -TimeoutSeconds $ReviewerTimeoutSeconds
        Save-IsolationCache -CachePath $isolationCachePath -Fingerprint $deepseekFingerprint -Status $isolation.Status
    }
    $deepseekState.isolation_status = $isolation.Status
    if ($isolation.Status -ne 'passed') {
        $deepseekState.error = $isolation.Error
    } else {
        $cacheDirectory = Join-Path $reviewCacheRoot $deepseekReviewKey
        if (-not (Restore-ReviewCache -CacheDirectory $cacheDirectory -ReviewerName $reviewerResultName -ReviewDirectory $reviewDirectory -State $deepseekState)) {
            $output = Invoke-IsolatedProcess -Name "DeepSeek v4 Pro $Stage review through Claude Code" `
                -Executable $claudeCommand `
                -Arguments $reviewerArguments `
                -InputText $deepseekInput -WorkingDirectory $reviewerWorkingDirectory -TimeoutSeconds $ReviewerTimeoutSeconds
            if ([Text.Encoding]::UTF8.GetByteCount($output) -gt $MaxRawOutputBytes) {
                $rawPath = Join-Path $reviewDirectory "$reviewerResultName-review.raw.md"
                [IO.File]::WriteAllText($rawPath, $output + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
                $deepseekState.raw_output_path=$rawPath;$deepseekState.raw_output_saved=$true
                $deepseekState.output_characters=$output.Length;$deepseekState.incomplete_status='REVIEW_INCOMPLETE_OUTPUT_LIMIT'
            } else {
                Save-ReviewerResult -ReviewerName $reviewerResultName -Prefix D -Output $output `
                    -ReviewDirectory $reviewDirectory -ExpectedCharacters $ExpectedReviewCharacters -Mode $Mode -State $deepseekState
            }
            Save-ReviewCache -CacheDirectory $cacheDirectory -State $deepseekState
        }
    }
} catch {
    $deepseekState.error = $_.Exception.Message
    $deepseekState.incomplete_status = 'REVIEW_INCOMPLETE_TOOL_FAILURE'
} finally {
    if (Test-Path -LiteralPath $deepseekSandbox) { Remove-Item -LiteralPath $deepseekSandbox -Recurse -Force }
    if (Test-Path -LiteralPath $evidenceSandbox) { Remove-Item -LiteralPath $evidenceSandbox -Recurse -Force }
}

$adjudicationStatus = Get-AdjudicationStatus -DeepSeekState $deepseekState
$ledgerPath = if ($IssueLedgerPath) { [IO.Path]::GetFullPath($IssueLedgerPath) } else { Join-Path (Split-Path $outputRootFull -Parent) 'roundtable-issue-ledger.jsonl' }
$existingLedger = @()
if (Test-Path $ledgerPath) {
    $existingLedger = @(Get-Content $ledgerPath -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}
if ($IssueLifecycleUpdatesPath) {
    if (-not $AuthorizationRecordPath) { throw 'AuthorizationRecordPath is required to update issue lifecycle states.' }
    $approval = Read-Utf8File -Path $AuthorizationRecordPath -Label 'User authorization record' | ConvertFrom-Json
    if (-not $approval.user_approved -or -not $approval.approved_at) { throw 'Authorization record must contain user_approved: true and approved_at.' }
    $updates = Get-Content -LiteralPath $IssueLifecycleUpdatesPath -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }
    foreach($update in $updates) {
        if ($update.status -notin @('resolved','rejected','deferred') -or -not $update.issue_id -or -not $update.handling_evidence -or -not $update.change_set_hash -or -not $update.responsibility -or -not $update.rollback_info) { throw 'Each lifecycle update requires issue_id, status, handling_evidence, change_set_hash, responsibility, and rollback_info.' }
        $entry=@($existingLedger|Where-Object {$_.issue_id -eq $update.issue_id})|Select-Object -First 1
        if(-not $entry -or $entry.status -ne 'open'){throw "Invalid lifecycle transition for $($update.issue_id)."}
        $entry.status=$update.status;$entry.resolution_note=$update.handling_evidence;$entry.change_set_hash=$update.change_set_hash;$entry.approval_time=$approval.approved_at;$entry.responsibility=$update.responsibility;$entry.rollback_info=$update.rollback_info
    }
}
$roundId = (Get-Date).ToString('o')
foreach ($state in @($deepseekState)) {
    if (-not $state.normalized_output_path -or -not (Test-Path $state.normalized_output_path)) { continue }
    foreach ($line in (Get-Content $state.normalized_output_path -Encoding UTF8 | Where-Object { $_.Trim() })) {
        try { $item = $line | ConvertFrom-Json } catch { continue }
        if ($item.type -eq 'UNPARSED_REVIEW_ITEM' -or -not $item.id) { continue }
        $canonical = ("$($item.category)|$($item.anchor)|$($item.evidence)|$($item.action)".ToLowerInvariant() -replace '[^\p{L}\p{N}]+',' ' -replace '\s+',' ').Trim()
        $signature = Get-TextSha256 $canonical
        $found = @($existingLedger | Where-Object { $_.signature -eq $signature }) | Select-Object -First 1
        if ($found) { $found.last_seen_round = $roundId; continue }
        $existingLedger += [pscustomobject][ordered]@{
            issue_id=('ISSUE-{0:D3}' -f ($existingLedger.Count + 1));signature=$signature
            first_seen_round=$roundId;last_seen_round=$roundId;status='open'
            severity=$item.severity;category=$item.category;anchor=$item.anchor
            issue=$item.evidence;required_action=$item.action;resolution_note='';change_set_hash='';approval_time='';responsibility='';rollback_info=''
        }
    }
}
New-Item -ItemType Directory -Path (Split-Path $ledgerPath -Parent) -Force | Out-Null
$ledgerContent = ($existingLedger | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join [Environment]::NewLine
[IO.File]::WriteAllText($ledgerPath, $ledgerContent + $(if($ledgerContent){[Environment]::NewLine}else{''}), [Text.UTF8Encoding]::new($false))
$unresolvedMustFix = @($existingLedger | Where-Object { $_.status -eq 'open' -and $_.severity -eq 'MUST_FIX' }).Count
$codexReadRaw = ($Mode -like '*Deep' -and (@($deepseekState) | Where-Object { $_.format_status -ne 'valid' }).Count -gt 0)
$costFeatures = @('normalized_only','exact_review_cache','isolation_cache')
if ($compressionEnabled) { $costFeatures += 'compressed_packet' }
if ($Mode -like '*Normal') { $costFeatures += 'must_fix_only' }
if ($readOnlyProjectRoot) { $costFeatures += 'on_demand_project_read' }
$manifest = [ordered]@{
    timestamp = (Get-Date).ToString('o')
    review_type = $ReviewType
    mode = $Mode
    review_stage = $Stage
    review_scope = if($DeepSeekPacketPath){'focused_packet'}else{'complete_packet'}
    preflight_status = $preflight.Status
    reviewers_called = $true
    missing_required_fields = $preflight.Missing
    packet_sha256 = $originalPacketHash
    original_packet_sha256 = $originalPacketHash
    compressed_packet_sha256 = $effectivePacketHash
    effective_packet_sha256 = $effectivePacketHash
    packet_path_used = $packetPathUsed
    compressed_packet_used = ($packetPathUsed -ne $originalPacketPath)
    compression_enabled = $compressionEnabled
    original_characters = $originalPacketCharacters
    compressed_characters = $packet.Length
    compression_ratio = $compressionRatio
    reviewer_specific_packet = [bool]($DeepSeekPacketPath)
    project_read_access = [bool]$readOnlyProjectRoot
    project_read_fingerprint = $readOnlyProjectFingerprint
    project_read_policy = if($readOnlyProjectRoot){'Read,Glob,Grep only; packet-first and on-demand'}else{'packet only'}
    evidence_files = @($evidenceFiles | ForEach-Object {[ordered]@{relative_path=$_.relative_path;sha256=$_.sha256;characters=$_.characters}})
    evidence_file_count = @($evidenceFiles).Count
    evidence_characters = (@($evidenceFiles|Measure-Object characters -Sum).Sum)
    evidence_file_limit = 6
    evidence_character_limit = 25000
    deepseek_packet_sha256 = $deepseekPacketHash
    codex_draft_sha256 = if($codexDraft){Get-TextSha256 $codexDraft}else{''}
    compression_strategy = $CompressionStrategy
    input_characters = $deepseekMaterial.Length
    base_input_characters = $material.Length
    maximum_input_characters = $MaximumInputCharacters
    reviewer_input_limit = $ReviewerInputLimit
    reviewer_allowed_tools = if($readOnlyProjectRoot){@('Read','Glob','Grep')}else{@()}
    reviewers = [ordered]@{ deepseek_v4_pro = $deepseekState }
    review_cache_hit = [bool]($deepseekState.review_cache_hit)
    isolation_cached = [ordered]@{deepseek_v4_pro=$deepseekState.isolation_cached}
    lean_must_fix_only = ($Mode -like '*Normal')
    auto_format_retry = $false
    raw_read_by_codex = $codexReadRaw
    codex_read_raw = $codexReadRaw
    codex_read_raw_reason = if($codexReadRaw){'Deep mode with degraded normalized output'}else{''}
    issue_ledger_path = $ledgerPath
    unresolved_must_fix_count = $unresolvedMustFix
    cost_saving_features = $costFeatures
    adjudication_status = $adjudicationStatus
    authorization_status = 'pending'
}
$manifestPath = Join-Path $reviewDirectory 'roundtable-manifest.json'
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

Write-Output "Roundtable status: $adjudicationStatus"
Write-Output "DeepSeek v4 Pro $Stage isolation: $($deepseekState.isolation_status); format: $($deepseekState.format_status)"
if ($deepseekState.error) { Write-Output "DeepSeek unavailable: $($deepseekState.error)" }
Write-Output "Manifest: $manifestPath"
if ($deepseekState.raw_output_path) { Write-Output "DeepSeek raw: $($deepseekState.raw_output_path)" }
if ($deepseekState.normalized_output_path) { Write-Output "DeepSeek normalized: $($deepseekState.normalized_output_path)" }
