<#
.SYNOPSIS
    Builds the comment that reports a submission on its issue.

.DESCRIPTION
    Reads what tools/submission.ps1 produced and, when the review ran, its verdict, and writes
    the markdown for the issue comment plus the labels that go with it. The workflow posts the
    file; this is the part that is worth testing.

.EXAMPLE
    ./tools/issue-comment.ps1 -Report ./out/submission-report.md -Review ./out/review.json `
        -OutFile ./out/comment.md -LabelsFile ./out/labels.txt
#>
[CmdletBinding()]
param(
    # The report submission.ps1 wrote. Absent when the checks failed.
    [string]$Report,

    # The review service's reply, as it sent it.
    [string]$Review,

    # Why the review step failed, when it did.
    [string]$ReviewError,

    # The review is still running: this is the checks report, and the comment is updated later.
    [switch]$ReviewPending,

    # What submission.ps1 printed when it refused the submission.
    [string]$Failure,

    [Parameter(Mandatory = $true)][string]$OutFile,
    [Parameter(Mandatory = $true)][string]$LabelsFile
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'catalogue-rules.ps1')

$marker = '<!-- swyf-modding-check -->'

$lines = New-Object System.Collections.ArrayList
$labels = New-Object System.Collections.ArrayList
[void]$labels.Add('submission')

function Add-Line([string]$text) { [void]$lines.Add($text) }

[void]$lines.Add($marker)
[void]$lines.Add('')

if ($Failure) {
    # The checks refused it. What the script printed is the most useful thing to show, and it
    # already names the file or the field at fault.
    [void]$labels.Add('review: failed')

    $text = if (Test-Path -LiteralPath $Failure) { Get-Content -Raw -LiteralPath $Failure } else { $Failure }

    Add-Line '### The submission did not pass'
    Add-Line ''
    Add-Line '```'
    foreach ($line in ($text.TrimEnd() -split "`r?`n")) { Add-Line $line }
    Add-Line '```'
    Add-Line ''
    Add-Line 'Nothing has been listed. Fix the release or the entry, then a maintainer can comment'
    Add-Line '**`/recheck`** to run this again.'
}
else {
    if (-not (Test-Path $Report)) { throw "There is no report at $Report." }

    # Not $report: PowerShell does not distinguish it from the $Report parameter, and assigning
    # an array to a [string] parameter joins it into one line.
    $reportLines = @(Get-Content -Raw -LiteralPath $Report).TrimEnd() -split "`r?`n"

    # The report's own title repeats the repository, which the issue title already says.
    $start = 0
    if ($reportLines.Count -gt 0 -and $reportLines[0] -like '# Submission:*') {
        $start = 1
        while ($start -lt $reportLines.Count -and [string]::IsNullOrWhiteSpace($reportLines[$start])) { $start++ }
    }

    Add-Line '### Checked against the release'
    Add-Line ''
    for ($i = $start; $i -lt $reportLines.Count; $i++) {
        # The report's own headings sit under the one above, so they move down a level.
        Add-Line ($reportLines[$i] -replace '^## ', '### ')
    }
    Add-Line ''

    $verdict = $null
    $reason = $null
    $detail = $null
    if ($Review -and (Test-Path $Review)) {
        $result = (Get-Content -Raw -LiteralPath $Review | ConvertFrom-Json).results | Select-Object -First 1
        if ($result) {
            $verdict = $result.verdict
            $reason = $result.reason
            $detail = $result.detail
        }
    }

    if ($ReviewPending) {
        Add-Line '### Review'
        Add-Line ''
        Add-Line 'The automated review is running now.'
        Add-Line ''
        [void]$labels.Add('review: running')
    }
    elseif ($verdict) {
        Add-Line '### Review'
        Add-Line ''
        Add-Line "**$verdict** - $reason"
        Add-Line ''
        if ($detail) {
            # Collapsed: the submitter gets the sentence above, the maintainer can open this.
            Add-Line '<details><summary>What the review service said</summary>'
            Add-Line ''
            Add-Line '```'
            foreach ($line in ($detail -split "`r?`n")) { Add-Line $line }
            Add-Line '```'
            Add-Line ''
            Add-Line '</details>'
            Add-Line ''
        }
        [void]$labels.Add("review: $verdict")
    }
    elseif ($ReviewError) {
        [void]$labels.Add('review: error')

        $why = if (Test-Path -LiteralPath $ReviewError) {
            (Get-Content -Raw -LiteralPath $ReviewError).Trim()
        }
        else {
            $ReviewError
        }

        Add-Line '### Review'
        Add-Line ''
        Add-Line 'The automated review did not finish this time, so nothing was decided.'
        Add-Line ''
        Add-Line '<details><summary>What happened</summary>'
        Add-Line ''
        Add-Line '```'
        foreach ($line in ($why.TrimEnd() -split "`r?`n")) { Add-Line $line }
        Add-Line '```'
        Add-Line ''
        Add-Line '</details>'
        Add-Line ''
    }
    else {
        [void]$labels.Add('review: none')
    }

    Add-Line '---'
    Add-Line ''

    if ($ReviewPending) {
        Add-Line 'The checks are done; the review takes a few minutes. This comment updates by itself.'
    }
    elseif ($ReviewError) {
        Add-Line 'The checks above passed. A maintainer can comment **`/recheck`** to run the checks and'
        Add-Line 'the review again.'
    }
    else {
        switch ($verdict) {
            'ok' {
                Add-Line 'This passes every check and the review agrees, so the pull request is opened'
                Add-Line 'automatically. A maintainer can comment **`/recheck`** to run this again.'
            }
            'unsure' {
                Add-Line 'The review was not certain, so this waits for a person. A maintainer can comment'
                Add-Line '**`/recheck`** to run the checks and the review again, or **`/create-pr`** to list it anyway.'
            }
            'refuse' {
                Add-Line 'The review refused this one. A maintainer who has read it and disagrees can comment'
                Add-Line '**`/create-pr force`**; **`/recheck`** runs it again.'
            }
            default {
                Add-Line 'No review service is configured, so the checks are the gate and the pull request is'
                Add-Line 'opened automatically. A maintainer can comment **`/recheck`** to run this again.'
            }
        }
    }

    Add-Line ''
    Add-Line '<sub>`/recheck`, `/create-pr` and `/create-pr force` only work for people with write access.</sub>'
}

# No BOM and LF endings: this is read by `gh`, which is not a Windows program.
$full = Resolve-FullPath $OutFile
[IO.File]::WriteAllText($full, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

$labelsFull = Resolve-FullPath $LabelsFile
[IO.File]::WriteAllText($labelsFull, (($labels -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Comment: $full"
Write-Host "Labels: $($labels -join ', ')"
