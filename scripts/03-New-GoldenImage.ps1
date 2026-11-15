#Requires -Version 5.1
<#
.SYNOPSIS
    Module 03 - Builds generalized Gen 2 "golden" parent VHDX files straight from the Windows Server ISO.
.DESCRIPTION
    The WIM inside Microsoft media is already generalized (it is a Sysprepped image), so applying it to a
    UEFI/GPT VHDX gives a parent disk that every lab VM can use through a differencing disk.
    This is the same technique as Convert-WindowsImage and the parent-disk step in AutomatedLab/MDT.

    Produces (read-only):
        <LabRoot>\Images\WS2025-Desktop.vhdx
        <LabRoot>\Images\WS2025-Core.vhdx

    Module 03 also walks through the manual Sysprep path (customize a VM, sysprep /generalize, keep its VHDX).
.PARAMETER Edition
    Build only one edition. Default builds both.
.PARAMETER SizeBytes
    Max size of the dynamic VHDX. Default 127 GB (the Hyper-V Manager default).
#>
[CmdletBinding()]
param(
    [ValidateSet('Desktop', 'Core', 'Both')][string]$Edition = 'Both',
    [uint64]$SizeBytes = 127GB,
    [switch]$Force
)

Import-Module "$PSScriptRoot\LabCommon.psm1" -Force
Assert-LabAdmin
$cfg = Get-LabConfig
$imagesDir = Join-Path $cfg.LabRoot 'Images'

$targets = @()
if ($Edition -in 'Desktop', 'Both') { $targets += @{ Name = 'Desktop'; ImageName = $cfg.ImageIndexName } }
if ($Edition -in 'Core', 'Both')    { $targets += @{ Name = 'Core';    ImageName = $cfg.CoreImageName } }

Write-LabLog "Mounting ISO $($cfg.IsoPath)" -Level Step
$iso = Mount-DiskImage -ImagePath $cfg.IsoPath -PassThru
try {
    $isoLetter = ($iso | Get-Volume).DriveLetter
    $wim = "${isoLetter}:\sources\install.wim"
    if (-not (Test-Path $wim)) { $wim = "${isoLetter}:\sources\install.esd" }
    if (-not (Test-Path $wim)) { throw 'No install.wim/install.esd found on the ISO.' }

    Write-LabLog 'Images available on this media:'
    Get-WindowsImage -ImagePath $wim | Format-Table ImageIndex, ImageName -AutoSize | Out-Host

    foreach ($t in $targets) {
        $vhdPath = Join-Path $imagesDir "WS2025-$($t.Name).vhdx"
        if ((Test-Path $vhdPath) -and -not $Force) { Write-LabLog "$vhdPath exists; use -Force to rebuild."; continue }
        if (Test-Path $vhdPath) {
            Set-ItemProperty -Path $vhdPath -Name IsReadOnly -Value $false
            Remove-Item $vhdPath -Force
        }

        $img = Get-WindowsImage -ImagePath $wim | Where-Object ImageName -eq $t.ImageName
        if (-not $img) { throw "Image '$($t.ImageName)' not found on media. Fix ImageIndexName/CoreImageName in LabConfig.psd1 using the table above." }

        Write-LabLog "Creating $vhdPath from index $($img.ImageIndex) ($($t.ImageName))" -Level Step
        $vhd = New-VHD -Path $vhdPath -SizeBytes $SizeBytes -Dynamic -BlockSizeBytes 1MB
        $disk = $vhd | Mount-VHD -PassThru | Get-Disk
        try {
            Initialize-Disk -Number $disk.Number -PartitionStyle GPT
            # Remove the automatic MSR so we control the layout: EFI (260 MB) + MSR (16 MB) + Windows
            Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue | Remove-Partition -Confirm:$false -ErrorAction SilentlyContinue

            # Create the ESP as a basic data partition first so it can be formatted and get a letter,
            # then flip it to the EFI GPT type. (Windows will not format a partition already typed as EFI.)
            $esp = New-Partition -DiskNumber $disk.Number -Size 260MB -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' -AssignDriveLetter
            Format-Volume -Partition $esp -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false | Out-Null
            New-Partition -DiskNumber $disk.Number -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null
            $os = New-Partition -DiskNumber $disk.Number -UseMaximumSize -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' -AssignDriveLetter
            Format-Volume -Partition $os -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false | Out-Null

            $espLetter = (Get-Partition -DiskNumber $disk.Number -PartitionNumber $esp.PartitionNumber).DriveLetter
            $osLetter  = (Get-Partition -DiskNumber $disk.Number -PartitionNumber $os.PartitionNumber).DriveLetter

            Write-LabLog "Applying image to ${osLetter}: (takes several minutes)" -Level Step
            Expand-WindowsImage -ImagePath $wim -Index $img.ImageIndex -ApplyPath "${osLetter}:\" | Out-Null

            Write-LabLog 'Writing UEFI boot files with bcdboot'
            & "$env:windir\System32\bcdboot.exe" "${osLetter}:\Windows" /s "${espLetter}:" /f UEFI | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "bcdboot failed ($LASTEXITCODE)" }

            # Stamp the image so learners can tell parents apart
            Set-Content -Path "${osLetter}:\Windows\HVLAB-Image.txt" -Value "HVLAB golden image $($t.Name) built $(Get-Date -Format s) from $($t.ImageName)"

            Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $esp.PartitionNumber -AccessPath "${espLetter}:\"
            Set-Partition -DiskNumber $disk.Number -PartitionNumber $esp.PartitionNumber -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
        } finally {
            Dismount-VHD -Path $vhdPath
        }

        Optimize-VHD -Path $vhdPath -Mode Full
        # Parent disks must never change once children exist, or every child breaks.
        Set-ItemProperty -Path $vhdPath -Name IsReadOnly -Value $true
        Write-LabLog "Golden image ready: $vhdPath ($([math]::Round((Get-Item $vhdPath).Length/1GB,1)) GB on disk)" -Level Ok
    }
} finally {
    Dismount-DiskImage -ImagePath $cfg.IsoPath | Out-Null
}
Write-LabLog 'Next: 04-New-LabVMs.ps1' -Level Ok
