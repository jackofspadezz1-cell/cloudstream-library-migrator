# CloudStream Library Migrator

PowerShell utility for migrating **CloudStream Android / Android TV Library bookmarks from YFlix to CineStream** while preserving Library state, consolidating duplicates, cleaning stale source-provider data, validating the generated backup, and optionally creating a cleanup/tombstone backup.

> **Tested provider path:** YFlix → CineStream  
> **Script:** `CloudStream-LibraryMigrator.ps1`  
> **Version:** 1.1.0  
> **PowerShell:** Windows PowerShell 5.1 or newer

This is a backup-transformation utility and is not an official CloudStream feature.

---

## Privacy First

CloudStream backup files can contain much more than Library titles. Depending on installed extensions and configuration, a backup may contain cookies, session values, provider settings, repository information, account-related settings, and device/application state.

**Do not publish a raw CloudStream backup.**

If asking another person or an AI assistant to help adapt this utility:

1. Prefer a backup created specifically for testing.
2. Remove unrelated settings and credentials when possible.
3. Share only the minimum bookmark/cache records needed to understand the extension format.
4. Never intentionally publish cookies, tokens, passwords, account identifiers, or private repository credentials.

The public script and examples in this repository contain no user-specific backup filenames, usernames, device names, personal paths, raw Library data, cookies, or account credentials.

---

## What the Utility Does

The script provides four actions:

| Action | Purpose |
|---|---|
| `Analyze` | Reads the original backup, finds active YFlix Library records, determines which records can be migrated automatically, and creates `NeedsReview.csv` only when manual metadata is required. |
| `Build` | Creates one validated `FINAL_CLEANED.txt` directly from the untouched original backup. |
| `Verify` | Compares an original backup with a final backup and checks that the original Library is accounted for. |
| `Tombstone` | Creates `REMOVE_OLD_YFLIX.txt`, a minimal backup that neutralizes stale YFlix records that can remain after CloudStream merges a restored backup with existing app data. |

Running the script without `-Action` displays an interactive menu.

---

# How It Works in Basic Terms

CloudStream Library entries are stored as structured bookmark records inside the backup.

A simplified source bookmark may contain:

```text
Title
Year
Provider
CloudStream bookmark ID
Provider URL
IMDb/TMDb synchronization data
Watch state
Playback state
Poster
Metadata
```

For the currently supported YFlix → CineStream migration, the important stable identifier is normally the **IMDb ID** already stored in the bookmark's synchronization metadata.

Conceptually:

```text
Old YFlix bookmark
        ↓
Read the stored IMDb ID
        ↓
Check for an existing working bookmark with that IMDb ID
        ↓
If none exists, construct CineStream's bookmark URL
        ↓
Calculate the CloudStream bookmark ID
        ↓
Copy the Library state and compatible auxiliary state
        ↓
Remove the active YFlix bookmark
        ↓
Validate the entire generated backup
```

The script does **not** normally search IMDb.com. It reads an IMDb identifier that is already present in the CloudStream backup.

If an item has missing or unreliable metadata, the utility puts it in `NeedsReview.csv` rather than guessing.

---

# Extension Support: What Is Generic and What Is Not

A large part of the utility is reusable across CloudStream extensions, but the current release is **not a universal provider-to-provider migrator**.

## Reusable Migration Engine

These parts are largely provider-independent:

- CloudStream backup parsing
- Library record discovery
- watch-state preservation
- playback/resume-state handling
- IMDb-based duplicate detection
- manual-review CSV handling
- collision protection
- original-vs-final verification
- JSON validation
- generated-file protection
- reporting
- tombstone/neutralization mechanics

## Source-Specific Logic: YFlix

The current script explicitly recognizes YFlix as the broken/source provider.

It looks for values such as:

```text
apiName = YFlix
```

and knows about YFlix-specific cleanup data, including:

```text
YFlix download_header_cache records
YFlix BACKUP_download_header_cache records
Yflix_CURRENT_SERVER
YFlix entries in saved provider preferences
```

A different source extension may use different provider names and saved keys.

## Target-Specific Logic: CineStream

CineStream is currently the implemented destination adapter.

For a movie with a valid IMDb ID, the script constructs a CineStream bookmark URL in this form:

```json
{"id":"tt1234567","type":"movie"}
```

`tt1234567` is only a placeholder example.

The target poster pattern implemented by the script is:

```text
https://wsrv.nl/?url=https://images.metahub.space/poster/small/<IMDb_ID>/img
```

The script then reproduces Java/Kotlin `String.hashCode()` for the exact provider URL string to generate the corresponding CloudStream bookmark ID.

These rules were verified for the tested CineStream records. **Do not assume another extension follows the same rules.**

---

# Adapting the Utility to Another Extension

If CineStream stops working, most of the migration engine does not need to be rewritten. The main job is determining how the replacement extension represents a bookmark.

For a new target provider, determine:

1. **Provider name**
   - What value appears in `apiName`?

2. **Stable identifier**
   - Does it use IMDb?
   - TMDb?
   - MAL/AniList?
   - A provider-specific numeric/string ID?

3. **Bookmark URL**
   - What exact string is saved in the CloudStream bookmark's `url` field?

4. **Bookmark ID**
   - Is the CloudStream `id` a Java/Kotlin hash of the saved URL?
   - Is it supplied directly by the extension?
   - Is another formula used?

5. **Poster**
   - Is a poster URL generated from IMDb/TMDb?
   - Does the extension return its own poster URL?

6. **Content type**
   - How are movies and TV series represented?

7. **Source cleanup**
   - What cache/preferences are associated with the broken provider?
   - Which keys should be removed or neutralized?

The main target-provider modification points in the script are intentionally marked with comments, including:

```powershell
New-CineStreamUrl
Get-CineStreamPosterUrl
```

The source-provider cleanup section is also clearly labeled:

```powershell
Remove-YFlixCaches
Repair-ProviderPreferences
Apply-YFlixGeneralCleanup
```

There are additional direct checks for the strings:

```text
YFlix
CineStream
```

Those should be reviewed when adapting the script.

---

# A Practical Way to Reverse-Engineer a Replacement Extension

The easiest approach is usually to create a **small controlled sample**.

## 1. Add Test Titles Manually

Install the replacement CloudStream extension and manually add a few test titles through that extension.

Using several examples is better than using one because it helps reveal which fields change and which are fixed.

## 2. Create a New CloudStream Backup

Create a backup after adding those sample records.

Do not publish the complete raw backup.

## 3. Extract/Sanitize the Relevant Records

The useful records are generally the new bookmark entries and closely related state/cache data.

Remove unrelated account/session/provider data before sharing the sample publicly.

## 4. Compare the Records

Look for:

```text
apiName
url
id
posterUrl
type
syncData
IMDb/TMDb IDs
download_header_cache
watch-state keys
```

The goal is to understand the transformation:

```text
Stable content identity
        ↓
Replacement extension's URL/ID format
        ↓
Valid CloudStream bookmark
```

## 5. Modify the Provider Adapter

Once the pattern is understood, replace or add target-provider helper functions and update the provider-specific checks.

Then run the same Analyze → Build → Verify workflow against a test backup before using it on a real Library.

---

# Using AI to Help Adapt It

An AI coding assistant can be useful for adapting the provider-specific pieces, but give it **sanitized data**.

A useful request would be similar to:

> I have a PowerShell CloudStream backup migrator. It currently targets CineStream. Here are sanitized bookmark records from several titles added through another extension. Compare the records, determine how the new extension constructs `apiName`, `url`, `id`, `posterUrl`, `type`, and sync identifiers, then explain what functions/checks in the migrator need to change. Do not modify the backup data itself until the format is verified.

Provide:

- the current public script;
- several sanitized target-extension bookmark examples;
- optionally equivalent source bookmarks for the same titles;
- no cookies, account data, tokens, private repository credentials, or unrelated backup settings.

The AI should first explain the inferred provider format and confidence level. Only then should it generate an adapter or modified script.

### Why Several Samples Matter

A single bookmark can make an accidental relationship look like a rule.

For example, another extension might use:

```text
IMDb ID
TMDb ID
its own internal website ID
a slug
an encoded JSON object
```

Multiple sample records make it easier to determine which identifier actually controls the provider URL and CloudStream ID.

---

# Difficulty of Adapting to Different Provider Types

## Easy: IMDb-Based Provider

Example conceptual format:

```json
{"id":"<IMDb_ID>","type":"movie"}
```

If the provider directly accepts IMDb IDs, adaptation may only require changing the provider URL/poster builders and provider name.

## Moderate: TMDb-Based Provider

If the backup contains IMDb IDs but the destination extension requires TMDb IDs, the migration needs a reliable IMDb → TMDb mapping step.

That can still be automated, but it requires a metadata lookup/source rather than only local backup data.

## Harder: Provider-Specific IDs

Some extensions may save URLs such as:

```text
https://provider.example/watch/provider-specific-id
```

If that provider-specific ID cannot be derived from IMDb/TMDb, the migration tool must either:

- search the destination provider;
- use an extension/provider API;
- import a prebuilt mapping;
- or require manual review.

In that case the generic backup engine is still useful, but discovery of the destination record becomes a separate component.

---

# Quick Start

Place the script and an untouched CloudStream backup in a working folder.

Example:

```text
C:\CloudStreamMigration\
├── CloudStream-LibraryMigrator.ps1
└── original-backup.txt
```

Open PowerShell in that folder.

If PowerShell blocks script execution for the current session:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

This setting applies only to the current PowerShell process.

---

# Analyze

```powershell
.\CloudStream-LibraryMigrator.ps1 `
  -Action Analyze `
  -OriginalBackup ".\original-backup.txt"
```

Typical information reported:

```text
Active Library records
YFlix records
Ready to migrate
Existing provider matches
Needs manual review
Provider counts
```

If manual input is necessary, the script creates:

```text
CloudStreamMigration\NeedsReview.csv
```

`Analyze` does not modify the source backup.

---

# Manual Review CSV

Possible columns include:

```text
Name
Year
OldId
OldType
Reason
CurrentImdbId
ManualImdbId
TargetType
CorrectedName
CorrectedYear
```

## `ManualImdbId`

Enter a verified IMDb title ID, including the `tt` prefix:

```text
tt1234567
```

The value above is a placeholder example.

## `TargetType`

Valid values:

```text
movie
tv
```

## `CorrectedName`

Optional corrected bookmark name.

Example:

```text
Example Movie
```

## `CorrectedYear`

Optional corrected four-digit year.

Example:

```text
2020
```

## `OldId`

Do not edit `OldId`. It identifies the original bookmark record.

---

# Build

After completing `NeedsReview.csv` when required:

```powershell
.\CloudStream-LibraryMigrator.ps1 `
  -Action Build `
  -OriginalBackup ".\original-backup.txt"
```

If this file exists:

```text
CloudStreamMigration\NeedsReview.csv
```

the script automatically uses it.

A successful build creates:

```text
CloudStreamMigration\FINAL_CLEANED.txt
CloudStreamMigration\MigrationSummary.txt
```

The original backup remains unchanged.

---

# Duplicate Handling

Before creating a CineStream bookmark, the script checks for an existing **non-YFlix** bookmark with the same IMDb ID.

If one exists, the utility can retain the existing working bookmark rather than creating a duplicate.

This means an already-working copy from another extension may remain the final destination.

The existing destination's watch state is preserved, and compatible auxiliary state from the YFlix record is only used where appropriate.

---

# Build Validation

Before `FINAL_CLEANED.txt` is written, the utility checks that:

- no active YFlix Library bookmarks remain;
- no active Library URL/poster still points to YFlix;
- every active bookmark has a watch-state key;
- no duplicate IMDb groups remain;
- CineStream URL/hash IDs are consistent;
- every original Library record maps to a final destination;
- every final Library record is traceable to the original;
- YFlix cache records are removed;
- the YFlix server preference is removed;
- the output is valid JSON.

If validation fails:

```text
VALIDATION FAILED
FINAL_CLEANED.txt was NOT written.
```

Do not restore a failed/partial result.

---

# Verify

To independently compare the source and final backups:

```powershell
.\CloudStream-LibraryMigrator.ps1 `
  -Action Verify `
  -OriginalBackup ".\original-backup.txt" `
  -FinalBackup ".\CloudStreamMigration\FINAL_CLEANED.txt"
```

Verification attempts to match records using:

1. the same CloudStream ID;
2. a supplied manual IMDb correction;
3. IMDb ID;
4. normalized exact title + year as a conservative fallback.

A clean result reports:

```text
RESULT: PASS
Every original Library record is accounted for.
```

---

# Tombstone Cleanup

CloudStream restore can merge restored values with keys already stored on the device. A generated backup may contain no active YFlix bookmarks while old YFlix records still survive locally.

Generate a cleanup/tombstone backup from the **original source backup**:

```powershell
.\CloudStream-LibraryMigrator.ps1 `
  -Action Tombstone `
  -OriginalBackup ".\original-backup.txt"
```

Output:

```text
CloudStreamMigration\REMOVE_OLD_YFLIX.txt
```

For each old YFlix bookmark the cleanup backup writes:

```text
0/result_watch_state/<oldId> = 5
0/result_watch_state_data/<oldId> = "null"
```

In the currently implemented CloudStream watch-state mapping, `5` represents `None`.

The cleanup file also neutralizes YFlix cache records and directly associated resume state where present.

## Device Workflow

1. Restore `FINAL_CLEANED.txt`.
2. If stale YFlix cards remain, restore `REMOVE_OLD_YFLIX.txt` over the existing installation.
3. Do **not** clear application data unless you intentionally want to reset CloudStream.
4. If only old images remain, force-stop CloudStream and clear the application cache.
5. Reopen CloudStream.

---

# Interactive Mode

Run:

```powershell
.\CloudStream-LibraryMigrator.ps1
```

Menu:

```text
CloudStream Library Migration Utility
=====================================================
1. Analyze original backup
2. Build final migrated backup
3. Verify original vs final
4. Generate YFlix cleanup/tombstone backup
5. Exit
```

---

# Optional Parameters

## Custom Output Directory

```powershell
-OutputDir ".\Output"
```

## Detailed Reports

```powershell
-DetailedReport
```

Depending on the selected action, optional files can include:

```text
Analysis.csv
MigrationAudit.csv
VerificationAudit.csv
```

## Overwrite Generated Files

```powershell
-Overwrite
```

The script otherwise protects existing output files from accidental replacement.

---

# Default Output Layout

```text
CloudStreamMigration\
├── NeedsReview.csv
├── FINAL_CLEANED.txt
├── MigrationSummary.txt
└── REMOVE_OLD_YFLIX.txt
```

Optional detailed reports are only generated with `-DetailedReport`.

---

# Recommended Workflow

```text
1. Create a fresh CloudStream backup.
2. Preserve an untouched copy.
3. Run Analyze.
4. Complete NeedsReview.csv if generated.
5. Run Build.
6. Review MigrationSummary.txt.
7. Run Verify.
8. Restore FINAL_CLEANED.txt on a test/device installation.
9. Test several migrated Library entries.
10. Use the Tombstone action only if stale source-provider entries remain.
11. Keep the original backup as the rollback point.
```

---

# CloudStream Watch-State IDs Used by This Script

| ID | State |
|---:|---|
| `0` | Watching |
| `1` | Completed |
| `2` | On Hold |
| `3` | Dropped |
| `4` | Plan to Watch |
| `5` | None |

These values are used for Library-state preservation and tombstone cleanup.

---

# Troubleshooting

## Script Execution Is Disabled

For the current PowerShell process:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

## Build Stops for Manual Review

Open:

```text
CloudStreamMigration\NeedsReview.csv
```

Complete the required metadata, save the file, and rerun `Build`.

## Output Already Exists

Move/rename the existing output, or intentionally use:

```powershell
-Overwrite
```

## Hash Self-Test Fails

The script validates the Java/Kotlin hash implementation with a provider-neutral test string:

```text
cloudstream-migrator-self-test
→ -1527676709
```

Do not bypass this validation. A bad hash implementation can produce invalid destination bookmark IDs.

## Gray Source-Provider Cards Remain After Restore

Generate and restore the Tombstone backup. This addresses stale local records that were not deleted by CloudStream's merge-style restore.

---

# Scope and Limitations

This release has been tested for:

```text
YFlix → CineStream
```

It should **not** be presented as supporting arbitrary CloudStream extensions without modification and testing.

Other extensions may use:

- different bookmark URL structures;
- TMDb instead of IMDb;
- provider-specific IDs;
- different poster sources;
- different type representations;
- non-hash bookmark IDs;
- provider-specific TV episode identifiers;
- additional cache/preference keys.

Movies with stable IMDb IDs are the simplest migration case. TV-series migrations can be more complex because episode identifiers and playback state may be provider-specific.

---

# Files Worth Keeping

After a successful migration, keep:

```text
original-backup.txt
CloudStream-LibraryMigrator.ps1
NeedsReview.csv
FINAL_CLEANED.txt
MigrationSummary.txt
REMOVE_OLD_YFLIX.txt
README.md
```

Keep the untouched original backup as the rollback source.

---

## Disclaimer

Provider formats and CloudStream internals can change. Always analyze and verify a fresh backup before restoring generated data.

If adapting this utility to another extension, verify the new provider format from multiple sanitized sample records before modifying a real Library.
