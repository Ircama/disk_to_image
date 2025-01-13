# Input parameters from command line:
# 1. Source image path
# 2. Destination disk number
# .\image_to_disk.ps1 -source "C:\path\to\disk.img" -disk 2
param(
    [Parameter(Mandatory=$true)]
    [string]$source,
    
    [Parameter(Mandatory=$true)]
    [int]$disk
)

GET-CimInstance -query "SELECT * from Win32_DiskDrive"

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

# Before trying to write to disk, set it offline
if ($diskObject.OperationalStatus -eq "Online") {
    Write-Host "Setting disk offline..."
    Set-Disk -Number $disk -IsOffline $true
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
$bufferSize = 1MB
$buffer = New-Object byte[]($bufferSize)
$totalBytesWritten = 0
$dotCount = 0

# Open streams
try {
    $srcStream = [System.IO.File]::OpenRead($source)
    $destStream = [System.IO.File]::OpenWrite($destination)

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
            Write-Host ""  # Add newline
            $dotCount = 0  # Reset counter
            [Console]::Out.Flush()
        }
    }
    if ($dotCount -ne 0) {
        Write-Host ""
    }

    Write-Host "Disk restore completed successfully!"

    # Verification Step
    Write-Host "Verifying disk contents..."
    [Console]::Out.Flush()

    $equal = $true
    $srcStream.Position = 0
    $destStream.Position = 0
    $totalBytesRead = 0
    $dotCount = 0

    while ($totalBytesRead -lt $imageSize -and $equal) {
        $remainingBytes = $imageSize - $totalBytesRead
        $readSize = [Math]::Min([long]$bufferSize, [long]$remainingBytes)
        
        $bytesRead1 = $srcStream.Read($buffer, 0, $readSize)
        $bytesRead2 = $destStream.Read($buffer, 0, $readSize)
        
        if ($bytesRead1 -ne $bytesRead2) {
            $equal = $false
            break
        }
        
        # Fast memory comparison
        for ($i = 0; $i -lt $bytesRead1; $i += 8) {
            if ([BitConverter]::ToInt64($buffer, $i) -ne [BitConverter]::ToInt64($buffer, $i)) {
                $equal = $false
                break
            }
        }
        
        # Check remaining bytes (if buffer size not divisible by 8)
        if ($equal -and ($bytesRead1 % 8 -ne 0)) {
            $remainder = $bytesRead1 % 8
            $startPos = $bytesRead1 - $remainder
            for ($i = $startPos; $i -lt $bytesRead1; $i++) {
                if ($buffer[$i] -ne $buffer[$i]) {
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
    if ($equal) {
        Write-Host "Verification successful: Disk contents match image file!"
    } else {
        Write-Host "Verification failed: Disk contents do not match image file!"
    }
}
catch {
    Write-Host "Error: $_"
}
finally {
    # Clean up
    if ($srcStream) { $srcStream.Close() }
    if ($destStream) { $destStream.Close() }
}
