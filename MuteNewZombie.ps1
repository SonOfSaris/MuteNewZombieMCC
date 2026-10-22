<#
.SYNOPSIS
    Mutes (or restores) the "New Zombie" announcer line in Halo 3, Halo: The Master Chief
    Collection on PC.

.DESCRIPTION
    Halo 3 keeps its sounds in halo3\fmod\pc\sfx.fsb. This script finds every language's
    "multiplayer_<language>\infection\new_zombie" sound in YOUR copy of that file and rewrites
    only that sound's audio data so it plays as silence of the same length. Nothing else in the
    file changes, and the file keeps its size. No game files ship with this script.

    Before changing anything it saves the original bytes of each muted sound in a "backup"
    folder next to this script, so -Restore can put them back. Steam's "Verify integrity of
    game files" also restores the original file.

.PARAMETER Path
    The game folder, its halo3\fmod\pc folder, or sfx.fsb itself. Optional: without it the
    script looks for MCC in your Steam libraries.

.PARAMETER Restore
    Put the original New Zombie sounds back (needs the backup made when they were muted).

.PARAMETER Check
    Only report whether each New Zombie sound is muted or original. Changes nothing.

.PARAMETER Lang
    Only these languages: cht de en fr it jpn kor mx pt sp. Default: all of them.

.EXAMPLE
    .\MuteNewZombie.ps1
.EXAMPLE
    .\MuteNewZombie.ps1 -Restore
.EXAMPLE
    .\MuteNewZombie.ps1 "D:\SteamLibrary\steamapps\common\Halo The Master Chief Collection" -Lang en
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Path,
    [switch]$Restore,
    [switch]$Check,
    [string[]]$Lang
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.0'
$SoundName = 'new_zombie'
$MccFolder = 'Halo The Master Chief Collection'
$BankRelative = 'halo3\fmod\pc\sfx.fsb'
# Halo 3's two Vorbis setups (by the CRC32 FMOD stores per sound): ad11d38d (stereo) and
# 632b1fac (mono), in decimal because PowerShell reads 0xad11d38d as a negative Int32. Both
# have two modes: mode 0 = short block, mode 1 = long block.
$KnownSetups = @([long]2903626637, [long]1663770540)
$GameProcesses = @('MCC-Win64-Shipping', 'MCC-Win64-Shipping-EAC', 'mcclauncher')
$BackupDir = Join-Path $PSScriptRoot 'backup'

function Say([string]$Text, [string]$Color = 'Gray') { Write-Host $Text -ForegroundColor $Color }

function Get-Sha256([byte[]]$Bytes) {
    $h = [System.Security.Cryptography.SHA256]::Create()
    try { return (($h.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $h.Dispose() }
}

function Find-Bank {
    param([string]$Given)
    if ($Given) {
        $Given = $Given.Trim().Trim('"')
        $tries = @($Given,
                   (Join-Path $Given 'sfx.fsb'),
                   (Join-Path $Given $BankRelative),
                   (Join-Path $Given 'fmod\pc\sfx.fsb'),
                   (Join-Path $Given ('Content\' + $BankRelative)))
        foreach ($t in $tries) {
            if ((Test-Path -LiteralPath $t -PathType Leaf) -and ((Split-Path $t -Leaf) -eq 'sfx.fsb')) { return (Resolve-Path -LiteralPath $t).ProviderPath }
        }
        throw "No halo3\fmod\pc\sfx.fsb found at: $Given"
    }
    $steamRoots = New-Object System.Collections.Generic.List[string]
    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        try {
            $item = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            foreach ($name in @('SteamPath', 'InstallPath')) {
                if ($item.PSObject.Properties[$name] -and $item.$name) { $steamRoots.Add(($item.$name -replace '/', '\')) }
            }
        } catch { }
    }
    $steamRoots.Add('C:\Program Files (x86)\Steam')
    $libraries = New-Object System.Collections.Generic.List[string]
    foreach ($root in $steamRoots) {
        $libraries.Add($root)
        $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($m in [regex]::Matches([System.IO.File]::ReadAllText($vdf), '"path"\s+"([^"]+)"')) {
                $libraries.Add(($m.Groups[1].Value -replace '\\\\', '\'))
            }
        }
    }
    foreach ($lib in ($libraries | Select-Object -Unique)) {
        $p = Join-Path $lib ("steamapps\common\$MccFolder\" + $BankRelative)
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if ($drive.DriveType -ne 'Fixed') { continue }
        $p = Join-Path $drive.RootDirectory.FullName ("XboxGames\$MccFolder\Content\" + $BankRelative)
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    throw "Couldn't find Halo: The Master Chief Collection. Run the script again with the game folder, for example:`n  .\MuteNewZombie.ps1 `"D:\SteamLibrary\steamapps\common\$MccFolder`"`n(or drag the game folder onto the .bat file)"
}

function Read-Exactly([System.IO.Stream]$Stream, [long]$Offset, [int]$Count) {
    $buf = New-Object byte[] $Count
    [void]$Stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
    $done = 0
    while ($done -lt $Count) {
        $n = $Stream.Read($buf, $done, $Count - $done)
        if ($n -le 0) { throw "Unexpected end of file at offset $($Offset + $done)" }
        $done += $n
    }
    return ,$buf
}

# Every New Zombie sound in the bank: index, language, where its data sits, its setup CRC.
function Get-Targets([string]$Bank) {
    $info = $Bank + '.info'
    if (-not (Test-Path -LiteralPath $info -PathType Leaf)) { throw "Missing $info (needed to tell the languages apart)." }
    $fs = [System.IO.File]::Open($Bank, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $h = Read-Exactly $fs 0 0x3C
        if ([System.Text.Encoding]::ASCII.GetString($h, 0, 4) -ne 'FSB5') { throw "$Bank is not an FMOD FSB5 sound bank." }
        $ver = [BitConverter]::ToUInt32($h, 4); $count = [BitConverter]::ToUInt32($h, 8)
        $shSize = [BitConverter]::ToUInt32($h, 12); $nameSize = [BitConverter]::ToUInt32($h, 16)
        $dataSize = [long][BitConverter]::ToUInt32($h, 20); $codec = [BitConverter]::ToUInt32($h, 24)
        if ($ver -ne 1 -or $codec -ne 15) { throw "Unexpected sound bank format (FSB5 version $ver, codec $codec); expected version 1, Vorbis (15)." }
        if ($nameSize -eq 0) { throw 'The sound bank has no name table.' }
        $sh = Read-Exactly $fs 0x3C ([int]$shSize)
        $names = Read-Exactly $fs (0x3C + [long]$shSize) ([int]$nameSize)
        $dataStart = 0x3C + [long]$shSize + [long]$nameSize
        $fileSize = $fs.Length
    } finally { $fs.Dispose() }
    $infoBytes = [System.IO.File]::ReadAllBytes($info)
    if ($infoBytes.Length -ne 280 * [long]$count) { throw "$info doesn't match the sound bank ($($infoBytes.Length) bytes for $count sounds)." }

    $want = [System.Text.Encoding]::ASCII.GetBytes($SoundName + [char]0)
    $offsets = New-Object long[] $count
    $crcs = New-Object long[] $count
    $pos = 0
    for ($i = 0; $i -lt $count; $i++) {
        $lo = [long][BitConverter]::ToUInt32($sh, $pos); $hi = [long][BitConverter]::ToUInt32($sh, $pos + 4); $pos += 8
        $offsets[$i] = (($lo -shr 7) -bor (($hi -band 3) -shl 25)) * 32
        $crcs[$i] = -1
        $more = $lo -band 1
        while ($more) {
            $c = [long][BitConverter]::ToUInt32($sh, $pos); $pos += 4
            $more = $c -band 1; $size = ($c -shr 1) -band 0xFFFFFF; $kind = ($c -shr 25) -band 0x7F
            if ($kind -eq 11 -and $size -ge 4) { $crcs[$i] = [long][BitConverter]::ToUInt32($sh, $pos) }
            $pos += $size
        }
    }
    $targets = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $count; $i++) {
        $o = [BitConverter]::ToUInt32($names, 4 * $i)
        if ($o + $want.Length -gt $names.Length -or $names[$o] -ne $want[0]) { continue }
        $match = $true
        for ($k = 1; $k -lt $want.Length; $k++) { if ($names[$o + $k] -ne $want[$k]) { $match = $false; break } }
        if (-not $match) { continue }
        $src = [System.Text.Encoding]::ASCII.GetString($infoBytes, 280 * $i + 0x18, 256).Split([char]0)[0]
        $m = [regex]::Match($src, '\\multiplayer_([a-z]+)\\infection\\new_zombie\.aif$')
        if (-not $m.Success) { continue }
        $end = if ($i + 1 -lt $count) { $offsets[$i + 1] } else { $dataSize }
        $targets.Add([pscustomobject]@{ Index = $i; Lang = $m.Groups[1].Value; Source = $src; Offset = $dataStart + $offsets[$i]
                                         Length = [int]($end - $offsets[$i]); Crc = $crcs[$i] })
    }
    return [pscustomobject]@{ FileSize = $fileSize; Targets = $targets }
}

# The muted form of a sound's data: every Vorbis audio packet keeps its size and position and
# its header bits (packet type, mode, and on long blocks the two window flags); every bit after
# them is zeroed, which marks each channel unused, so the packet decodes to silence.
function Get-MutedSlot([byte[]]$Slot, [long]$Crc) {
    if ($KnownSetups -notcontains $Crc) { throw ('Unknown Vorbis setup {0:x8}; this script only knows Halo 3''s.' -f $Crc) }
    $out = [byte[]]$Slot.Clone()
    $p = 0; $packets = 0
    while ($p + 2 -le $out.Length) {
        $size = [BitConverter]::ToUInt16($out, $p)
        if ($size -eq 0) { break }
        if ($p + 2 + $size -gt $out.Length) { throw 'A sound packet runs past its data; the file may be damaged.' }
        $first = $out[$p + 2]
        if ($first -band 1) { throw 'Not a Vorbis audio packet; the file may be damaged or of another version.' }
        $mode = ($first -shr 1) -band 1
        $keepMask = if ($mode -eq 1) { 0x0F } else { 0x03 }
        $out[$p + 2] = [byte]($first -band $keepMask)
        if ($size -gt 1) { [Array]::Clear($out, $p + 3, $size - 1) }
        $p += 2 + $size; $packets++
    }
    if ($packets -eq 0) { throw 'No audio packets found.' }
    return ,$out
}

function Get-RunningGame {
    $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $GameProcesses -contains $_.ProcessName -or $_.ProcessName -like 'project-reclaimer-client*' })
    return (($running | ForEach-Object { $_.ProcessName } | Select-Object -Unique) -join ', ')
}

function Backup-Paths($Target) {
    $base = Join-Path $BackupDir ("new_zombie_{0}" -f $Target.Lang)
    return [pscustomobject]@{ Json = $base + '.json'; Bin = $base + '.bin' }
}

try {
    Say "New Zombie mute $ScriptVersion" 'Cyan'
    $bank = Find-Bank $Path
    Say "Sound bank: $bank"
    $scan = Get-Targets $bank
    $targets = $scan.Targets.ToArray()  # @() on this List throws "Argument types do not match" in Windows PowerShell 5.1
    if ($Lang) {
        $Lang = @($Lang | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
        $unknown = @($Lang | Where-Object { @($targets | ForEach-Object { $_.Lang }) -notcontains $_ })
        if ($unknown.Count) { throw ("Unknown language(s): " + ($unknown -join ', ') + ". Available: " + (($targets | ForEach-Object { $_.Lang }) -join ' ')) }
        $targets = @($targets | Where-Object { $Lang -contains $_.Lang })
    }
    if (-not $targets.Count) { throw 'No New Zombie sound found in this sound bank.' }

    # Current state of every target
    $fs = [System.IO.File]::Open($bank, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        foreach ($t in $targets) {
            $slot = Read-Exactly $fs $t.Offset $t.Length
            $muted = Get-MutedSlot $slot $t.Crc
            $t | Add-Member -NotePropertyName Current -NotePropertyValue $slot
            $t | Add-Member -NotePropertyName Muted -NotePropertyValue $muted
            $t | Add-Member -NotePropertyName CurrentSha -NotePropertyValue (Get-Sha256 $slot)
            $t | Add-Member -NotePropertyName MutedSha -NotePropertyValue (Get-Sha256 $muted)
        }
    } finally { $fs.Dispose() }

    if ($Check) {
        foreach ($t in $targets) {
            $state = if ($t.CurrentSha -eq $t.MutedSha) { 'muted' } else { 'original (not muted)' }
            Say ("  {0,-4} {1}" -f $t.Lang, $state) $(if ($state -eq 'muted') { 'Green' } else { 'Yellow' })
        }
        exit 0
    }

    $writes = New-Object System.Collections.Generic.List[object]
    if (-not $Restore) {
        foreach ($t in $targets) {
            if ($t.CurrentSha -eq $t.MutedSha) { Say ("  {0,-4} already muted" -f $t.Lang) 'Green'; continue }
            $writes.Add([pscustomobject]@{ Target = $t; Data = $t.Muted; Sha = $t.MutedSha; Done = 'muted' })
        }
        if ($writes.Count) {
            if (-not (Test-Path -LiteralPath $BackupDir)) { [void](New-Item -ItemType Directory -Path $BackupDir) }
            foreach ($w in $writes) {
                $t = $w.Target; $b = Backup-Paths $t
                [System.IO.File]::WriteAllBytes($b.Bin, $t.Current)
                $meta = [ordered]@{ script_version = $ScriptVersion; bank = $bank; bank_size = $scan.FileSize; index = $t.Index; source = $t.Source
                                    offset = $t.Offset; length = $t.Length; original_sha256 = $t.CurrentSha; muted_sha256 = $t.MutedSha
                                    saved = (Get-Date).ToString('s') }
                [System.IO.File]::WriteAllText($b.Json, ($meta | ConvertTo-Json))
                if ((Get-Sha256 ([System.IO.File]::ReadAllBytes($b.Bin))) -ne $t.CurrentSha) { throw "The backup $($b.Bin) didn't save correctly; nothing was changed." }
            }
        }
    } else {
        foreach ($t in $targets) {
            $b = Backup-Paths $t
            if ($t.CurrentSha -ne $t.MutedSha) { Say ("  {0,-4} not muted: nothing to restore" -f $t.Lang) 'Green'; continue }
            if (-not (Test-Path -LiteralPath $b.Bin) -or -not (Test-Path -LiteralPath $b.Json)) {
                Say ("  {0,-4} muted, but there's no backup for it here. Use Steam's `"Verify integrity of game files`" to restore it." -f $t.Lang) 'Yellow'; continue
            }
            $meta = Get-Content -LiteralPath $b.Json -Raw | ConvertFrom-Json
            $orig = [System.IO.File]::ReadAllBytes($b.Bin)
            if ([long]$meta.offset -ne $t.Offset -or [int]$meta.length -ne $t.Length -or [long]$meta.bank_size -ne $scan.FileSize -or
                $meta.muted_sha256 -ne $t.MutedSha -or (Get-Sha256 $orig) -ne $meta.original_sha256) {
                Say ("  {0,-4} the backup doesn't match this file (was the game updated?). Use Steam's `"Verify integrity of game files`" instead." -f $t.Lang) 'Yellow'; continue
            }
            $writes.Add([pscustomobject]@{ Target = $t; Data = $orig; Sha = $meta.original_sha256; Done = 'restored' })
        }
    }

    if ($writes.Count) {
        try {
            $fs = [System.IO.File]::Open($bank, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        } catch {
            # Exclusive access fails while anything (the game, Steam) has the file open
            $game = Get-RunningGame
            $why = if ($game) { "Another program has it open. Close the game (running now: $game) and try again." } else { "Close the game and Steam's file verification, then try again. If the game is installed under Program Files, run this as administrator." }
            throw "Can't write to the sound bank. $why`n($($_.Exception.Message))"
        }
        try {
            if ($fs.Length -ne $scan.FileSize) { throw 'The sound bank changed while the script was running; nothing was written.' }
            foreach ($w in $writes) {
                [void]$fs.Seek($w.Target.Offset, [System.IO.SeekOrigin]::Begin)
                $fs.Write($w.Data, 0, $w.Data.Length)
            }
            $fs.Flush()
            foreach ($w in $writes) {
                $now = Read-Exactly $fs $w.Target.Offset $w.Target.Length
                if ((Get-Sha256 $now) -ne $w.Sha) { throw "Verification failed for $($w.Target.Lang); restore with Steam's `"Verify integrity of game files`"." }
                Say ("  {0,-4} {1}" -f $w.Target.Lang, $w.Done) 'Green'
            }
        } finally { $fs.Dispose() }
    }
    if ($writes.Count -and -not $Restore) { Say "Backup of the original sounds: $BackupDir" }
    Say 'Done.' 'Cyan'
    exit 0
} catch {
    Say ("Error: " + $_.Exception.Message) 'Red'
    Say ("(script line {0}, PowerShell {1})" -f $_.InvocationInfo.ScriptLineNumber, $PSVersionTable.PSVersion) 'DarkGray'
    exit 1
}
