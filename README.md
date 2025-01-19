# disk_to_image

__Disk to Image - Advanced Disk Imaging Utility__

*disk_to_image* is a powerful and flexible Windows PowerShell utility that creates binary images of physical disks, like SD Cards. It is designed to be both user-friendly for interactive use and automation-ready for batch operations.

The script identifies mounted volumes on the disk to be copied, automatically dismounts all volumes to ensure no writes can occur during copying, also avoiding verification errors. At the end of the operation, it automatically remounts all volumes, restoring disk to original mounted state.

Nothing to install. Just copy the program and run it on Windows.

Tested on SD Cards.

## Key Features

- __Full Disk Imaging__: Create complete disk images or select specific partitions
- __Smart SD Card Imaging__: Create optimized images by copying only used space from SD cards
- __Automatic End Detection__: Automatically detects and stops at the last used partition
- __Space Optimization__: Avoids copying unused space beyond the last partition, resulting in smaller image files
- __Flexible Buffer Management__: Adjustable buffer size for optimized performance
- __Data Verification__: Built-in verification process to ensure data integrity
- __No Installation Required__: Standalone script that runs directly from PowerShell
- __Interactive and Batch Modes__: Run with command-line parameters or interactive prompts
- __Partition-Level Control__: Select specific partitions to image
- __Robust Error Handling__: Retry mechanisms and detailed error reporting
- __Administrative Rights Management__: Automatic elevation of privileges if not run as Administrator

## Download and Run

To download and run the utility directly from GitHub using a Windows CMD:

```cmd
# Download the script
powershell Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/Ircama/disk_to_image/main/disk_to_image.ps1' -OutFile 'disk_to_image.ps1'

# Run interactively
powershell .\disk_to_image.ps1

# Or run with parameters
powershell .\disk_to_image.ps1 -DiskNumber 2 -Destination "D:\backups\disk2.bin"
```

## Usage Modes

1.  Interactive Mode

    Simply run the script without parameters: `.\disk_to_image.ps1`.

    The script will:

    - Prompt for administrative rights if needed
    - Ask whether to use partitions
    - Guide you through the imaging process

2.  Command-Line Mode

    For automated or scripted operations:

    ```powershell
    .\disk_to_image.ps1 -DiskNumber 3 -Destination "D:\backups\disk3.bin" -UsePartitions -FirstPartition 0 -LastPartition 4 -Force
    ```

## Advanced Features

The utility is particularly valuable for backing up SD cards by:

- Reading all data from the start of the disk
- Automatically detecting the last used partition
- Creating an image that includes only the meaningful data
- Skipping unused space after the last partition

This approach offers several benefits:

- Smaller backup files
- Faster backup process
- Reduced storage requirements
- Perfect for embedded systems and IoT devices

Example for SD card backup:

```powershell
.\disk_to_image.ps1 -DiskNumber 2 -Destination "D:\sdcard_backup.bin" -UsePartitions -FirstPartition 0 -LastPartition 4
```

When used with partitions (either interactively or via command-line arguments), the script will:

- Analyze the partition structure
- Copy from the beginning of the disk if 0 is used as the first partition
- Include all partitions if the last partition number is used
- Stop after the last partition, avoiding to copy unused space.

This is particularly useful for:

- Backing up Raspberry Pi SD cards
- Cloning embedded system storage
- Creating distributable images
- Efficient storage management.

Other useful features:

- Verification Options:

  - Built-in verification (default)
  - Skip verification with -NoVerify
  - Only verify existing images with -OnlyVerify
  - Custom verification retry count with -RetryVerify

- Performance Tuning:

  - Adjustable buffer size (-BufferSize)
  - Custom sector size specification (-SectorSize)
  - Optimized read operations

- Partition Management:

  - Full disk or selected partitions
  - Flexible partition range selection
  - Zero-based offset support

Safety Features:

  - Confirmation prompts (unless -Force is used)
  - Error handling and retry mechanisms
  - Progress reporting
  - Debug information for verification issues
  - Automatically dismounts disk before copying
  - Safely remounts disk after completion

## Common Use Cases

System Backup of the full disk:

```powershell
.\disk_to_image.ps1 -DiskNumber 1 -Destination "D:\system_backup.bin"
```

Batch System Backup of the used part of the disk:

```powershell
disk_to_image.ps1 -DiskNumber 2 -Destination k:\image.bin -UsePartitions -FirstPartition 0 -LastPartition 4 -Force
```

Quick batch System Backup of the used part of the disk without verification:

```powershell
disk_to_image.ps1 -DiskNumber 2 -Destination "D:\quick_backup.bin" -UsePartitions -FirstPartition 0 -LastPartition 4 -Force -NoVerify
```

Specific Partition Backup:

```powershell
.\disk_to_image.ps1 -DiskNumber 3 -Destination "D:\partition2.bin" -UsePartitions -FirstPartition 2 -LastPartition 2
```

Automated Backup:

```powershell
.\disk_to_image.ps1 -DiskNumber 1 -Destination "D:\auto_backup.bin" -Force -BufferSize 10MB
```

Simple verification, without :

```powershell
disk_to_image.ps1 -DiskNumber 2 -Destination k:\image.bin -UsePartitions -FirstPartition 0 -LastPartition 4 -Force -OnlyVerify
```

## Usage

```
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
  # Run the command interactively for full disk copy
  .\disk_to_image.ps1

  # Read Disk 2 and output to C:\save\to\imagine.bin with default settings:
  .\disk_to_image.ps1 -DiskNumber 2 -Destination "C:\save\to\imagine.bin"

  # Read Disk 2 with partitions 1 to 3 and a 10MB buffer:
  .\disk_to_image.ps1 2 "C:\save\to\imagine.bin" -UsePartitions `
                   -FirstPartition 1 -LastPartition 3 -BufferSize 10MB

  # Read Disk 2 without verification:
  .\disk_to_image.ps1 2 "C:\save\to\imagine.bin" -NoVerify
```

## Writing a raw disk image to the physical devices

For the inverse process, use [VisualDiskImager](https://github.com/raspopov/VisualDiskImager).
