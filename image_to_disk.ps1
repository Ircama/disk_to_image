# Image_To_Disk.ps1
param(
    [Parameter(Mandatory=$false)]
    [switch]$Help,

    [Parameter(Mandatory=$false)]
    [string]$Source,
    
    [Parameter(Mandatory=$false)]
    [string]$DiskNumber,

    [Parameter(Mandatory=$false)]
    [int]$Partition,
    
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
    [int]$RetryVerify = 3,

    [Parameter(Mandatory=$false)]
    [int]$SectorSize = 1MB,

    [Parameter(Mandatory=$false)]
    [switch]$DebugRetryVerify
)

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class DiskWriterAPI {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetFilePointerEx(
        IntPtr hFile,
        long liDistanceToMove,
        IntPtr lpNewFilePointer,
        uint dwMoveMethod);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr CreateFile(
        string lpFileName,
        int dwDesiredAccess,
        int dwShareMode,
        IntPtr lpSecurityAttributes,
        int dwCreationDisposition,
        int dwFlagsAndAttributes,
        IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool DeviceIoControl(
        IntPtr hDevice,
        uint dwIoControlCode,
        IntPtr lpInBuffer,
        uint nInBufferSize,
        IntPtr lpOutBuffer,
        uint nOutBufferSize,
        ref uint lpBytesReturned,
        IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool WriteFile(
        IntPtr hFile,
        byte[] lpBuffer,
        uint nNumberOfBytesToWrite,
        ref uint lpNumberOfBytesWritten,
        IntPtr lpOverlapped);

    [DllImport("kernel32.dll")]
    public static extern bool LockFile(
        IntPtr hFile,
        uint dwFileOffsetLow,
        uint dwFileOffsetHigh,
        uint nNumberOfBytesToLockLow,
        uint nNumberOfBytesToLockHigh);

    [DllImport("kernel32.dll")]
    public static extern bool UnlockFile(
        IntPtr hFile,
        uint dwFileOffsetLow,
        uint dwFileOffsetHigh,
        uint nNumberOfBytesToLockLow,
        uint nNumberOfBytesToLockHigh);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool ReadFile(
        IntPtr hFile,
        byte[] lpBuffer,
        uint nNumberOfBytesToRead,
        ref uint lpNumberOfBytesRead,
        IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint SetFilePointer(
        IntPtr hFile,
        int lDistanceToMove,
        IntPtr lpDistanceToMoveHigh,
        uint dwMoveMethod);
}

public class VolumeManagement {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern bool SetVolumeMountPoint(
        string lpszVolumeMountPoint,
        string lpszVolumeName);
        
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern bool DeleteVolumeMountPoint(
        string lpszVolumeMountPoint);
}
"@ 2>&1 | Out-Null

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

function Disable-Automount {
    $tempFile = [System.IO.Path]::GetTempFileName()
    "automount disable" | Out-File -FilePath $tempFile
    diskpart /s $tempFile | Out-Null
    Remove-Item $tempFile
    Write-Host "Automount disabled"
}

# Function to enable automount
function Enable-Automount {
    $tempFile = [System.IO.Path]::GetTempFileName()
    "automount enable" | Out-File -FilePath $tempFile
    diskpart /s $tempFile | Out-Null
    Remove-Item $tempFile
    Write-Host "Automount enabled"
}

if ($NoVerify -and $OnlyVerify) {
    Write-Host "`nInvalid parameters. Either -NoVerify or -OnlyVerify.`n" -ForegroundColor Red
    $Help = $true
}

if ($Partition) {
    $UsePartitions = $true
}

if ($Help) {
    Write-Host @"
Usage: image_to_disk.ps1 -Source <string> -DiskNumber <string> [options]

Description:
  Copy file image to disk.

  This script reads an image file and writes data to disk, allowing you to
   specify whether the entire disk will be written, or only specific partitions.
   It also allows setting options like buffer size and whether to perform
   verification.

Needed Parameters:
  -Source             The source file to be copied to the disk (e.g.,
                      "C:\save\to\imagine.bin").
  -DiskNumber         The destination number of the disk where the file image
                      will be copied (e.g., "2").

Optional Parameters:
  -Partition          Specify the partition to write (e.g., "1").
  -BufferSize         Specify the buffer size for the operation in MB
                      (default: 1MB).
                      Example: -BufferSize 10MB
  -NoVerify           Skip verification step (default is to verify)
  -Force              Do not ask any confirmation
  -OnlyVerify         Only perform the verification process, without copying
  -OffsetVerify       Start verification from given offset
  -DebugRetryVerify   Write debug information when verify temporarily fails
  -RetryVerify        Number of verification retries of reading a sector
                      before showing error (default: 3)
  -SectorSize         Sector size in bytes (default is 512 bytes)
  -help               Show this help message.

Examples:
  # Run the command interactively
  .\image_to_disk.ps1

  # Write C:\save\to\imagine.bin to Disk 2 with default settings:
  .\image_to_disk.ps1 -Source "C:\save\to\imagine.bin" -DiskNumber 2

  # Write to Disk 2, partitions 1 and a 10MB buffer:
  .\image_to_disk.ps1 "C:\save\to\imagine.bin" 2 -Partition 1 -BufferSize 10MB

  # Write to Disk 2 without verification:
  .\image_to_disk.ps1 "C:\save\to\imagine.bin" 2 -NoVerify

"@ -ForegroundColor Cyan
    exit 2
}

# Check if the script is running with administrative privileges
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "The script is not running as administrator. Restarting with elevated privileges..."
    
    # Reconstruct the original command with all parameters
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" "
    
    # Add all the original parameters and their values
    $arguments += $MyInvocation.BoundParameters.GetEnumerator() | ForEach-Object {
        $value = if ($_.Value -is [switch]) {
            "-$($_.Key)"
        } else {
            "-$($_.Key) `"$($_.Value)`""
        }
        $value
    }
    
    try {
        $process = Start-Process powershell -ArgumentList $arguments -Verb RunAs -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            Write-Host "Administrative privileges are required. Terminating."
            exit 1
        }
    }
    catch {
        Write-Host "Administrative privileges are required. Script will now exit."
        exit 1
    }
    exit 0
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

# Check source file
if (-not $Source) {

    $Source = $(
        Write-Host "`nPlease enter the complete file path for the source image: " -NoNewLine -ForegroundColor Green
        Read-Host
    )
    if ($Source -eq '') {
        Write-Host "`nERROR: Missing source. Use --help for usage information.`n" -ForegroundColor Red
        exit 1
    }
}

# Extract the directory path from the full source path
$directory = Split-Path -Path $Source -Parent

# Check if the source directory exists
if (-not $directory) {
    Write-Host "`nUse full pathname of the source image file for safer operation.`n" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -Path $directory)) {
    Write-Host "`nThe source directory is invalid: $directory`n" -ForegroundColor Red
    exit 1
}

if (-not [System.IO.File]::Exists($Source)) {
    Write-Host "`nThe source path does not exist (use full pathnames): $Source`n" -ForegroundColor Red
    exit 1
}

# Get sizes
$imageSize = (Get-Item $Source).Length

if ($imageSize -lt 10) {
    Write-Host "`nThe source image file is too small: $imageSize bytes.`n" -ForegroundColor Red
    exit 1
}

# Function to validate disk number
function Test-DiskNumber {
    param ([string]$Number)
    $disk = Get-Disk -Number $Number -ErrorAction SilentlyContinue
    return $null -ne $disk
}

# If no destination disk number provided, ask for it
if (-not $DiskNumber) {
    Write-Host "`nAvailable destination disks:" -ForegroundColor Green
    Get-Disk | Format-Table -AutoSize
    do {
        $DiskNumber = $(
            Write-Host "Please enter the disk number (e.g., '0', '1', etc.): " -NoNewLine -ForegroundColor Green
            Read-Host
        )
        if ($DiskNumber -match "^\d+$") {
            Write-Host "Entered disk number $DiskNumber." -ForegroundColor Cyan
        } else {
            Write-Host "The entered value is not numeric." -ForegroundColor Red
            $DiskNumber = $null
        }
    } while (-not (Test-DiskNumber $DiskNumber))
}

# Check if DiskNumber is numeric, if not, list all disks and ask user to select
if ($DiskNumber -match '^\d+$') {
    # If DiskNumber is a number, proceed with the disk number as entered
    Write-Host "Disk to write/verify: $DiskNumber" -ForegroundColor Cyan
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

# If no arguments are provided, prompt for UsePartitions
if ($MyInvocation.BoundParameters.Count -eq 0) {
    Write-Host "`nDo you want to use partitions? (y/n): " -NoNewLine -ForegroundColor Green
    $response = Read-Host
    $UsePartitions = $response.ToLower() -eq 'y'
}

$disk = Get-Disk -Number $DiskNumber
$partitions = Get-Partition -DiskNumber 2 -ErrorVariable partitionError -ErrorAction SilentlyContinue
if (-not $partitions) {
    $partitions = 0
}

if ((-not $partitions -or $partitions -eq 0) -and $UsePartitions) {
    Write-Host "Error: using partitions while the target disk has no partition.`n" -ForegroundColor Red
    exit 1
}

# Initialize variables
[long]$startOffset = 0
[long]$totalSize = $disk.Size
[long]$endOffset = $totalSize

if ($UsePartitions) {
    # Display available partitions

    if (-not $PSBoundParameters.ContainsKey('Partition')) {
        Write-Host "`nAvailable partitions:" -ForegroundColor Green
        $partitions | Format-Table -Property PartitionNumber, Type, Size, @{ Name='GB'; Expression={ '{0:N2} GB' -f ($_.Size / 1gb) } }, Offset, @{ Name='GB'; Expression={ '{0:N2} GB' -f ($_.Offset / 1gb) } }, DriveLetter
    }

    # If not provided as parameters, ask for partition range
    if (-not $PSBoundParameters.ContainsKey('Partition')) {
        $input = $(
            Write-Host "Enter the partition number to use: " -NoNewLine -ForegroundColor Green
            Read-Host
        )
        if ($input -ne '') {
            $Partition = [int]$input
        }
    }

    if ($Partition -eq 0) {
        Write-Host "Invalid partition $Partition.`n" -ForegroundColor Red
        exit 1
    }

    # Calculate start offset based on partition
    if ($Partition) {
        $Part = $partitions | Where-Object { $_.PartitionNumber -eq $Partition }
        if ($Part) {
            [long]$startOffset = $Part.Offset
            [long]$endOffset = $Part.Offset + $Part.Size
            [long]$totalSize = $endOffset - $startOffset
        } else {
            Write-Host "`nAvailable partitions:" -ForegroundColor Green
            $partitions | Format-Table -Property PartitionNumber, Type, Size, Offset, DriveLetter
            Write-Host "Invalid partition $Partition.`n" -ForegroundColor Red
            exit 1
        }
    }

    if ($totalSize -lt $imageSize) {
        Write-Host "Error. Selected partition size ($totalSize bytes = $([math]::Round($totalSize/1GB, 2)) GB) is less than the source image file size ($imageSize bytes = $([math]::Round($imageSize/1GB, 2)) GB).`n" -ForegroundColor Red
        exit 1
    }
} else {
    if ($totalSize -lt $imageSize) {
        Write-Host "Error. Selected disk size ($totalSize bytes = $([math]::Round($totalSize/1GB, 2)) GB) is less than the sorce image file size ($imageSize bytes = $([math]::Round($imageSize/1GB, 2)) GB).`n" -ForegroundColor Red
        exit 1
    }
}

# Get the device path for the destination disk
$destination_disk = "\\.\PhysicalDrive$DiskNumber"

if ((-not $Force) -and (-not $OnlyVerify)) {
    Write-Host "`nWARNING: This will OVERWRITE disk $DiskNumber ($($disk.FriendlyName))" -ForegroundColor Green
    Write-Host "Image size to read: $([math]::Round($imageSize/1GB, 2)) GB" -ForegroundColor Green
    Write-Host "Disk size to write: $([math]::Round($totalSize/1GB, 2)) GB" -ForegroundColor Green
    if ($startOffset -gt 0) {
        Write-Host "Use partition. Disk offset: $startOffset bytes ($([math]::Round($startOffset/1GB, 2)) GB)" -ForegroundColor Green    
    } else {
        Write-Host "Copy full disk." -ForegroundColor Green    
    }

    $confirmation = $(
        Write-Host "`nAre you sure you want to proceed? (Y/N): " -NoNewLine -ForegroundColor Green
        Read-Host
    )
    if ($confirmation -ne 'Y') {
        Write-Host "`nOperation canceled. Exiting script.`n" -ForegroundColor Yellow
        exit 1
    }
}

$buffer = New-Object byte[]($BufferSize)
[long]$totalBytesWritten = 0
$disabledPoints = @()  # Initialize an array to hold the disabled mount points

# Dismount volumes
if ($partitions) {
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
}

# Constants
$GENERIC_READ = 0x80000000
$GENERIC_WRITE = 0x40000000
$FILE_SHARE_READ = 0x1
$FILE_SHARE_WRITE = 0x2
$OPEN_EXISTING = 3
$INVALID_HANDLE_VALUE = -1
$FSCTL_LOCK_VOLUME = 0x00090018
$FSCTL_UNLOCK_VOLUME = 0x0009001c
$FSCTL_DISMOUNT_VOLUME = 0x00090020

if (-not $OnlyVerify) {
    try {
        $dotCount = 0
        [long]$bytesReturned = 0u
        $success = $false

        #Disable-Automount

        # Clear disk to ensure clean state
        if (-not $partitions) {
            Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm: (-not $Force)
        }

        # Open source file
        $srcStream = [System.IO.File]::OpenRead($source)

        # Open the physical drive
        $handle = [DiskWriterAPI]::CreateFile($destination_disk, 
            $GENERIC_READ -bor $GENERIC_WRITE,
            $FILE_SHARE_READ -bor $FILE_SHARE_WRITE,
            [IntPtr]::Zero,
            $OPEN_EXISTING,
            0,
            [IntPtr]::Zero)

        if ($handle -eq $INVALID_HANDLE_VALUE) {
            throw "Failed to open disk. Error code: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }

        # Skip to partition offset
        if ($startOffset -gt 0) {

            #$totalBytesWritten = $startOffset
            #$srcStream.Seek($startOffset, [System.IO.SeekOrigin]::Begin) | Out-Null

            $seekSuccess = [DiskWriterAPI]::SetFilePointerEx(
                $handle,
                $startOffset,
                [IntPtr]::Zero,
                $FILE_BEGIN)

            Write-Host "Offset: $startOffset bytes ($([math]::Round($startOffset / 1GB, 2)) GB)" -ForegroundColor Cyan
            Write-Host "Copy size: $imageSize bytes ($([math]::Round($imageSize / 1GB, 2)) GB)" -ForegroundColor Cyan
        } else {
            Write-Host "Copying $imageSize bytes ($([math]::Round($imageSize / 1GB, 2)) GB) from the start of the disk." -ForegroundColor Cyan
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

        $DoLock = $false
        if ($DoLock) {
            # Lock and dismount the volume
            Write-Host "Locking and dismounting volume..."
            $success = [DiskWriterAPI]::DeviceIoControl(
                $handle,
                $FSCTL_LOCK_VOLUME,
                [IntPtr]::Zero,
                0,
                [IntPtr]::Zero,
                0,
                [ref]$bytesReturned,
                [IntPtr]::Zero)

            if (-not $success) {
                throw "Failed to lock volume. Error code: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
            }

            $success = [DiskWriterAPI]::DeviceIoControl(
                $handle,
                $FSCTL_DISMOUNT_VOLUME,
                [IntPtr]::Zero,
                0,
                [IntPtr]::Zero,
                0,
                [ref]$bytesReturned,
                [IntPtr]::Zero)

            if (-not $success) {
                throw "Failed to dismount volume. Error code: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
            }
        }

        # Copy the image to disk
        Write-Host "Writing disk image..."
        [Console]::Out.Flush()

        while ($totalBytesWritten -lt $imageSize) {
            $remainingBytes = $imageSize - $totalBytesWritten
            $readSize = [Math]::Min([long]$bufferSize, [long]$remainingBytes)
            
            # Read the data first
            $bytesRead = $srcStream.Read($buffer, 0, $readSize)
            if ($bytesRead -eq 0) { break }

            # Always ensure the write size is aligned to 512 bytes
            [long]$alignedSize = $bytesRead
            if ($alignedSize % 512 -ne 0) {
                $alignedSize += (512 - ($alignedSize % 512))
            }
            
            # If we need to align, create a new padded buffer
            if ($alignedSize -ne $bytesRead) {
                [long]$alignedBuffer = New-Object byte[]($alignedSize)
                [Array]::Copy($buffer, $alignedBuffer, $bytesRead)
                # Zero out the padding bytes
                for ($i = $bytesRead; $i -lt $alignedSize; $i++) {
                    $alignedBuffer[$i] = 0
                }
                $buffer = $alignedBuffer
            }

            [long]$bytesWritten = 0u
            $success = [DiskWriterAPI]::WriteFile(
                $handle,
                $buffer,
                [uint32]$alignedSize,
                [ref]$bytesWritten,
                [IntPtr]::Zero)

            if (-not $success) {
                $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                throw "`nFailed to write $alignedSize bytes to disk at offset $totalBytesWritten. Attempted to write $alignedSize bytes. Error code: $lastError"
            }

            if ($bytesWritten -ne $alignedSize) {
                throw "`nWrite size mismatch. Wrote $bytesWritten of $alignedSize bytes at offset $totalBytesWritten"
            }

            # Only count the actual bytes we read from the source, not the padding
            $totalBytesWritten += $bytesRead
            Write-Host "." -NoNewline
            $dotCount++
            
            if ($dotCount -ge 80) {
                $percentage = ([long]$totalBytesWritten / [long]$imageSize) * 100
                Write-Host "`r $([math]::Round($percentage, 1))% " -NoNewline
                $dotCount = 0
                [Console]::Out.Flush()
            }
        }
        if ($dotCount -ne 0) {
            Write-Host ""
        }
    }
    catch {
        Write-Host "Error: $_"
        #Write-Host "Last Win32 Error: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    } finally {
        # Ensure that the destination stream is closed and the file is released
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
    Write-Host "`nDisk restore completed successfully!" -ForegroundColor Cyan
    Write-Host "Bytes written: $totalBytesWritten" -ForegroundColor Cyan
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
    $fs2 = [System.IO.File]::OpenRead($Source)
} catch {
    Write-Host "`nError: The image source file is busy or the stream is invalid." -ForegroundColor Red
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
    while ([long]$totalBytesRead -lt [long]$imageSize -and $equal) {
        if ($retry -gt $RetryVerify) {
            $equal = $false
            Write-Host "`nDifferent data content at offset $totalBytesRead ($([math]::Round($totalBytesRead / 1GB, 2)) GB)." -ForegroundColor Red
            break
        }
        if ($retry -eq 0) {
            [long]$remainingBytes = [long]$imageSize - [long]$totalBytesRead
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
            $percentage = ([long]$totalBytesRead / [long]$imageSize) * 100
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
