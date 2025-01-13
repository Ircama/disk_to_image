# Disk_To_Image.ps1
param(
    [Parameter(Mandatory=$false)]
    [switch]$Help,

    [Parameter(Mandatory=$false)]
    [string]$DiskNumber,

    [Parameter(Mandatory=$false)]
    [string]$Destination,
    
    [Parameter(Mandatory=$false)]
    [switch]$UsePartitions,
    
    [Parameter(Mandatory=$false)]
    [int]$FirstPartition,
    
    [Parameter(Mandatory=$false)]
    [int]$LastPartition,
    
    [Parameter(Mandatory=$false)]
    [string]$BufferSize = "1MB",

    [Parameter(Mandatory=$false)]
    [switch]$NoVerify,

    [Parameter(Mandatory=$false)]
    [switch]$OnlyVerify,

    [Parameter(Mandatory=$false)]
    [switch]$Force,

    [Parameter(Mandatory=$false)]
    [long]$OffsetVerify = 0,

    [Parameter(Mandatory=$false)]
    [int]$RetryVerify = 20,

    [Parameter(Mandatory=$false)]
    [int]$SectorSize = 512,

    [Parameter(Mandatory=$false)]
    [switch]$DebugRetryVerify
)

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class VolumeManagement {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern bool SetVolumeMountPoint(
        string lpszVolumeMountPoint,
        string lpszVolumeName);
        
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern bool DeleteVolumeMountPoint(
        string lpszVolumeMountPoint);
}
"@

function Disable-VolumeMountPoint {
    param (
        [Parameter(Mandatory=$true)]
        [object]$Volume,
        [Parameter(Mandatory=$true)]
        [string]$DriveLetter,
        [Parameter(Mandatory=$true)]
        [bool]$Force
    )
    
    $disabledMountPoints = @()  # Initialize an array to hold the disabled mount points

    try {
        $mountPoint = $DriveLetter + ":\"  # Construct the mount point path
        if (-not $Force) {
            Write-Host "Please confirm disabling mount point $DriveLetter`: (Y/N): " -NoNewLine -ForegroundColor Green
            $confirmation = Read-Host
            if ($confirmation -ne 'Y') {
                Write-Host "Mount point $DriveLetter`: not disabled" -ForegroundColor Cyan
                continue
            }
        }
        $result = [VolumeManagement]::DeleteVolumeMountPoint($mountPoint)
        
        if ($result) {
            Write-Host "Disabled mount point $DriveLetter`:." -ForegroundColor Yellow
            # Add the successfully disabled mount point to the array
            $disabledMountPoints = [PSCustomObject]@{
                MountPoint = $DriveLetter
                Volume     = $volume.UniqueId
            }
        } else {
            Write-Host "Mount point $DriveLetter`: already disabled." -ForegroundColor Cyan
        }
    }
    catch {
        Write-Host "Failed to disable mount point: $_`n" -ForegroundColor Red
        exit 1
    }

    return $disabledMountPoints  # Return the array of disabled mount points
}

function Enable-VolumeMountPoint {
    param (
        [Parameter(Mandatory=$true)]
        [array]$DisabledMountPoints,
        [bool]$Force
    )
    
    try {
        foreach ($entry in $DisabledMountPoints) {
            $DriveLetter = $entry.MountPoint
            $volume = $entry.Volume

            # Mount the drive again
            if (-not $Force) {
                Write-Host "`nPlease confirm enabling mount point $DriveLetter`: previously disabled (Y/N): " -NoNewLine -ForegroundColor Green
                $confirmation = Read-Host
                if ($confirmation -ne 'Y') {
                    Write-Host "Mount point $DriveLetter`: not enabled" -ForegroundColor Cyan
                    continue
                }
            }
            $MountPoint = $DriveLetter + ":\"
            $result = [VolumeManagement]::SetVolumeMountPoint($MountPoint, $volume)

            if ($result) {
                Write-Host "Enabled again mount point $DriveLetter`:." -ForegroundColor Yellow
            } else {
                Write-Host "Mount point $DriveLetter`: could not be remounted." -ForegroundColor Red
            }
        }
    }
    catch {
        Write-Host "Failed to enable mount points: $_`n" -ForegroundColor Red
        exit 1
    }
}

if ($NoVerify -and $OnlyVerify) {
    Write-Host "`nInvalid parameters. Either -NoVerify or -OnlyVerify.`n" -ForegroundColor Red
    $Help = $true
}

if ($FirstPartition -or $LastPartition) {
    $UsePartitions = $true
}

if ($Help) {
    Write-Host @"
Usage: disk_to_image.ps1 -DiskNumber <string> -Destination <string> [options]

Description:
  Copy disk to file image.

  This script reads disk data writing an image file, allowing you to specify
  partitions, buffer size, and verification options.

Needed Parameters:
  -DiskNumber         The number of the disk to process (e.g., "2").
  -Destination        The destination where data should be written (e.g.,
                      "C:\save\to\imagine.bin").

Optional Parameters:
  -UsePartitions      Use this switch to enable partition-specific operations.
  -FirstPartition     Specify the first partition to process (e.g., "1") or use
                      "0" for for disk start. Requires -UsePartitions.
  -LastPartition      Specify the last partition to process (e.g., "4").
                      Default is last partition. Requires -UsePartitions.
  -BufferSize         Specify the buffer size for the operation in MB
                      (default: 1MB).
                      Example: -BufferSize 10MB
  -NoVerify           Skip verification step (default is to verify)
  -Force              Do not ask any confirmation
  -OnlyVerify         Only perform the verification process, without copying
  -OffsetVerify       Start verification from given offset (
  -DebugRetryVerify   Write debug information when verify temporarily fails
  -RetryVerify        Number of verification retries of reading a sector
                      before showing error (default: 20)
  -SectorSize         Sector size in bytes (default is 512 bytes)
  -help               Show this help message.

Examples:
  # Read Disk 2 and output to C:\save\to\imagine.bin with default settings:
  .\disk_to_image.ps1 -DiskNumber 2 -Destination "C:\save\to\imagine.bin"

  # Read Disk 2 with partitions 1 to 3 and a 10MB buffer:
  .\disk_to_image.ps1 2 "C:\save\to\imagine.bin" -UsePartitions `
                   -FirstPartition 1 -LastPartition 3 -BufferSize 10MB

  # Read Disk 2 without verification:
  .\disk_to_image.ps1 2 "C:\save\to\imagine.bin" -NoVerify

"@ -ForegroundColor Cyan
    exit 2
}

# Convert BufferSize string (e.g., "10MB", "1KB", "100G") into bytes
if ($BufferSize -match "^(\d+)([KMG])B$") {
    $size = [int]$matches[1]
    $unit = $matches[2]

    switch ($unit) {
        "K" { [long]$BufferSize = $size * 1KB }
        "M" { [long]$BufferSize = $size * 1MB }
        "G" { [long]$BufferSize = $size * 1GB }
        default { throw "Invalid BufferSize format. Use formats like '1M', '10M', or '512K'." }
    }
} elseif ($BufferSize -eq "1MB") {
    # Default value check, no conversion needed
    [long]$BufferSize = 1MB
} else {
    throw "Invalid BufferSize format. Use formats like '1M', '10M', or '512K'."
}

# Function to validate disk number
function Test-DiskNumber {
    param ([string]$Number)
    $disk = Get-Disk -Number $Number -ErrorAction SilentlyContinue
    return $null -ne $disk
}

# If no disk number provided, ask for it
if (-not $DiskNumber) {
    Write-Host "`nAvailable disks:" -ForegroundColor Green
    Get-Disk | Format-Table -AutoSize
    do {
        $DiskNumber = $(
            Write-Host "Please enter the disk number (e.g., '0', '1', etc.): " -NoNewLine -ForegroundColor Green
            Read-Host
        )
    } while (-not (Test-DiskNumber $DiskNumber))
}

# Check if DiskNumber is numeric, if not, list all disks and ask user to select
if ($DiskNumber -match '^\d+$') {
    # If DiskNumber is a number, proceed with the disk number as entered
    Write-Host "Disk to read: $DiskNumber" -ForegroundColor Cyan
} else {
    # List all available disks
    $disks = Get-WmiObject -Class Win32_DiskDrive | Select-Object DeviceID, MediaType, Model
    Write-Host "Available disks:" -ForegroundColor Green
    $disks | Format-Table

    # Prompt user for a disk number
    $selectedDisk = $(
        Write-Host "Please enter the disk number (e.g., '0', '1', etc.): " -NoNewLine -ForegroundColor Green
        Read-Host
    )


    # Validate if the entered disk exists
    if ($disks.DeviceID -contains "\\.\PHYSICALDRIVE$selectedDisk") {
        # User input matches one of the disks
        Write-Host "`nYou selected disk: $selectedDisk. " -NoNewLine -ForegroundColor Cyan
        $DiskNumber = $selectedDisk
        if ($Force) {
            Write-Host ""
        } else {
            Write-Host "Please confirm (Y/N): " -NoNewLine -ForegroundColor Green
            $confirmation = Read-Host
            if ($confirmation -eq 'Y') {
                Write-Host "Disk selected: $DiskNumber" -ForegroundColor Cyan
            } else {
                Write-Host "`nSelection canceled. Exiting script.`n" -ForegroundColor Yellow
                exit 1
            }
        }

    } else {
        Write-Host "`nInvalid disk number. Exiting script.`n" -ForegroundColor Red
        exit 1
    }
}

$disk = Get-Disk -Number $DiskNumber
$partitions = Get-Partition -DiskNumber $DiskNumber | Sort-Object -Property OffsetInBytes

# Initialize variables
[long]$startOffset = 0
[long]$totalSize = $disk.Size

if ($UsePartitions) {
    # Display available partitions

    if ((-not $PSBoundParameters.ContainsKey('FirstPartition')) -or (-not $PSBoundParameters.ContainsKey('LastPartition'))) {
        Write-Host "`nAvailable partitions:" -ForegroundColor Green
        $partitions | Format-Table -Property PartitionNumber, Type, Size, Offset, DriveLetter
    }

    # If not provided as parameters, ask for partition range
    if (-not $PSBoundParameters.ContainsKey('FirstPartition')) {
        $input = $(
            Write-Host "Enter first partition number (default: 0 for disk start): " -NoNewLine -ForegroundColor Green
            Read-Host
        )
        if ($input -ne '') {
            $FirstPartition = [int]$input
        }
    }

    if (-not $PSBoundParameters.ContainsKey('LastPartition')) {
        $input = $(
            Write-Host "Enter last partition number (default: last partition): " -NoNewLine -ForegroundColor Green
            Read-Host
        )
        if ($input -ne '') {
            $LastPartition = [int]$input
        }
    }

    # Calculate start offset and size based on partitions
    if ($FirstPartition) {
        $firstPart = $partitions | Where-Object { $_.PartitionNumber -eq $FirstPartition }
        if ($firstPart) {
            [long]$startOffset = $firstPart.Offset
        } else {
            Write-Host "`nAvailable partitions:" -ForegroundColor Green
            $partitions | Format-Table -Property PartitionNumber, Type, Size, Offset, DriveLetter
            Write-Host "Invalid first partition $FirstPartition.`n" -ForegroundColor Red
            exit 1
        }
    }

    if ($LastPartition) {
        $lastPart = $partitions | Where-Object { $_.PartitionNumber -eq $LastPartition }
        if ($lastPart) {
            [long]$endOffset = $lastPart.Offset + $lastPart.Size
            [long]$totalSize = $endOffset - $startOffset
        } else {
            Write-Host "`nAvailable partitions:" -ForegroundColor Green
            $partitions | Format-Table -Property PartitionNumber, Type, Size, Offset, DriveLetter
            Write-Host "Invalid last partition $LastPartition.`n" -ForegroundColor Red
            exit 1
        }
    }
}

# Get the device path for the disk
$source = "\\.\PhysicalDrive$DiskNumber"

# Check mandatory parameters manually
if (-not $Destination) {

    $Destination = $(
        Write-Host "`nPlease enter the complete file path for the destination image: " -NoNewLine -ForegroundColor Green
        Read-Host
    )
    if ($input -eq '') {
        Write-Host "`nERROR: Missing destination. Use --help for usage information.`n" -ForegroundColor Red
        exit 1
    }
}

# Extract the directory path from the full destination path
$directory = Split-Path -Path $Destination -Parent

# Check if the directory exists
if (-not (Test-Path -Path $directory)) {
    Write-Host "`nThe destination directory is invalid: $directory`n" -ForegroundColor Red
    exit 1  # Exit the script if the directory does not exist
}

if ((-not $Force) -and (-not $OnlyVerify) -and (Test-Path -Path $Destination)) {
    Write-Host "`nPath " -NoNewline -ForegroundColor Green
    Write-Host "$Destination" -ForegroundColor Yellow -NoNewline
    Write-Host " already exists." -ForegroundColor Green
    $confirmation = $(
        Write-Host "`nPlease confirm overwriting (Y/N): " -NoNewLine -ForegroundColor Green
        Read-Host
    )
    if ($confirmation -ne 'Y') {
        Write-Host "`nOperation canceled. Exiting script.`n" -ForegroundColor Yellow
        exit 1
    }
}

$buffer = New-Object byte[]($BufferSize)
[long]$totalBytesRead = 0
$disabledPoints = @()  # Initialize an array to hold the disabled mount points

# Dismount volumes
try {
    $volumes = Get-Partition -DiskNumber $DiskNumber | Get-Volume
    if (-not $volumes) {
        Write-Host "No volumes found on disk $DiskNumber" -ForegroundColor Red
        exit 1
    }
    Write-Host "Trying to dismount volumes on disk $DiskNumber..." -ForegroundColor Cyan
    foreach ($volume in $volumes) {
        if ($volume.DriveLetter) {
            $disabledPoints += Disable-VolumeMountPoint -Volume $volume -DriveLetter $volume.DriveLetter -Force $Force
        }
    }
} catch {
    Write-Host "`nAn error occurred while dismounting volumes: $_`n" -ForegroundColor Red
    exit 1
}

# Skip to partition offset
$CopyLabel = "Copy"
$CopyingLabel = "Copying"
if ($OnlyVerify) {
    $CopyLabel = "Verify"
    $CopyingLabel = "Verifying"
}
if ($startOffset -gt 0) {
    $srcStream.Seek($startOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
    Write-Host "Offset: $startOffset bytes ($([math]::Round($startOffset / 1GB, 2)) GB)" -ForegroundColor Cyan
    Write-Host "$CopyLabel size: $totalSize bytes ($([math]::Round($totalSize / 1GB, 2)) GB)" -ForegroundColor Cyan
} else {
    Write-Host "$CopyingLabel $totalSize bytes ($([math]::Round($totalSize / 1GB, 2)) GB) from the start of the disk." -ForegroundColor Cyan
}
if (-not $Force) {
    $confirmation = $(
        Write-Host "`nConfirm the above parameters (Y/N): " -NoNewLine -ForegroundColor Green
        Read-Host
    )
    if ($confirmation -eq 'Y') {
        Write-Host "Disk selected: $DiskNumber" -ForegroundColor Cyan
    } else {
        Write-Host "`nSelection canceled. Exiting script.`n" -ForegroundColor Yellow
        exit 1
    }
}

if (-not $OnlyVerify) {
    Write-Host "Creating disk image..." -ForegroundColor Cyan
    [Console]::Out.Flush()

    # Open streams for reading and writing
    try {
        $srcStream = [System.IO.File]::OpenRead($source)
    } catch {
        Write-Host "`nError: The source disk cannot be read." -ForegroundColor Red
        Write-Host "`nDetails: $_`n" -ForegroundColor Red
        exit 1
    }

    try {
        $destStream = [System.IO.File]::Create($Destination)
    } catch {
        Write-Host "`nError: The destination file is busy or the stream is invalid." -ForegroundColor Red
        Write-Host "`nDetails: $_`n" -ForegroundColor Red
        exit 1
    }

    # Copy the disk
    $dotCount = 0
    $interruptOccurred = $true
    try {
        while ([long]$totalBytesRead -lt [long]$totalSize) {
            [long]$remainingBytes = [long]$totalSize - [long]$totalBytesRead
            [long]$readSize = [Math]::Min([long]$BufferSize, [long]$remainingBytes)
            
            [long]$bytesRead = $srcStream.Read($buffer, 0, [long]$readSize)
            
            if ($bytesRead -eq 0) { break }
            
            try {
                $destStream.Write($buffer, 0, $bytesRead)
            } catch {
                Write-Host "`nError: The destination file is busy or the stream is invalid.`n" -ForegroundColor Red
                exit 1
            }

            $totalBytesRead += $bytesRead
            Write-Host "." -NoNewline
            $dotCount++
            
            if ($dotCount -ge 80) {
                $percentage = ([long]$totalBytesRead / [long]$totalSize) * 100
                Write-Host "`r $([math]::Round($percentage, 1))% " -NoNewline
                $dotCount = 0  # Reset counter
                [Console]::Out.Flush()
            }
        }
        $interruptOccurred = $false
    } finally {
        # Ensure that the destination stream is closed and the file is released
        $destStream.Close()
        $destStream.Dispose()
        $srcStream.Close()
        if ($interruptOccurred) {
            if ($disabledPoints) {
                Write-Host ""
                Enable-VolumeMountPoint -DisabledMountPoints $disabledPoints -Force $Force
            }
            Write-Host "`nInterrupted.`n" -ForegroundColor Cyan
        } else {
            Write-Host "`r Completed "
        }
    }

    Write-Host "Disk image created successfully!" -ForegroundColor Cyan
    [Console]::Out.Flush()
}

if ($NoVerify) {
    Write-Host "Verification is disabled. Program completed.`n" -ForegroundColor Cyan
    exit
}

# Verification Step
Write-Host "Verifying disk image..." -ForegroundColor Cyan
[Console]::Out.Flush()

$equal = $true
try {
    $fs1 = [System.IO.File]::OpenRead($source)
} catch {
    Write-Host "`nError: The disk is busy or invalid." -ForegroundColor Red
    Write-Host "`nDetails: $_`n" -ForegroundColor Red
    exit 1
}
try {
    $fs2 = [System.IO.File]::OpenRead($Destination)
} catch {
    Write-Host "`nError: The destination file is busy or the stream is invalid." -ForegroundColor Red
    Write-Host "`nDetails: $_`n" -ForegroundColor Red
    exit 1
}

# Increase buffer size for faster reading
$one = New-Object byte[]($BufferSize)
$two = New-Object byte[]($BufferSize)

$dotCount = 0
[long]$totalBytesRead = 0

[long]$OffsetVerify = [long]$OffsetVerify - ([long]$OffsetVerify % $SectorSize)
if ($OffsetVerify -gt 0) {
    Write-Host "Verification starts at offset $OffsetVerify ($([math]::Round($OffsetVerify / 1GB, 2)) GB)." -ForegroundColor Cyan
    $fs1.Seek($OffsetVerify, [System.IO.SeekOrigin]::Begin) | Out-Null
    $fs2.Seek($OffsetVerify, [System.IO.SeekOrigin]::Begin) | Out-Null
    [long]$totalBytesRead = [long]$OffsetVerify
}

$interruptOccurred = $true
$retry = 0
try {
    while ([long]$totalBytesRead -lt [long]$totalSize -and $equal) {
        if ($retry -gt $RetryVerify) {
            $equal = $false
            Write-Host "`nDifferent data content at offset $totalBytesRead ($([math]::Round($totalBytesRead / 1GB, 2)) GB)." -ForegroundColor Red
            break
        }
        if ($retry -eq 0) {
            [long]$remainingBytes = [long]$totalSize - [long]$totalBytesRead
            $readSize = [Math]::Min([long]$BufferSize, [long]$remainingBytes)
        }
        
        [long]$bytesRead1 = $fs1.Read($one, 0, [long]$readSize)
        [long]$bytesRead2 = $fs2.Read($two, 0, [long]$readSize)

        if ($bytesRead1 -ne $bytesRead2) {
            $equal = $false
            Write-Host "`nDifferent Length of read data: source=$bytesRead1 bytes, destination=$bytesRead2 bytes" -ForegroundColor Red
            break
        }
        
        # Memory comparison
        if ([System.Linq.Enumerable]::SequenceEqual($one, $two)) {
            $retry = 0
        } else {
            if ($DebugRetryVerify) {
                Write-Host "`nRetry at offset $totalBytesRead ($([math]::Round($totalBytesRead / 1GB, 2)) GB)." -ForegroundColor Yellow
            }
            $fs1.Seek($totalBytesRead, [System.IO.SeekOrigin]::Begin) | Out-Null
            $fs2.Seek($totalBytesRead, [System.IO.SeekOrigin]::Begin) | Out-Null
            $retry += 1
            continue
        }

        $totalBytesRead += $bytesRead1
        Write-Host "." -NoNewline
        $dotCount++
        
        if ($dotCount -ge 80) {
            $percentage = ([long]$totalBytesRead / [long]$totalSize) * 100
            Write-Host "`r $([math]::Round($percentage, 1))% " -NoNewline
            $dotCount = 0
            [Console]::Out.Flush()
        }
    }
    $interruptOccurred = $false
} finally {
    # Ensure that the destination stream is closed and the file is released
    $fs1.Close()
    $fs2.Close()
    if ($interruptOccurred) {
        Write-Host "`nInterrupted.`n" -ForegroundColor Cyan
    } else {
        if ($equal) {
            Write-Host "`r Completed " -ForegroundColor Cyan
        } else {
            Write-Host "`r"
        }
    }
    if ($disabledPoints) {
        Enable-VolumeMountPoint -DisabledMountPoints $disabledPoints -Force $Force
    }
}

Write-Host ""
if ($equal) {
    Write-Host "Verification successful: Disk image matches source!`n" -ForegroundColor Cyan
} else {
    Write-Host "Verification failed: Disk image does not match source!`n" -ForegroundColor Cyan
}
