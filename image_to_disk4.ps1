# Input parameters from command line:
# 1. Source image path
# 2. Destination disk number
param(
    [Parameter(Mandatory=$true)]
    [string]$source,
    
    [Parameter(Mandatory=$true)]
    [int]$disk
)

# Add required Windows API definitions
Add-Type -TypeDefinition @"
    using System;
    using System.Runtime.InteropServices;

    public class DiskWriterAPI {
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
"@

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

# Safety checks
if (-not (Test-Path $source)) {
    Write-Host "Error: Image file not found: $source"
    exit 1
}

$destination = "\\.\PhysicalDrive$disk"
$diskObject = Get-Disk -Number $disk

if (-not $diskObject) {
    Write-Host "Error: Disk $disk not found"
    exit 1
}

# Get sizes
$imageSize = (Get-Item $source).Length
$diskSize = $diskObject.Size

if ($imageSize -gt $diskSize) {
    Write-Host "Error: Image size ($imageSize bytes) is larger than disk size ($diskSize bytes)"
    exit 1
}

# Prompt for confirmation
Write-Host "WARNING: This will OVERWRITE disk $disk ($($diskObject.FriendlyName))"
Write-Host "Disk size: $([math]::Round($diskSize/1GB, 2)) GB"
Write-Host "Image size: $([math]::Round($imageSize/1GB, 2)) GB"
$confirmation = Read-Host "Are you sure you want to proceed? (yes/no)"
if ($confirmation -ne "yes") {
    Write-Host "Operation cancelled"
    exit 0
}

# Initialize variables
$bufferSize = 10MB
$buffer = New-Object byte[]($bufferSize)
$totalBytesWritten = 0
$dotCount = 0
$bytesReturned = 0u
$volume = $null
$success = $false

# Function to check and remove partition access paths
# Function to check and remove partition access paths
function Remove-PartitionAccessPaths {
    param (
        [Parameter(Mandatory=$true)]
        [int]$disk
    )

    # First check if the disk exists and get its partition count
    $diskInfo = Get-Disk -Number $disk -ErrorAction SilentlyContinue
    if (-not $diskInfo) {
        Write-Host "Disk $disk not found."
        return $false
    }

    # Check partition count using disk info
    if ($diskInfo.NumberOfPartitions -eq 0) {
        Write-Host "No partitions found on disk $disk."
        return $true
    }

    # Now we know we have partitions, get them
    try {
        $partitions = @(Get-Partition -DiskNumber $disk -ErrorAction Stop)
    } catch {
        Write-Error "Error accessing partitions: $_"
        return $false
    }

    # Show partition information and confirm
    Write-Host "`nFound $($partitions.Count) partition(s) on disk $disk :"
    foreach ($partition in $partitions) {
        Write-Host "Partition $($partition.PartitionNumber):"
        Write-Host "  Size: $([math]::Round($partition.Size/1GB, 2)) GB"
        Write-Host "  Type: $($partition.Type)"
        if ($partition.DriveLetter) {
            Write-Host "  Drive Letter: $($partition.DriveLetter)"
        }
        Write-Host ""
    }

    $confirmation = Read-Host "Do you want to remove access paths from these partitions? (Y/N)"
    if ($confirmation -ne "Y") {
        Write-Host "Operation cancelled by user."
        return $false
    }

    # Process each partition
    foreach ($partition in $partitions) {
        try {
            if ($partition.AccessPaths) {
                foreach ($accessPath in $partition.AccessPaths) {
                    Write-Host "Removing access path '$accessPath' from partition $($partition.PartitionNumber)..."
                    
                    # Handle drive letters differently from other access paths
                    if ($accessPath -match "^[A-Z]:\\$") {
                        Remove-PartitionAccessPath -DiskNumber $disk `
                            -PartitionNumber $partition.PartitionNumber `
                            -AccessPath $accessPath `
                            -ErrorAction Stop `
                            -Confirm:$false
                    }
                    # For other types of access paths (if they exist)
                    else {
                        Remove-PartitionAccessPath -DiskNumber $disk `
                            -PartitionNumber $partition.PartitionNumber `
                            -AccessPath $accessPath `
                            -ErrorAction Stop `
                            -Confirm:$false
                    }
                    
                    Write-Host "Successfully removed access path '$accessPath'."
                }
            } else {
                Write-Host "Partition $($partition.PartitionNumber) has no access paths."
            }
        } catch {
            Write-Error "Failed to remove access paths from partition $($partition.PartitionNumber): $_"
            return $false
        }
    }
    return $true
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

try {

    $result = Remove-PartitionAccessPaths -disk $disk
    if ($result) {
        Write-Host "Access path removal process completed successfully."
    } else {
        Write-Host "Access path removal process failed or was cancelled."
    }

    Disable-Automount

    # Clear disk to ensure clean state
    Clear-Disk -Number $disk -RemoveData -RemoveOEM -Confirm:$false

    # Open source file
    $srcStream = [System.IO.File]::OpenRead($source)

    # Open the physical drive
    $handle = [DiskWriterAPI]::CreateFile($destination, 
        $GENERIC_READ -bor $GENERIC_WRITE,
        $FILE_SHARE_READ -bor $FILE_SHARE_WRITE,
        [IntPtr]::Zero,
        $OPEN_EXISTING,
        0,
        [IntPtr]::Zero)

    if ($handle -eq $INVALID_HANDLE_VALUE) {
        throw "Failed to open disk. Error code: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }

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
        $alignedSize = $bytesRead
        if ($alignedSize % 512 -ne 0) {
            $alignedSize += (512 - ($alignedSize % 512))
        }
        
        # If we need to align, create a new padded buffer
        if ($alignedSize -ne $bytesRead) {
            $alignedBuffer = New-Object byte[]($alignedSize)
            [Array]::Copy($buffer, $alignedBuffer, $bytesRead)
            # Zero out the padding bytes
            for ($i = $bytesRead; $i -lt $alignedSize; $i++) {
                $alignedBuffer[$i] = 0
            }
            $buffer = $alignedBuffer
        }

        $bytesWritten = 0u
        $success = [DiskWriterAPI]::WriteFile(
            $handle,
            $buffer,
            [uint32]$alignedSize,
            [ref]$bytesWritten,
            [IntPtr]::Zero)

        if (-not $success) {
            $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "Failed to write to disk at offset $totalBytesWritten. Attempted to write $alignedSize bytes. Error code: $lastError"
        }

        if ($bytesWritten -ne $alignedSize) {
            throw "Write size mismatch. Wrote $bytesWritten of $alignedSize bytes at offset $totalBytesWritten"
        }

        # Only count the actual bytes we read from the source, not the padding
        $totalBytesWritten += $bytesRead
        Write-Host "Ciao." -NoNewline
        $dotCount++
        
        if ($dotCount -ge 80) {
            Write-Host ""
            $dotCount = 0
            [Console]::Out.Flush()
        }
    }
    if ($dotCount -ne 0) {
        Write-Host ""
    }

    Write-Host "Disk write completed successfully!"
    Write-Host "Bytes written: $totalBytesWritten"
    
    #-----------------------------------------------------------------------

    # Verification Step
    Write-Host "Verifying disk image..."
    [Console]::Out.Flush()
    $equal = $true
    $fs1 = $null
    try {
        # Reset disk position to beginning
        $FILE_BEGIN = 0
        $result = [DiskWriterAPI]::SetFilePointer($handle, 0, [IntPtr]::Zero, $FILE_BEGIN)
        if ($result -eq [uint32]::MaxValue) {
            throw "Failed to seek disk to beginning. Error code: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }

        # Only open the source file - use existing handle for disk
        $fs1 = [System.IO.File]::OpenRead($source)
        $verifyBufferSize = 10MB
        # Ensure buffer size is multiple of 512 for disk reads
        $verifyBufferSize = $verifyBufferSize - ($verifyBufferSize % 512)
        $sourceBuffer = New-Object byte[]($verifyBufferSize)
        $diskBuffer = New-Object byte[]($verifyBufferSize)
        $dotCount = 0
        $totalBytesRead = 0
        
        # Use imageSize as reference and ensure we don't exceed diskSize
        $bytesToVerify = [Math]::Min($imageSize, $diskSize)
        
        while ($totalBytesRead -lt $bytesToVerify -and $equal) {
            $remainingBytes = $bytesToVerify - $totalBytesRead
            $readSize = [Math]::Min([long]$verifyBufferSize, [long]$remainingBytes)

            # Ensure readSize is aligned to sector size for disk reads
            if ($readSize % 512 -ne 0) {
                $readSize = $readSize - ($readSize % 512)

                # Increase size of last chunk to the sector size
                if ($readSize -eq 0 -and $remainingBytes -gt 0) {
                    $readSize = 512
                }

                if ($readSize -eq 0) { break }
            }
            
            $bytesRead1 = $fs1.Read($sourceBuffer, 0, $readSize)
            if ($bytesRead1 -eq 0) { break }

            # Read from disk using Win32 API
            $bytesRead2 = 0u
            $success = [DiskWriterAPI]::ReadFile(
                $handle,
                $diskBuffer,
                [uint32]$readSize,
                [ref]$bytesRead2,
                [IntPtr]::Zero)

            if ($remainingBytes -gt 0 -and $remainingBytes -lt 512) {
                $bytesRead2 = $remainingBytes
            }
                
            if (-not $success) {
                throw "Failed to read from disk at offset $totalBytesRead. Error code: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
            }
            
            if ($bytesRead1 -ne $bytesRead2) {
                $equal = $false
                Write-Host "`nSize mismatch at offset $totalBytesRead. Source: $bytesRead1, Disk: $bytesRead2"
                break
            }
            
            # Fast memory comparison
            for ($i = 0; $i -lt $bytesRead1; $i += 8) {
                if ($i + 8 -le $bytesRead1) {
                    if ([BitConverter]::ToInt64($sourceBuffer, $i) -ne [BitConverter]::ToInt64($diskBuffer, $i)) {
                        $equal = $false
                        Write-Host "`nContent mismatch at offset $($totalBytesRead + $i)"
                        break
                    }
                }
            }
            
            $totalBytesRead += $bytesRead1
            Write-Host "." -NoNewline
            $dotCount++
            
            if ($dotCount -ge 80) {
                Write-Host ""
                $dotCount = 0
                [Console]::Out.Flush()
            }
        }
        
        if ($dotCount -ne 0) {
            Write-Host ""
        }
        
        Write-Host "Total bytes verified: $totalBytesRead"
        if ($equal) {
            Write-Host "Verification successful: Disk image matches source!"
        } else {
            Write-Host "Verification failed: Disk image does not match source!"
        }

    }
    catch {
        Write-Host "`nError during verification: $_"
    }
    finally {
        if ($fs1) { $fs1.Close() }
    }

    # Unlock the volume
    Write-Host "Unlocking volume..."
    $success = [DiskWriterAPI]::DeviceIoControl(
        $handle,
        $FSCTL_UNLOCK_VOLUME,
        [IntPtr]::Zero,
        0,
        [IntPtr]::Zero,
        0,
        [ref]$bytesReturned,
        [IntPtr]::Zero)

    if (-not $success) {
        throw "Failed to unlock volume. Error code: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    
    Enable-Automount
    
}
catch {
    Write-Host "Error: $_"
    Write-Host "Last Win32 Error: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
}
finally {
    # Clean up
    if ($srcStream) { 
        try { $srcStream.Dispose() } catch { }
    }
    if ($handle -and $handle -ne $INVALID_HANDLE_VALUE) {
        try { [DiskWriterAPI]::CloseHandle($handle) } catch { }
    }
}
