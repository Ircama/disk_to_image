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

    public class Win32 {
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

try {
    # Open source file
    $srcStream = [System.IO.File]::OpenRead($source)

    # Open the physical drive
    $handle = [Win32]::CreateFile($destination, 
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
    $success = [Win32]::DeviceIoControl(
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

    $success = [Win32]::DeviceIoControl(
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
        $success = [Win32]::WriteFile(
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

    Write-Host "`nDisk restore completed successfully!"
    Write-Host "Bytes written: $totalBytesWritten"
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
        try { [Win32]::CloseHandle($handle) } catch { }
    }
}
