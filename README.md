# disk_to_image

Windows PowerShell program allowing to copy disk or partitions to a file image.

Nothing to install. Just copy the program and run it on Windows.

Tested on SD Cards.

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
  # Read Disk 2 and output to C:\save\to\imagine.bin with default settings:
  .\disk_to_image.ps1 -DiskNumber 2 -Destination "C:\save\to\imagine.bin"

  # Read Disk 2 with partitions 1 to 3 and a 10MB buffer:
  .\disk_to_image.ps1 2 "C:\save\to\imagine.bin" -UsePartitions `
                   -FirstPartition 1 -LastPartition 3 -BufferSize 10MB

  # Read Disk 2 without verification:
  .\disk_to_image.ps1 2 "C:\save\to\imagine.bin" -NoVerify
```
