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
            long dwDesiredAccess,
            long dwShareMode,
            IntPtr lpSecurityAttributes,
            long dwCreationDisposition,
            long dwFlagsAndAttributes,
            IntPtr hTemplateFile);
    }
"@

# Constants for CreateFile
$GENERIC_READ = [long]0x80000000
$GENERIC_WRITE = [long]0x40000000
$FILE_SHARE_READ = [long]0x1
$FILE_SHARE_WRITE = [long]0x2
$OPEN_EXISTING = [long]3
$INVALID_HANDLE_VALUE = -1

# Safety checks
if (-not (Test-Path $source)) {
    Write-Host "Error: Image file not found: $source"
    exit 1
}

$destination = "\\.\PhysicalDrive$disk"
$diskObject = Get-Disk -Number $disk

# More safety checks
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

try {
    # Open the source file
    $srcStream = [System.IO.File]::OpenRead($source)

    # Open the physical drive using CreateFile
    $access = [long]($GENERIC_READ -bor $GENERIC_WRITE)
    $share = [long]($FILE_SHARE_READ -bor $FILE_SHARE_WRITE)
    
    $dwFlagsAndAttributes = [long]0x20000000 -bor 0x80 # FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH
    $handle = [Win32]::CreateFile($destination, 
        $access,
        $share,
        [IntPtr]::Zero,
        $OPEN_EXISTING,
        $dwFlagsAndAttributes,
        [IntPtr]::Zero)

    if ($handle -eq $INVALID_HANDLE_VALUE) {
        throw "Failed to open disk. Error code: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }

    # Create a FileStream from the handle
        $destStream = New-Object System.IO.FileStream($handle, 
        [System.IO.FileAccess]::Write, 
        $true,   # leaveOpen 
        $bufferSize, 
        $false)  # false = do not use Async

    # Copy the image to disk
    Write-Host "Writing disk image..."
    [Console]::Out.Flush()

    while ($totalBytesWritten -lt $imageSize) {
        $remainingBytes = $imageSize - $totalBytesWritten
        $readSize = [Math]::Min([long]$bufferSize, [long]$remainingBytes)
        
        $bytesRead = $srcStream.Read($buffer, 0, $readSize)
        
        if ($bytesRead -eq 0) { break }
        
        $destStream.Write($buffer, 0, $bytesRead)
        $totalBytesWritten += $bytesRead
        Write-Host "." -NoNewline
        $dotCount++
        
        if ($dotCount -ge 80) {
            Write-Host ""
            $dotCount = 0
            [Console]::Out.Flush()
        }
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
    if ($srcStream) { $srcStream.Close() }
    if ($destStream) { $destStream.Close() }
}

#--------------------------------------------------------

# Verification Step
Write-Host "Verifying disk image..."
[Console]::Out.Flush()

$equal = $true
$fs1 = [System.IO.File]::OpenRead($source)
$fs2 = [System.IO.File]::OpenRead($destination)

# Increase buffer size for faster reading
$bufferSize = 1MB
$one = New-Object byte[]($bufferSize)
$two = New-Object byte[]($bufferSize)
$dotCount = 0
$totalBytesRead = 0

while ($totalBytesRead -lt $diskSize -and $equal) {
    $remainingBytes = $diskSize - $totalBytesRead
    $readSize = [Math]::Min([long]$bufferSize, [long]$remainingBytes)
    
    $bytesRead1 = $fs1.Read($one, 0, $readSize)
    $bytesRead2 = $fs2.Read($two, 0, $readSize)
    $bytesRead2 = [Math]::Min([long]$bytesRead1, [long]$bytesRead2)
    
    if ($bytesRead1 -ne $bytesRead2) {
        Write-Host "Error: $bytesRead1 -ne $bytesRead2 ($readSize2) - $source, $destination"
        $equal = $false
        break
    }
    
    # Fast memory comparison
    for ($i = 0; $i -lt $bytesRead1; $i += 8) {
        if ([BitConverter]::ToInt64($one, $i) -ne [BitConverter]::ToInt64($two, $i)) {
            Write-Host "Error: not matching: $i"
            $equal = $false
            break
        }
    }
    
    # Check remaining bytes (if buffer size not divisible by 8)
    if ($equal -and ($bytesRead1 % 8 -ne 0)) {
        $remainder = $bytesRead1 % 8
        $startPos = $bytesRead1 - $remainder
        for ($i = $startPos; $i -lt $bytesRead1; $i++) {
            if ($one[$i] -ne $two[$i]) {
                $equal = $false
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

$fs1.Close()
$fs2.Close()

Write-Host ""
if ($equal) {
    Write-Host "Verification successful: Disk image matches source!"
} else {
    Write-Host "Verification failed: Disk image does not match source!"
}
