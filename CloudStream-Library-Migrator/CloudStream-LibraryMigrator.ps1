<#
.SYNOPSIS
    Migrates CloudStream Library bookmarks from YFlix to CineStream.

.DESCRIPTION
    Reads a CloudStream Android / Android TV backup and provides four actions:

      Analyze   - Inspect the source backup and create NeedsReview.csv only when
                  manual metadata is required.
      Build     - Create one validated FINAL_CLEANED.txt directly from the
                  untouched source backup.
      Verify    - Compare an original backup with a migrated backup and confirm
                  that each original Library record is accounted for.
      Tombstone - Create REMOVE_OLD_YFLIX.txt to neutralize stale YFlix records
                  that may survive CloudStream's merge-style restore behavior.

    The tested provider path is YFlix -> CineStream. The general backup,
    duplicate-detection, state-preservation, reporting, and verification logic is
    reusable, but provider-specific URL, poster, identifier, and cleanup logic
    must be adapted before using this utility with other extensions.

.NOTES
    Public-release build.
    Windows PowerShell 5.1 compatible.

    Privacy:
      - This script does not contain account credentials, cookies, user names,
        device names, personal file paths, or raw backup data.
      - CloudStream backup files themselves may contain sensitive configuration
        or session data. Do not publish raw backups without reviewing/redacting
        them first.

    Provider assumptions currently implemented:
      Source provider: YFlix
      Target provider: CineStream
      CineStream URL:  {"id":"tt########","type":"movie"}
      Bookmark ID:     Java/Kotlin String.hashCode() of the exact provider URL
#>

[CmdletBinding()]
param(
    [ValidateSet("Analyze", "Build", "Verify", "Tombstone")]
    [string]$Action,

    [string]$OriginalBackup,

    [string]$FinalBackup,

    [string]$ManualMappings,

    [string]$OutputDir,

    [switch]$DetailedReport,

    [switch]$Overwrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptVersion = "1.1.0"

# ============================================================================
# CORE FILE AND DATA HELPERS
# ============================================================================

function Clean-UserPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    return $Path.Trim().Trim('"').Trim("'")
}

function Resolve-RequiredFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Label
    )

    $Path = Clean-UserPath $Path

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label not found: $Path"
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Ensure-OutputDirectory {
    param(
        [Parameter(Mandatory=$true)][string]$OriginalPath,
        [string]$RequestedOutputDir
    )

    if ([string]::IsNullOrWhiteSpace($RequestedOutputDir)) {
        $parent = Split-Path -Parent $OriginalPath
        $RequestedOutputDir = Join-Path $parent "CloudStreamMigration"
    }

    $RequestedOutputDir = Clean-UserPath $RequestedOutputDir

    if (-not (Test-Path -LiteralPath $RequestedOutputDir -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $RequestedOutputDir -Force
    }

    return (Resolve-Path -LiteralPath $RequestedOutputDir).Path
}

function Assert-CanWriteFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [switch]$AllowOverwrite
    )

    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and -not $AllowOverwrite) {
        throw "Output file already exists: $Path`nUse -Overwrite if you intentionally want to replace it."
    }
}

function ConvertTo-Hashtable {
    param($Object)

    $table = @{}
    if ($null -eq $Object) {
        return $table
    }

    foreach ($p in $Object.PSObject.Properties) {
        $table[$p.Name] = $p.Value
    }

    return $table
}

function Read-CloudStreamBackup {
    param([Parameter(Mandatory=$true)][string]$Path)

    $resolved = Resolve-RequiredFile -Path $Path -Label "CloudStream backup"
    $raw = Get-Content -LiteralPath $resolved -Raw -Encoding UTF8
    $backup = $raw | ConvertFrom-Json

    if ($null -eq $backup.datastore -or
        $null -eq $backup.datastore._String) {
        throw "Unsupported CloudStream backup: datastore._String is missing."
    }

    return [pscustomobject]@{
        Path   = $resolved
        Backup = $backup
        Store  = ConvertTo-Hashtable -Object $backup.datastore._String
    }
}

function Write-CloudStreamBackup {
    param(
        [Parameter(Mandatory=$true)]$Backup,
        [Parameter(Mandatory=$true)][hashtable]$Store,
        [Parameter(Mandatory=$true)][string]$Path
    )

    $Backup.datastore._String = $Store

    $json = $Backup | ConvertTo-Json -Depth 100 -Compress
    [IO.File]::WriteAllText(
        $Path,
        $json,
        [Text.UTF8Encoding]::new($false)
    )

    # Validate the generated JSON immediately after writing it.
    $null = (
        Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
        ConvertFrom-Json
    )
}

# ============================================================================
# CLOUDSTREAM DATA AND PROVIDER HELPERS
# ============================================================================

function Get-JavaStringHashCode {
    param([Parameter(Mandatory=$true)][string]$Text)

    # Java/Kotlin String.hashCode():
    # h = 31*h + UTF-16 code unit, with 32-bit wraparound each iteration.
    [uint64]$h = 0
    [uint64]$mod32 = 4294967296

    foreach ($ch in $Text.ToCharArray()) {
        [uint64]$codeUnit = [uint16][char]$ch
        $h = (([uint64]31 * $h) + $codeUnit) % $mod32
    }

    if ($h -ge [uint64]2147483648) {
        return ([int64]$h - [int64]4294967296)
    }

    return [int64]$h
}

# Verify the hash implementation with a provider-neutral test string.
# Expected value was calculated using Java/Kotlin String.hashCode().
$HashSelfTestText = "cloudstream-migrator-self-test"
$HashSelfTestExpected = -1527676709
$HashSelfTestActual = Get-JavaStringHashCode -Text $HashSelfTestText

if ($HashSelfTestActual -ne $HashSelfTestExpected) {
    throw "Java/Kotlin hash self-test failed. Expected $HashSelfTestExpected, got $HashSelfTestActual."
}

# ----------------------------------------------------------------------------
# PROVIDER-SPECIFIC TARGET ADAPTER: CINESTREAM
#
# These functions describe how a stable content identifier becomes a bookmark
# understood by the target extension. To adapt the utility to another target
# provider, determine from sanitized sample bookmarks:
#
#   1. Which stable identifier the provider uses (IMDb, TMDb, provider ID, etc.).
#   2. The exact value CloudStream stores in the bookmark "url" field.
#   3. How the provider's bookmark "id" is derived.
#   4. How poster URLs and movie/TV types are represented.
#
# Do not assume another provider uses CineStream's IMDb-based format or the same
# hash rule until it has been verified from real sample records.
# ----------------------------------------------------------------------------

function New-CineStreamUrl {
    param(
        [Parameter(Mandatory=$true)][string]$ImdbId,
        [Parameter(Mandatory=$true)]
        [ValidateSet("movie", "tv")]
        [string]$TargetType
    )

    # Property order is intentional because CloudStream hashes the exact string.
    $ordered = [ordered]@{
        id   = $ImdbId
        type = $TargetType
    }

    return ($ordered | ConvertTo-Json -Compress)
}

function Get-CineStreamPosterUrl {
    param([Parameter(Mandatory=$true)][string]$ImdbId)

    return "https://wsrv.nl/?url=https://images.metahub.space/poster/small/$ImdbId/img"
}

function Get-ImdbIdFromBookmark {
    param($Bookmark)

    try {
        if ($null -eq $Bookmark) {
            return $null
        }

        $syncProp = $Bookmark.PSObject.Properties["syncData"]
        if ($null -eq $syncProp -or $null -eq $syncProp.Value) {
            return $null
        }

        $simklProp = $syncProp.Value.PSObject.Properties["simkl"]
        if ($null -eq $simklProp) {
            return $null
        }

        $simkl = [string]$simklProp.Value
        if ([string]::IsNullOrWhiteSpace($simkl)) {
            return $null
        }

        $parsed = $simkl | ConvertFrom-Json
        $imdbProp = $parsed.PSObject.Properties["Imdb"]

        if ($null -eq $imdbProp) {
            return $null
        }

        $imdb = [string]$imdbProp.Value

        if ($imdb -match '^tt\d+$') {
            return $imdb
        }
    }
    catch {}

    return $null
}

function Ensure-BookmarkImdb {
    param(
        [Parameter(Mandatory=$true)]$Bookmark,
        [Parameter(Mandatory=$true)][string]$ImdbId
    )

    $syncProp = $Bookmark.PSObject.Properties["syncData"]

    if ($null -eq $syncProp) {
        $Bookmark | Add-Member `
            -NotePropertyName syncData `
            -NotePropertyValue ([pscustomobject]@{})
    }
    elseif ($null -eq $Bookmark.syncData) {
        $Bookmark.syncData = [pscustomobject]@{}
    }

    $simklValue = (
        [ordered]@{ Imdb = $ImdbId } |
        ConvertTo-Json -Compress
    )

    $simklProp = $Bookmark.syncData.PSObject.Properties["simkl"]

    if ($null -ne $simklProp) {
        $Bookmark.syncData.simkl = $simklValue
    }
    else {
        $Bookmark.syncData |
            Add-Member -NotePropertyName simkl -NotePropertyValue $simklValue
    }
}

function Get-ActiveBookmarks {
    param([Parameter(Mandatory=$true)][hashtable]$Store)

    $items = @()

    foreach ($key in @($Store.Keys)) {
        if ($key -notlike "0/result_watch_state_data/*") {
            continue
        }

        $raw = [string]$Store[$key]

        if ([string]::IsNullOrWhiteSpace($raw) -or $raw -eq "null") {
            continue
        }

        try {
            $bookmark = $raw | ConvertFrom-Json

            if ($null -eq $bookmark) {
                continue
            }

            $items += [pscustomobject]@{
                Key      = $key
                Bookmark = $bookmark
            }
        }
        catch {
            Write-Warning "Could not parse active bookmark key $key. It will be ignored by analysis."
        }
    }

    return @($items)
}

function Get-WatchState {
    param(
        [Parameter(Mandatory=$true)][hashtable]$Store,
        [Parameter(Mandatory=$true)][int]$Id
    )

    $key = "0/result_watch_state/$Id"

    if ($Store.ContainsKey($key)) {
        return [string]$Store[$key]
    }

    return ""
}

function Get-StatusName {
    param([string]$State)

    # Current CloudStream WatchType internal IDs.
    switch ($State) {
        "0" { return "Watching" }
        "1" { return "Completed" }
        "2" { return "OnHold" }
        "3" { return "Dropped" }
        "4" { return "PlanToWatch" }
        "5" { return "None" }
        default { return "Unknown($State)" }
    }
}

function Copy-AuxiliaryState {
    param(
        [Parameter(Mandatory=$true)][hashtable]$Store,
        [Parameter(Mandatory=$true)][int]$OldId,
        [Parameter(Mandatory=$true)][int]$NewId,
        [switch]$DoNotOverwriteDestination
    )

    $prefixes = @(
        "0/result_episode/",
        "0/result_season/",
        "0/result_dub/",
        "0/video_pos_dur/",
        "0/result_resume_watching_2/"
    )

    foreach ($prefix in $prefixes) {
        $oldKey = "$prefix$OldId"
        $newKey = "$prefix$NewId"

        if (-not $Store.ContainsKey($oldKey)) {
            continue
        }

        if (-not $DoNotOverwriteDestination -or
            -not $Store.ContainsKey($newKey)) {
            $Store[$newKey] = $Store[$oldKey]
        }

        $null = $Store.Remove($oldKey)
    }
}

function Remove-ActiveBookmark {
    param(
        [Parameter(Mandatory=$true)][hashtable]$Store,
        [Parameter(Mandatory=$true)][int]$Id
    )

    $null = $Store.Remove("0/result_watch_state/$Id")
    $null = $Store.Remove("0/result_watch_state_data/$Id")
}

function Find-BookmarksByImdb {
    param(
        [Parameter(Mandatory=$true)][hashtable]$Store,
        [Parameter(Mandatory=$true)][string]$ImdbId,
        [Nullable[int]]$ExcludeId
    )

    $matches = @()

    foreach ($entry in @(Get-ActiveBookmarks -Store $Store)) {
        $bookmark = $entry.Bookmark
        $id = [int]$bookmark.id

        if ($null -ne $ExcludeId -and $id -eq $ExcludeId.Value) {
            continue
        }

        $imdb = Get-ImdbIdFromBookmark -Bookmark $bookmark

        if ($imdb -eq $ImdbId) {
            $matches += $entry
        }
    }

    return @($matches)
}

function Select-PreferredExistingBookmark {
    param([Parameter(Mandatory=$true)][object[]]$Matches)

    if ($Matches.Count -eq 0) {
        return $null
    }

    # Prefer:
    # 1. a working non-YFlix provider
    # 2. most recently updated bookmark
    # 3. most recently bookmarked record
    #
    # The destination provider is intentionally not restricted here. Any
    # existing non-YFlix bookmark with the same IMDb ID may be retained instead
    # of creating a duplicate CineStream bookmark.
    $sortable = foreach ($entry in $Matches) {
        $b = $entry.Bookmark

        [int64]$updated = 0
        [int64]$bookmarked = 0

        try { $updated = [int64]$b.latestUpdatedTime } catch {}
        try { $bookmarked = [int64]$b.bookmarkedTime } catch {}

        $provider = [string]$b.apiName
        $providerScore = 1

        if ($provider -eq "YFlix") {
            $providerScore = 0
        }

        [pscustomobject]@{
            Entry         = $entry
            ProviderScore = $providerScore
            Updated       = $updated
            Bookmarked    = $bookmarked
        }
    }

    $winner = @(
        $sortable |
        Sort-Object `
            @{ Expression = "ProviderScore"; Descending = $true },
            @{ Expression = "Updated"; Descending = $true },
            @{ Expression = "Bookmarked"; Descending = $true }
    )[0]

    return $winner.Entry
}

function Normalize-Title {
    param([string]$Title)

    if ([string]::IsNullOrWhiteSpace($Title)) {
        return ""
    }

    $s = $Title.ToLowerInvariant()
    $s = $s -replace '&', ' and '
    $s = $s -replace '[^a-z0-9]+', ' '
    $s = $s -replace '\s+', ' '

    return $s.Trim()
}

# ============================================================================
# MANUAL REVIEW AND MAPPING
# ============================================================================

function Import-ManualMappings {
    param([string]$Path)

    $map = @{}

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $map
    }

    $resolved = Resolve-RequiredFile -Path $Path -Label "Manual mappings CSV"

    foreach ($row in @(Import-Csv -LiteralPath $resolved)) {
        $oldIdProp = $row.PSObject.Properties["OldId"]

        if ($null -eq $oldIdProp) {
            continue
        }

        $oldId = [string]$oldIdProp.Value

        if ([string]::IsNullOrWhiteSpace($oldId)) {
            continue
        }

        $manualImdb = ""
        $targetType = ""
        $correctedName = ""
        $correctedYear = ""

        $p = $row.PSObject.Properties["ManualImdbId"]
        if ($null -ne $p) { $manualImdb = [string]$p.Value }

        $p = $row.PSObject.Properties["TargetType"]
        if ($null -ne $p) { $targetType = ([string]$p.Value).ToLowerInvariant() }

        $p = $row.PSObject.Properties["CorrectedName"]
        if ($null -ne $p) { $correctedName = [string]$p.Value }

        $p = $row.PSObject.Properties["CorrectedYear"]
        if ($null -ne $p) { $correctedYear = [string]$p.Value }

        $map[$oldId] = [pscustomobject]@{
            OldId         = $oldId
            ManualImdbId  = $manualImdb.Trim()
            TargetType    = $targetType.Trim()
            CorrectedName = $correctedName.Trim()
            CorrectedYear = $correctedYear.Trim()
        }
    }

    return $map
}

function Get-MigrationDecision {
    param(
        [Parameter(Mandatory=$true)]$Bookmark,
        [hashtable]$ManualMap
    )

    $oldId = [string][int]$Bookmark.id
    $oldImdb = Get-ImdbIdFromBookmark -Bookmark $Bookmark
    $manual = $null

    if ($null -ne $ManualMap -and $ManualMap.ContainsKey($oldId)) {
        $manual = $ManualMap[$oldId]
    }

    $finalImdb = $oldImdb
    $targetType = $null
    $correctedName = ""
    $correctedYear = ""
    $source = "Automatic"

    if ($null -ne $manual) {
        $source = "ManualCSV"

        if ($manual.ManualImdbId -match '^tt\d+$') {
            $finalImdb = $manual.ManualImdbId
        }

        if ($manual.TargetType -in @("movie", "tv")) {
            $targetType = $manual.TargetType
        }

        $correctedName = $manual.CorrectedName
        $correctedYear = $manual.CorrectedYear
    }

    if ($null -eq $targetType) {
        if ([string]$Bookmark.type -eq "Movie") {
            $targetType = "movie"
        }
    }

    $reasons = @()

    if ($null -eq $finalImdb -or $finalImdb -notmatch '^tt\d+$') {
        $reasons += "Missing or invalid IMDb ID"
    }

    if ($targetType -notin @("movie", "tv")) {
        $reasons += "Source type '$($Bookmark.type)' requires target-type confirmation"
    }

    return [pscustomobject]@{
        Ready         = ($reasons.Count -eq 0)
        Reasons       = $reasons
        ImdbId        = $finalImdb
        TargetType    = $targetType
        CorrectedName = $correctedName
        CorrectedYear = $correctedYear
        MappingSource = $source
    }
}

function Get-NeedsReviewRows {
    param(
        [Parameter(Mandatory=$true)][hashtable]$Store,
        [hashtable]$ManualMap
    )

    $rows = @()

    foreach ($entry in @(Get-ActiveBookmarks -Store $Store)) {
        $b = $entry.Bookmark

        if ([string]$b.apiName -ne "YFlix") {
            continue
        }

        $decision = Get-MigrationDecision -Bookmark $b -ManualMap $ManualMap

        if ($decision.Ready) {
            continue
        }

        $currentImdb = Get-ImdbIdFromBookmark -Bookmark $b
        $currentImdbText = ""
        $defaultType = ""

        if ($null -ne $currentImdb) {
            $currentImdbText = [string]$currentImdb
        }

        if ([string]$b.type -eq "Movie") {
            $defaultType = "movie"
        }

        $rows += [pscustomobject]@{
            Name          = [string]$b.name
            Year          = [string]$b.year
            OldId         = [int]$b.id
            OldType       = [string]$b.type
            Reason        = ($decision.Reasons -join "; ")
            CurrentImdbId = $currentImdbText
            ManualImdbId  = ""
            TargetType    = $defaultType
            CorrectedName = ""
            CorrectedYear = ""
        }
    }

    return @($rows)
}

# ============================================================================
# SOURCE-PROVIDER CLEANUP
# ============================================================================

# ----------------------------------------------------------------------------
# PROVIDER-SPECIFIC SOURCE CLEANUP: YFLIX
#
# The functions in this section remove or neutralize YFlix-specific cache and
# preference keys. When adapting the utility to another broken source provider,
# inventory that provider's saved keys from a sanitized backup before changing
# this cleanup logic.
# ----------------------------------------------------------------------------

function Remove-YFlixCaches {
    param([Parameter(Mandatory=$true)][hashtable]$Store)

    $removed = 0

    foreach ($key in @($Store.Keys)) {
        if ($key -notlike "download_header_cache/*" -and
            $key -notlike "BACKUP_download_header_cache/*") {
            continue
        }

        try {
            $raw = [string]$Store[$key]

            if ($raw -eq "null") {
                continue
            }

            $obj = $raw | ConvertFrom-Json

            if ([string]$obj.apiName -eq "YFlix") {
                $null = $Store.Remove($key)
                $removed++
            }
        }
        catch {}
    }

    return $removed
}

function Repair-ProviderPreferences {
    param([Parameter(Mandatory=$true)][hashtable]$Store)

    $key = "0/search_pref_providers"

    if (-not $Store.ContainsKey($key)) {
        return $false
    }

    try {
        $parsed = $Store[$key] | ConvertFrom-Json
        $providers = @()

        if ($null -ne $parsed) {
            $valueProp = $parsed.PSObject.Properties["value"]

            if ($null -ne $valueProp) {
                $providers = @($valueProp.Value)
            }
            else {
                $providers = @($parsed)
            }
        }

        [object[]]$clean = @(
            $providers |
            ForEach-Object { [string]$_ } |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_) -and
                $_ -notmatch '^(?i)yflix$'
            } |
            Select-Object -Unique
        )

        $Store[$key] = ConvertTo-Json -InputObject $clean -Compress
        return $true
    }
    catch {
        throw "Could not repair 0/search_pref_providers: $($_.Exception.Message)"
    }
}

function Apply-YFlixGeneralCleanup {
    param([Parameter(Mandatory=$true)][hashtable]$Store)

    $result = [ordered]@{
        CacheRecordsRemoved      = 0
        ServerSettingRemoved     = $false
        ProviderPreferenceFixed  = $false
    }

    $result.CacheRecordsRemoved = Remove-YFlixCaches -Store $Store

    if ($Store.ContainsKey("Yflix_CURRENT_SERVER")) {
        $null = $Store.Remove("Yflix_CURRENT_SERVER")
        $result.ServerSettingRemoved = $true
    }

    $result.ProviderPreferenceFixed = Repair-ProviderPreferences -Store $Store

    return [pscustomobject]$result
}

# ============================================================================
# ACTION: ANALYZE
# ============================================================================

function Invoke-Analyze {
    param(
        [Parameter(Mandatory=$true)][string]$BackupPath,
        [string]$RequestedOutputDir,
        [string]$MappingsPath,
        [switch]$AllowOverwrite,
        [switch]$WriteDetailed
    )

    $data = Read-CloudStreamBackup -Path $BackupPath
    $outDir = Ensure-OutputDirectory `
        -OriginalPath $data.Path `
        -RequestedOutputDir $RequestedOutputDir

    $manualMap = @{}
    if (-not [string]::IsNullOrWhiteSpace($MappingsPath)) {
        $manualMap = Import-ManualMappings -Path $MappingsPath
    }

    $bookmarks = @(Get-ActiveBookmarks -Store $data.Store)
    $yflix = @($bookmarks | Where-Object { [string]$_.Bookmark.apiName -eq "YFlix" })

    $providerCounts = @{}
    foreach ($entry in $bookmarks) {
        $provider = [string]$entry.Bookmark.apiName
        if (-not $providerCounts.ContainsKey($provider)) {
            $providerCounts[$provider] = 0
        }
        $providerCounts[$provider]++
    }

    $autoReady = 0
    $existingMatches = 0
    $reviewRows = @()

    foreach ($entry in $yflix) {
        $b = $entry.Bookmark
        $decision = Get-MigrationDecision -Bookmark $b -ManualMap $manualMap

        if ($decision.Ready) {
            $autoReady++

            $matches = @(
                Find-BookmarksByImdb `
                    -Store $data.Store `
                    -ImdbId $decision.ImdbId `
                    -ExcludeId ([int]$b.id) |
                Where-Object { [string]$_.Bookmark.apiName -ne "YFlix" }
            )

            if ($matches.Count -gt 0) {
                $existingMatches++
            }
        }
    }

    $reviewRows = @(Get-NeedsReviewRows -Store $data.Store -ManualMap $manualMap)

    Write-Host ""
    Write-Host "========== CLOUDSTREAM MIGRATION ANALYSIS =========="
    Write-Host "Script version           : $ScriptVersion"
    Write-Host "Original backup          : $($data.Path)"
    Write-Host "Active Library records   : $($bookmarks.Count)"
    Write-Host "YFlix records            : $($yflix.Count)"
    Write-Host "Ready to migrate         : $autoReady"
    Write-Host "Existing provider match  : $existingMatches"
    Write-Host "Needs manual review      : $($reviewRows.Count)"
    Write-Host ""

    Write-Host "Provider counts:"
    foreach ($provider in ($providerCounts.Keys | Sort-Object)) {
        Write-Host ("  {0,-18} {1}" -f $provider, $providerCounts[$provider])
    }

    $reviewPath = Join-Path $outDir "NeedsReview.csv"

    if ($reviewRows.Count -gt 0) {
        if ((Test-Path -LiteralPath $reviewPath -PathType Leaf) -and
            -not $AllowOverwrite) {
            Write-Host ""
            Write-Host "NeedsReview.csv already exists and was preserved:"
            Write-Host "  $reviewPath"
            Write-Host "Use -Overwrite only if you intentionally want a fresh copy."
        }
        else {
            $reviewRows |
                Export-Csv -LiteralPath $reviewPath -NoTypeInformation -Encoding UTF8

            Write-Host ""
            Write-Host "Manual-review file:"
            Write-Host "  $reviewPath"
        }
    }
    else {
        Write-Host ""
        Write-Host "No manual-review file is required."
    }

    if ($WriteDetailed) {
        $analysisPath = Join-Path $outDir "Analysis.csv"
        Assert-CanWriteFile -Path $analysisPath -AllowOverwrite:$AllowOverwrite

        $rows = foreach ($entry in $bookmarks) {
            $b = $entry.Bookmark

            [pscustomobject]@{
                Name     = [string]$b.name
                Year     = [string]$b.year
                Id       = [int]$b.id
                Provider = [string]$b.apiName
                Type     = [string]$b.type
                ImdbId   = [string](Get-ImdbIdFromBookmark -Bookmark $b)
                Status   = Get-StatusName (
                    Get-WatchState -Store $data.Store -Id ([int]$b.id)
                )
            }
        }

        $rows |
            Export-Csv -LiteralPath $analysisPath -NoTypeInformation -Encoding UTF8

        Write-Host "Detailed analysis:"
        Write-Host "  $analysisPath"
    }

    Write-Host ""
    Write-Host "No backup data was changed."
}

# ============================================================================
# ACTION: BUILD
# ============================================================================

function Invoke-Build {
    param(
        [Parameter(Mandatory=$true)][string]$BackupPath,
        [string]$RequestedOutputDir,
        [string]$MappingsPath,
        [switch]$AllowOverwrite,
        [switch]$WriteDetailed
    )

    $data = Read-CloudStreamBackup -Path $BackupPath
    $outDir = Ensure-OutputDirectory `
        -OriginalPath $data.Path `
        -RequestedOutputDir $RequestedOutputDir

    $finalPath = Join-Path $outDir "FINAL_CLEANED.txt"
    $summaryPath = Join-Path $outDir "MigrationSummary.txt"
    $auditPath = Join-Path $outDir "MigrationAudit.csv"
    $reviewPath = Join-Path $outDir "NeedsReview.csv"

    Assert-CanWriteFile -Path $finalPath -AllowOverwrite:$AllowOverwrite
    Assert-CanWriteFile -Path $summaryPath -AllowOverwrite:$AllowOverwrite

    if ($WriteDetailed) {
        Assert-CanWriteFile -Path $auditPath -AllowOverwrite:$AllowOverwrite
    }

    # If no mapping path was explicitly given, automatically use the stable
    # NeedsReview.csv in the output folder when it exists.
    if ([string]::IsNullOrWhiteSpace($MappingsPath) -and
        (Test-Path -LiteralPath $reviewPath -PathType Leaf)) {
        $MappingsPath = $reviewPath
    }

    $manualMap = Import-ManualMappings -Path $MappingsPath

    $originalBookmarks = @(Get-ActiveBookmarks -Store $data.Store)
    $originalCount = $originalBookmarks.Count

    $originalById = @{}
    $originalWatchStateById = @{}

    foreach ($entry in $originalBookmarks) {
        $originalId = [int]$entry.Bookmark.id
        $originalById[[string]$originalId] = $entry.Bookmark
        $originalWatchStateById[[string]$originalId] =
            Get-WatchState -Store $data.Store -Id $originalId
    }

    # Stop before modifying the in-memory backup when manual review is incomplete.
    $unresolved = @(Get-NeedsReviewRows -Store $data.Store -ManualMap $manualMap)

    if ($unresolved.Count -gt 0) {
        if (-not (Test-Path -LiteralPath $reviewPath -PathType Leaf) -or $AllowOverwrite) {
            $unresolved |
                Export-Csv -LiteralPath $reviewPath -NoTypeInformation -Encoding UTF8
        }

        Write-Host ""
        Write-Host "BUILD STOPPED: $($unresolved.Count) YFlix item(s) still need review."
        Write-Host "Complete:"
        Write-Host "  $reviewPath"
        Write-Host "Then rerun Build."
        return
    }

    $store = $data.Store
    $mappingRows = @()
    $consolidatedCount = 0
    $convertedCount = 0

    # Preserve each original non-YFlix record as its own initial destination.
    foreach ($entry in $originalBookmarks) {
        $b = $entry.Bookmark

        if ([string]$b.apiName -eq "YFlix") {
            continue
        }

        $mappingRows += [pscustomobject]@{
            OriginalName     = [string]$b.name
            OriginalYear     = [string]$b.year
            OriginalProvider = [string]$b.apiName
            OriginalId       = [int]$b.id
            OriginalStatus   = Get-StatusName (
                Get-WatchState -Store $store -Id ([int]$b.id)
            )
            ImdbId           = [string](Get-ImdbIdFromBookmark -Bookmark $b)
            FinalName        = [string]$b.name
            FinalProvider    = [string]$b.apiName
            FinalId          = [int]$b.id
            FinalStatus      = ""
            Action           = "Preserved"
            MappingSource    = "Original"
            Notes            = ""
        }
    }

    $yflixEntries = @(
        $originalBookmarks |
        Where-Object { [string]$_.Bookmark.apiName -eq "YFlix" }
    )

    foreach ($entry in $yflixEntries) {
        $old = $entry.Bookmark
        $oldId = [int]$old.id
        $oldState = Get-WatchState -Store $store -Id $oldId

        if ([string]::IsNullOrWhiteSpace($oldState)) {
            throw "YFlix bookmark '$($old.name)' (ID $oldId) has no watch-state key. Build aborted rather than guessing."
        }

        $decision = Get-MigrationDecision -Bookmark $old -ManualMap $manualMap

        if (-not $decision.Ready) {
            throw "Internal error: unresolved migration decision reached Build for '$($old.name)'."
        }

        $imdb = $decision.ImdbId
        $targetType = $decision.TargetType

        $nonYflixMatches = @(
            Find-BookmarksByImdb `
                -Store $store `
                -ImdbId $imdb `
                -ExcludeId $oldId |
            Where-Object { [string]$_.Bookmark.apiName -ne "YFlix" }
        )

        $existing = Select-PreferredExistingBookmark -Matches $nonYflixMatches

        if ($null -ne $existing) {
            $dest = $existing.Bookmark
            $destId = [int]$dest.id

            # Keep the existing destination bookmark/status. Fill only missing
            # auxiliary state from the old YFlix record.
            Copy-AuxiliaryState `
                -Store $store `
                -OldId $oldId `
                -NewId $destId `
                -DoNotOverwriteDestination

            Remove-ActiveBookmark -Store $store -Id $oldId

            $consolidatedCount++

            $mappingRows += [pscustomobject]@{
                OriginalName     = [string]$old.name
                OriginalYear     = [string]$old.year
                OriginalProvider = "YFlix"
                OriginalId       = $oldId
                OriginalStatus   = Get-StatusName $oldState
                ImdbId           = $imdb
                FinalName        = [string]$dest.name
                FinalProvider    = [string]$dest.apiName
                FinalId          = $destId
                FinalStatus      = ""
                Action           = "ExistingMatchKept"
                MappingSource    = $decision.MappingSource
                Notes            = "Consolidated into existing non-YFlix bookmark with the same IMDb ID."
            }

            continue
        }

        $newUrl = New-CineStreamUrl -ImdbId $imdb -TargetType $targetType
        $newId = [int](Get-JavaStringHashCode -Text $newUrl)
        $destinationKey = "0/result_watch_state_data/$newId"

        if ($store.ContainsKey($destinationKey)) {
            try {
                $destination = [string]$store[$destinationKey] | ConvertFrom-Json
                $destinationImdb = Get-ImdbIdFromBookmark -Bookmark $destination

                if ([string]$destination.apiName -ne "CineStream" -or
                    $destinationImdb -ne $imdb) {
                    throw "Destination hash collision: $newId already belongs to '$($destination.name)' / $($destination.apiName)."
                }

                # If the ID is already the correct CineStream bookmark, treat it
                # as an existing match rather than overwriting.
                Copy-AuxiliaryState `
                    -Store $store `
                    -OldId $oldId `
                    -NewId $newId `
                    -DoNotOverwriteDestination

                Remove-ActiveBookmark -Store $store -Id $oldId
                $consolidatedCount++

                $mappingRows += [pscustomobject]@{
                    OriginalName     = [string]$old.name
                    OriginalYear     = [string]$old.year
                    OriginalProvider = "YFlix"
                    OriginalId       = $oldId
                    OriginalStatus   = Get-StatusName $oldState
                    ImdbId           = $imdb
                    FinalName        = [string]$destination.name
                    FinalProvider    = "CineStream"
                    FinalId          = $newId
                    FinalStatus      = ""
                    Action           = "ExistingCineStreamKept"
                    MappingSource    = $decision.MappingSource
                    Notes            = "Destination CineStream bookmark already existed."
                }

                continue
            }
            catch {
                throw "Destination key $destinationKey exists but cannot be safely reused. $($_.Exception.Message)"
            }
        }

        # Clone source metadata and replace only the target-provider-specific fields.
        $new = $old | ConvertTo-Json -Depth 100 | ConvertFrom-Json

        $new.id = $newId
        $new.apiName = "CineStream"
        $new.url = $newUrl
        $new.posterUrl = Get-CineStreamPosterUrl -ImdbId $imdb

        if ($targetType -eq "movie") {
            $new.type = "Movie"
        }
        else {
            $new.type = "TvSeries"
        }

        if (-not [string]::IsNullOrWhiteSpace($decision.CorrectedName)) {
            $new.name = $decision.CorrectedName
        }

        if (-not [string]::IsNullOrWhiteSpace($decision.CorrectedYear)) {
            [int]$correctedYearNumber = 0

            if ([int]::TryParse(
                $decision.CorrectedYear,
                [ref]$correctedYearNumber
            )) {
                $new.year = $correctedYearNumber
            }
            else {
                throw "CorrectedYear '$($decision.CorrectedYear)' for '$($old.name)' is not a valid integer."
            }
        }

        Ensure-BookmarkImdb -Bookmark $new -ImdbId $imdb

        $store[$destinationKey] = (
            $new |
            ConvertTo-Json -Depth 100 -Compress
        )

        $store["0/result_watch_state/$newId"] = $oldState

        Copy-AuxiliaryState `
            -Store $store `
            -OldId $oldId `
            -NewId $newId

        Remove-ActiveBookmark -Store $store -Id $oldId

        $convertedCount++

        $mappingRows += [pscustomobject]@{
            OriginalName     = [string]$old.name
            OriginalYear     = [string]$old.year
            OriginalProvider = "YFlix"
            OriginalId       = $oldId
            OriginalStatus   = Get-StatusName $oldState
            ImdbId           = $imdb
            FinalName        = [string]$new.name
            FinalProvider    = "CineStream"
            FinalId          = $newId
            FinalStatus      = ""
            Action           = "Converted"
            MappingSource    = $decision.MappingSource
            Notes            = ""
        }
    }

    $cleanup = Apply-YFlixGeneralCleanup -Store $store

    # ------------------------------------------------------------------------
    # FINAL VALIDATION
    # ------------------------------------------------------------------------
    $finalBookmarks = @(Get-ActiveBookmarks -Store $store)
    $finalById = @{}

    foreach ($entry in $finalBookmarks) {
        $finalById[[string][int]$entry.Bookmark.id] = $entry.Bookmark
    }

    # Fill final status/name/provider from the actual post-build datastore.
    foreach ($row in $mappingRows) {
        $destKey = [string][int]$row.FinalId

        if ($finalById.ContainsKey($destKey)) {
            $dest = $finalById[$destKey]
            $row.FinalName = [string]$dest.name
            $row.FinalProvider = [string]$dest.apiName
            $row.FinalStatus = Get-StatusName (
                Get-WatchState -Store $store -Id ([int]$dest.id)
            )
        }
    }

    $errors = @()
    $warnings = @()

    $activeYFlix = @(
        $finalBookmarks |
        Where-Object { [string]$_.Bookmark.apiName -eq "YFlix" }
    )

    if ($activeYFlix.Count -ne 0) {
        $errors += "Active YFlix bookmarks remain: $($activeYFlix.Count)"
    }

    $badYFlixLinks = @(
        $finalBookmarks |
        Where-Object {
            ([string]$_.Bookmark.url -match '(?i)yflix\.to') -or
            ([string]$_.Bookmark.posterUrl -match '(?i)yflix\.to')
        }
    )

    if ($badYFlixLinks.Count -ne 0) {
        $errors += "Active Library records still contain yflix.to URLs/posters: $($badYFlixLinks.Count)"
    }

    $missingWatchState = @()

    foreach ($entry in $finalBookmarks) {
        $id = [int]$entry.Bookmark.id
        if (-not $store.ContainsKey("0/result_watch_state/$id")) {
            $missingWatchState += $entry.Bookmark
        }
    }

    if ($missingWatchState.Count -ne 0) {
        $errors += "Active bookmarks missing watch-state keys: $($missingWatchState.Count)"
    }

    # Duplicate IMDb groups.
    $imdbGroups = @{}

    foreach ($entry in $finalBookmarks) {
        $b = $entry.Bookmark
        $imdb = Get-ImdbIdFromBookmark -Bookmark $b

        if ($null -eq $imdb) {
            continue
        }

        if (-not $imdbGroups.ContainsKey($imdb)) {
            $imdbGroups[$imdb] = @()
        }

        $imdbGroups[$imdb] += $b
    }

    $duplicateImdbGroups = @(
        $imdbGroups.GetEnumerator() |
        Where-Object { @($_.Value).Count -gt 1 }
    )

    if ($duplicateImdbGroups.Count -gt 0) {
        foreach ($group in $duplicateImdbGroups) {
            $names = @(
                $group.Value |
                ForEach-Object { "$($_.name) [$($_.apiName)]" }
            ) -join ", "

            $errors += "Duplicate IMDb $($group.Key): $names"
        }
    }

    # CineStream hash consistency.
    $badHashes = @()

    foreach ($entry in $finalBookmarks) {
        $b = $entry.Bookmark

        if ([string]$b.apiName -ne "CineStream") {
            continue
        }

        $url = [string]$b.url
        $expected = [int](Get-JavaStringHashCode -Text $url)

        if ([int]$b.id -ne $expected) {
            $badHashes += $b
        }
    }

    if ($badHashes.Count -gt 0) {
        $errors += "CineStream bookmarks with invalid URL/hash IDs: $($badHashes.Count)"
    }

    # Every original record must map to an existing final record.
    $missingMappings = @()

    foreach ($row in $mappingRows) {
        $destKey = [string][int]$row.FinalId

        if (-not $finalById.ContainsKey($destKey)) {
            $missingMappings += $row
        }
    }

    if ($mappingRows.Count -ne $originalCount) {
        $errors += "Internal mapping count mismatch: mapped $($mappingRows.Count) of $originalCount original records."
    }

    if ($missingMappings.Count -gt 0) {
        $errors += "Original records whose mapped destination is missing: $($missingMappings.Count)"
    }

    $uniqueDestinationIds = @(
        $mappingRows |
        ForEach-Object { [string][int]$_.FinalId } |
        Select-Object -Unique
    )

    if ($uniqueDestinationIds.Count -ne $finalBookmarks.Count) {
        $errors += "Distinct mapped destinations ($($uniqueDestinationIds.Count)) do not equal final Library count ($($finalBookmarks.Count))."
    }

    $mappedDestinationSet = @{}
    foreach ($id in $uniqueDestinationIds) {
        $mappedDestinationSet[$id] = $true
    }

    $unexpectedFinal = @(
        $finalBookmarks |
        Where-Object {
            -not $mappedDestinationSet.ContainsKey([string][int]$_.Bookmark.id)
        }
    )

    if ($unexpectedFinal.Count -gt 0) {
        $errors += "Unexpected final Library records not traceable to the original: $($unexpectedFinal.Count)"
    }

    # Calculate original and final watch-state totals for the summary.
    $originalStatusCounts = @{}
    foreach ($entry in $originalBookmarks) {
        $originalId = [int]$entry.Bookmark.id
        $originalState = $originalWatchStateById[[string]$originalId]
        $stateName = Get-StatusName $originalState

        if (-not $originalStatusCounts.ContainsKey($stateName)) {
            $originalStatusCounts[$stateName] = 0
        }

        $originalStatusCounts[$stateName]++
    }

    $finalStatusCounts = @{}
    foreach ($entry in $finalBookmarks) {
        $stateName = Get-StatusName (
            Get-WatchState -Store $store -Id ([int]$entry.Bookmark.id)
        )
        if (-not $finalStatusCounts.ContainsKey($stateName)) {
            $finalStatusCounts[$stateName] = 0
        }
        $finalStatusCounts[$stateName]++
    }

    # Confirm that no YFlix cache records remain in the generated backup.
    $remainingYFlixCache = 0

    foreach ($key in @($store.Keys)) {
        if ($key -notlike "download_header_cache/*" -and
            $key -notlike "BACKUP_download_header_cache/*") {
            continue
        }

        try {
            $raw = [string]$store[$key]
            if ($raw -eq "null") { continue }

            $obj = $raw | ConvertFrom-Json
            if ([string]$obj.apiName -eq "YFlix") {
                $remainingYFlixCache++
            }
        }
        catch {}
    }

    if ($remainingYFlixCache -gt 0) {
        $errors += "YFlix cache records remain in final backup: $remainingYFlixCache"
    }

    if ($store.ContainsKey("Yflix_CURRENT_SERVER")) {
        $errors += "Yflix_CURRENT_SERVER still exists."
    }

    # ------------------------------------------------------------------------
    # DO NOT WRITE FINAL BACKUP IF VALIDATION FAILED
    # ------------------------------------------------------------------------
    if ($errors.Count -gt 0) {
        Write-Host ""
        Write-Host "========== VALIDATION FAILED =========="
        foreach ($err in $errors) {
            Write-Host "  X $err"
        }
        Write-Host ""
        Write-Host "FINAL_CLEANED.txt was NOT written."
        return
    }

    Write-CloudStreamBackup `
        -Backup $data.Backup `
        -Store $store `
        -Path $finalPath

    if ($WriteDetailed) {
        $mappingRows |
            Export-Csv -LiteralPath $auditPath -NoTypeInformation -Encoding UTF8
    }

    $summaryLines = @()
    $summaryLines += "CloudStream YFlix -> CineStream Migration Summary"
    $summaryLines += "Script version: $ScriptVersion"
    $summaryLines += ""
    $summaryLines += "Original backup: $($data.Path)"
    $summaryLines += "Final backup:    $finalPath"
    $summaryLines += ""
    $summaryLines += "Original Library records: $originalCount"
    $summaryLines += "Final Library records:    $($finalBookmarks.Count)"
    $summaryLines += "Original records mapped:  $($mappingRows.Count) / $originalCount"
    $summaryLines += "Distinct final content:    $($uniqueDestinationIds.Count)"
    $summaryLines += "Converted to CineStream:   $convertedCount"
    $summaryLines += "Existing matches kept:     $consolidatedCount"
    $summaryLines += "Active YFlix:              0"
    $summaryLines += "Duplicate IMDb groups:     0"
    $summaryLines += "Invalid CineStream hashes: 0"
    $summaryLines += "Missing mapped titles:     0"
    $summaryLines += "Unexpected final titles:   0"
    $summaryLines += ""
    $summaryLines += "Cleanup:"
    $summaryLines += "  YFlix cache records removed: $($cleanup.CacheRecordsRemoved)"
    $summaryLines += "  YFlix server setting removed: $($cleanup.ServerSettingRemoved)"
    $summaryLines += "  Provider preference repaired: $($cleanup.ProviderPreferenceFixed)"
    $summaryLines += ""
    $summaryLines += "Original status counts:"
    foreach ($name in ($originalStatusCounts.Keys | Sort-Object)) {
        $summaryLines += "  ${name}: $($originalStatusCounts[$name])"
    }
    $summaryLines += ""
    $summaryLines += "Final status counts:"
    foreach ($name in ($finalStatusCounts.Keys | Sort-Object)) {
        $summaryLines += "  ${name}: $($finalStatusCounts[$name])"
    }
    $summaryLines += ""
    $summaryLines += "RESULT: PASS"
    $summaryLines += "Every original active Library record maps to an active final destination."

    [IO.File]::WriteAllLines(
        $summaryPath,
        $summaryLines,
        [Text.UTF8Encoding]::new($false)
    )

    Write-Host ""
    Write-Host "========== MIGRATION VERIFIED =========="
    Write-Host "Original Library records : $originalCount"
    Write-Host "Final Library records    : $($finalBookmarks.Count)"
    Write-Host "Original records mapped  : $($mappingRows.Count) / $originalCount"
    Write-Host "Distinct final content   : $($uniqueDestinationIds.Count)"
    Write-Host "Converted to CineStream  : $convertedCount"
    Write-Host "Existing matches kept    : $consolidatedCount"
    Write-Host "Missing titles           : 0"
    Write-Host "Unexpected titles        : 0"
    Write-Host "Active YFlix             : 0"
    Write-Host "Duplicate IMDb groups    : 0"
    Write-Host "Invalid CineStream IDs   : 0"
    Write-Host ""
    Write-Host "RESULT: PASS"
    Write-Host ""
    Write-Host "Final backup:"
    Write-Host "  $finalPath"
    Write-Host "Summary:"
    Write-Host "  $summaryPath"

    if ($WriteDetailed) {
        Write-Host "Detailed audit:"
        Write-Host "  $auditPath"
    }
}

# ============================================================================
# ACTION: VERIFY
# ============================================================================

function Invoke-Verify {
    param(
        [Parameter(Mandatory=$true)][string]$OriginalPath,
        [Parameter(Mandatory=$true)][string]$FinalPath,
        [string]$MappingsPath,
        [string]$RequestedOutputDir,
        [switch]$WriteDetailed,
        [switch]$AllowOverwrite
    )

    $original = Read-CloudStreamBackup -Path $OriginalPath
    $final = Read-CloudStreamBackup -Path $FinalPath

    $outDir = Ensure-OutputDirectory `
        -OriginalPath $original.Path `
        -RequestedOutputDir $RequestedOutputDir

    if ([string]::IsNullOrWhiteSpace($MappingsPath)) {
        $defaultMappings = Join-Path $outDir "NeedsReview.csv"

        if (Test-Path -LiteralPath $defaultMappings -PathType Leaf) {
            $MappingsPath = $defaultMappings
        }
    }

    $manualMap = Import-ManualMappings -Path $MappingsPath

    $originalBookmarks = @(Get-ActiveBookmarks -Store $original.Store)
    $finalBookmarks = @(Get-ActiveBookmarks -Store $final.Store)

    $finalById = @{}
    $finalByImdb = @{}
    $finalByTitleYear = @{}

    foreach ($entry in $finalBookmarks) {
        $b = $entry.Bookmark
        $idKey = [string][int]$b.id
        $finalById[$idKey] = $b

        $imdb = Get-ImdbIdFromBookmark -Bookmark $b
        if ($null -ne $imdb) {
            if (-not $finalByImdb.ContainsKey($imdb)) {
                $finalByImdb[$imdb] = @()
            }
            $finalByImdb[$imdb] += $b
        }

        $titleKey = "$(Normalize-Title ([string]$b.name))|$([string]$b.year)"
        if (-not $finalByTitleYear.ContainsKey($titleKey)) {
            $finalByTitleYear[$titleKey] = @()
        }
        $finalByTitleYear[$titleKey] += $b
    }

    $verifyRows = @()
    $unmatched = @()

    foreach ($entry in $originalBookmarks) {
        $b = $entry.Bookmark
        $oldId = [int]$b.id
        $matched = $null
        $matchMethod = ""

        # Non-migrated records normally keep their exact ID.
        $idKey = [string]$oldId
        if ($finalById.ContainsKey($idKey)) {
            $matched = $finalById[$idKey]
            $matchMethod = "SameId"
        }

        # Manual mapping overrides/repairs bad source IMDb metadata.
        if ($null -eq $matched -and
            $manualMap.ContainsKey([string]$oldId)) {
            $manual = $manualMap[[string]$oldId]
            $candidateImdb = $manual.ManualImdbId

            if ($candidateImdb -match '^tt\d+$' -and
                $finalByImdb.ContainsKey($candidateImdb)) {
                $matched = @($finalByImdb[$candidateImdb])[0]
                $matchMethod = "ManualIMDb"
            }
        }

        # Stable IMDb match.
        if ($null -eq $matched) {
            $imdb = Get-ImdbIdFromBookmark -Bookmark $b

            if ($null -ne $imdb -and $finalByImdb.ContainsKey($imdb)) {
                $matched = @($finalByImdb[$imdb])[0]
                $matchMethod = "IMDb"
            }
        }

        # Conservative exact normalized title + year fallback.
        if ($null -eq $matched) {
            $titleKey = "$(Normalize-Title ([string]$b.name))|$([string]$b.year)"

            if ($finalByTitleYear.ContainsKey($titleKey)) {
                $matched = @($finalByTitleYear[$titleKey])[0]
                $matchMethod = "TitleYear"
            }
        }

        if ($null -eq $matched) {
            $unmatched += $b

            $verifyRows += [pscustomobject]@{
                OriginalName     = [string]$b.name
                OriginalYear     = [string]$b.year
                OriginalProvider = [string]$b.apiName
                OriginalId       = $oldId
                OriginalImdb     = [string](Get-ImdbIdFromBookmark -Bookmark $b)
                FinalName        = ""
                FinalProvider    = ""
                FinalId          = ""
                FinalImdb        = ""
                MatchMethod      = "UNMATCHED"
            }

            continue
        }

        $verifyRows += [pscustomobject]@{
            OriginalName     = [string]$b.name
            OriginalYear     = [string]$b.year
            OriginalProvider = [string]$b.apiName
            OriginalId       = $oldId
            OriginalImdb     = [string](Get-ImdbIdFromBookmark -Bookmark $b)
            FinalName        = [string]$matched.name
            FinalProvider    = [string]$matched.apiName
            FinalId          = [int]$matched.id
            FinalImdb        = [string](Get-ImdbIdFromBookmark -Bookmark $matched)
            MatchMethod      = $matchMethod
        }
    }

    $matchedFinalIds = @(
        $verifyRows |
        Where-Object { $_.MatchMethod -ne "UNMATCHED" } |
        ForEach-Object { [string]$_.FinalId } |
        Select-Object -Unique
    )

    $matchedFinalSet = @{}
    foreach ($id in $matchedFinalIds) {
        $matchedFinalSet[$id] = $true
    }

    $unexpectedFinal = @(
        $finalBookmarks |
        Where-Object {
            -not $matchedFinalSet.ContainsKey([string][int]$_.Bookmark.id)
        }
    )

    $activeYFlix = @(
        $finalBookmarks |
        Where-Object { [string]$_.Bookmark.apiName -eq "YFlix" }
    )

    $imdbGroups = @{}
    foreach ($entry in $finalBookmarks) {
        $imdb = Get-ImdbIdFromBookmark -Bookmark $entry.Bookmark
        if ($null -eq $imdb) { continue }

        if (-not $imdbGroups.ContainsKey($imdb)) {
            $imdbGroups[$imdb] = @()
        }

        $imdbGroups[$imdb] += $entry.Bookmark
    }

    $duplicates = @(
        $imdbGroups.GetEnumerator() |
        Where-Object { @($_.Value).Count -gt 1 }
    )

    Write-Host ""
    Write-Host "========== ORIGINAL vs FINAL VERIFY =========="
    Write-Host "Original Library records : $($originalBookmarks.Count)"
    Write-Host "Final Library records    : $($finalBookmarks.Count)"
    Write-Host "Original records matched : $($originalBookmarks.Count - $unmatched.Count) / $($originalBookmarks.Count)"
    Write-Host "Distinct final matches   : $($matchedFinalIds.Count)"
    Write-Host "Unmatched originals      : $($unmatched.Count)"
    Write-Host "Unexpected final records : $($unexpectedFinal.Count)"
    Write-Host "Active YFlix             : $($activeYFlix.Count)"
    Write-Host "Duplicate IMDb groups    : $($duplicates.Count)"

    if ($unmatched.Count -eq 0 -and
        $unexpectedFinal.Count -eq 0 -and
        $activeYFlix.Count -eq 0 -and
        $duplicates.Count -eq 0) {
        Write-Host ""
        Write-Host "RESULT: PASS"
        Write-Host "Every original Library record is accounted for."
    }
    else {
        Write-Host ""
        Write-Host "RESULT: REVIEW REQUIRED"

        if ($unmatched.Count -gt 0) {
            Write-Host ""
            Write-Host "Unmatched originals:"
            foreach ($b in $unmatched) {
                Write-Host "  - $($b.name) ($($b.year)) [$($b.apiName)] ID $($b.id)"
            }
        }

        if ($unexpectedFinal.Count -gt 0) {
            Write-Host ""
            Write-Host "Unexpected final records:"
            foreach ($entry in $unexpectedFinal) {
                $b = $entry.Bookmark
                Write-Host "  - $($b.name) ($($b.year)) [$($b.apiName)] ID $($b.id)"
            }
        }
    }

    if ($WriteDetailed) {
        $verifyPath = Join-Path $outDir "VerificationAudit.csv"
        Assert-CanWriteFile -Path $verifyPath -AllowOverwrite:$AllowOverwrite

        $verifyRows |
            Export-Csv -LiteralPath $verifyPath -NoTypeInformation -Encoding UTF8

        Write-Host ""
        Write-Host "Verification audit:"
        Write-Host "  $verifyPath"
    }
}

# ============================================================================
# ACTION: TOMBSTONE
# ============================================================================

function Invoke-Tombstone {
    param(
        [Parameter(Mandatory=$true)][string]$BackupPath,
        [string]$RequestedOutputDir,
        [switch]$AllowOverwrite
    )

    $data = Read-CloudStreamBackup -Path $BackupPath
    $outDir = Ensure-OutputDirectory `
        -OriginalPath $data.Path `
        -RequestedOutputDir $RequestedOutputDir

    $outputPath = Join-Path $outDir "REMOVE_OLD_YFLIX.txt"
    Assert-CanWriteFile -Path $outputPath -AllowOverwrite:$AllowOverwrite

    $yflix = @(
        Get-ActiveBookmarks -Store $data.Store |
        Where-Object { [string]$_.Bookmark.apiName -eq "YFlix" }
    )

    $ids = @(
        $yflix |
        ForEach-Object { [int]$_.Bookmark.id } |
        Sort-Object -Unique
    )

    $strings = @{}

    foreach ($id in $ids) {
        # WatchType.NONE = 5.
        $strings["0/result_watch_state/$id"] = "5"

        # SharedPreferences string "null" deserializes to null BookmarkedData,
        # causing the stale Library record to be ignored.
        $strings["0/result_watch_state_data/$id"] = "null"

        $resumeKey = "0/result_resume_watching_2/$id"
        if ($data.Store.ContainsKey($resumeKey)) {
            $strings[$resumeKey] = "null"
        }
    }

    $cacheCount = 0

    foreach ($key in @($data.Store.Keys)) {
        if ($key -notlike "download_header_cache/*" -and
            $key -notlike "BACKUP_download_header_cache/*") {
            continue
        }

        try {
            $raw = [string]$data.Store[$key]
            if ($raw -eq "null") { continue }

            $obj = $raw | ConvertFrom-Json

            if ([string]$obj.apiName -eq "YFlix") {
                $strings[$key] = "null"
                $cacheCount++
            }
        }
        catch {}
    }

    $cleanup = [ordered]@{
        datastore = [ordered]@{
            _Bool      = @{}
            _Int       = @{}
            _String    = $strings
            _Float     = @{}
            _Long      = @{}
            _StringSet = @{}
        }
        settings = [ordered]@{
            _Bool      = @{}
            _Int       = @{}
            _String    = @{}
            _Float     = @{}
            _Long      = @{}
            _StringSet = @{}
        }
    }

    $json = $cleanup | ConvertTo-Json -Depth 20 -Compress

    [IO.File]::WriteAllText(
        $outputPath,
        $json,
        [Text.UTF8Encoding]::new($false)
    )

    $null = (
        Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    )

    Write-Host ""
    Write-Host "========== YFLIX TOMBSTONE CREATED =========="
    Write-Host "Old YFlix bookmark IDs : $($ids.Count)"
    Write-Host "YFlix cache tombstones : $cacheCount"
    Write-Host "Output:"
    Write-Host "  $outputPath"
    Write-Host ""
    Write-Host "Restore this file OVER the current TV installation."
    Write-Host "Do not clear CloudStream app data."
}

# ============================================================================
# INTERACTIVE USER INTERFACE
# ============================================================================

function Show-InteractiveMenu {
    Write-Host ""
    Write-Host "CloudStream Library Migration Utility v$ScriptVersion"
    Write-Host "====================================================="
    Write-Host "1. Analyze original backup"
    Write-Host "2. Build final migrated backup"
    Write-Host "3. Verify original vs final"
    Write-Host "4. Generate YFlix cleanup/tombstone backup"
    Write-Host "5. Exit"
    Write-Host ""

    $choice = Read-Host "Select"

    switch ($choice) {
        "1" {
            $path = Clean-UserPath (Read-Host "Original backup path")
            Invoke-Analyze -BackupPath $path
        }

        "2" {
            $path = Clean-UserPath (Read-Host "Original backup path")
            $mapping = Clean-UserPath (
                Read-Host "Manual mapping CSV (press Enter to auto-use CloudStreamMigration\NeedsReview.csv)"
            )

            Invoke-Build `
                -BackupPath $path `
                -MappingsPath $mapping
        }

        "3" {
            $originalPath = Clean-UserPath (Read-Host "Original backup path")
            $finalPath = Clean-UserPath (Read-Host "Final backup path")
            $mapping = Clean-UserPath (
                Read-Host "Manual mapping CSV (optional; press Enter to auto-detect)"
            )

            Invoke-Verify `
                -OriginalPath $originalPath `
                -FinalPath $finalPath `
                -MappingsPath $mapping
        }

        "4" {
            $path = Clean-UserPath (Read-Host "Original backup path")
            Invoke-Tombstone -BackupPath $path
        }

        "5" {
            return
        }

        default {
            Write-Host "Invalid selection."
        }
    }
}

# ============================================================================
# SCRIPT ENTRY POINT
# ============================================================================

try {
    if ([string]::IsNullOrWhiteSpace($Action)) {
        Show-InteractiveMenu
        exit 0
    }

    switch ($Action) {
        "Analyze" {
            if ([string]::IsNullOrWhiteSpace($OriginalBackup)) {
                throw "-OriginalBackup is required for Analyze."
            }

            Invoke-Analyze `
                -BackupPath $OriginalBackup `
                -RequestedOutputDir $OutputDir `
                -MappingsPath $ManualMappings `
                -AllowOverwrite:$Overwrite `
                -WriteDetailed:$DetailedReport
        }

        "Build" {
            if ([string]::IsNullOrWhiteSpace($OriginalBackup)) {
                throw "-OriginalBackup is required for Build."
            }

            Invoke-Build `
                -BackupPath $OriginalBackup `
                -RequestedOutputDir $OutputDir `
                -MappingsPath $ManualMappings `
                -AllowOverwrite:$Overwrite `
                -WriteDetailed:$DetailedReport
        }

        "Verify" {
            if ([string]::IsNullOrWhiteSpace($OriginalBackup)) {
                throw "-OriginalBackup is required for Verify."
            }

            if ([string]::IsNullOrWhiteSpace($FinalBackup)) {
                throw "-FinalBackup is required for Verify."
            }

            Invoke-Verify `
                -OriginalPath $OriginalBackup `
                -FinalPath $FinalBackup `
                -MappingsPath $ManualMappings `
                -RequestedOutputDir $OutputDir `
                -WriteDetailed:$DetailedReport `
                -AllowOverwrite:$Overwrite
        }

        "Tombstone" {
            if ([string]::IsNullOrWhiteSpace($OriginalBackup)) {
                throw "-OriginalBackup is required for Tombstone."
            }

            Invoke-Tombstone `
                -BackupPath $OriginalBackup `
                -RequestedOutputDir $OutputDir `
                -AllowOverwrite:$Overwrite
        }
    }
}
catch {
    Write-Host ""
    Write-Host "ERROR:"
    Write-Host $_.Exception.Message
    Write-Host ""
    exit 1
}
