# LogModule PowerShell Module

A comprehensive logging module for PowerShell that supports multiple output destinations, including console, local files, and Azure Application Insights.

## Features

- **Multi-Destination Logging**: Write to console, local files, and Azure Application Insights simultaneously
- **Configurable Output**: Enable/disable individual logging destinations
- **Automatic Log Rotation**: Local log files are automatically rotated when they exceed configured size limits
- **Rich Metadata**: Each log entry includes timestamps, severity levels, and script names
- **Azure Application Insights Integration**: Cloud-based telemetry with automatic SDK management
- **Color-Coded Console Output**: Improved readability with configurable colors
- **Cross-Platform Support**: Works with PowerShell 5.1+ and PowerShell Core 7+

## Installation

### Manual Installation
1. Copy the `LogModule` folder to one of your PowerShell module directories:
   - Windows: `C:\Users\<Username>\Documents\WindowsPowerShell\Modules\` or `C:\Program Files\WindowsPowerShell\Modules\`
   - macOS/Linux: `~/.local/share/powershell/Modules/` or `/usr/local/share/powershell/Modules/`

2. Import the module:
   ```powershell
   Import-Module LogModule
   ```

### Direct Usage
1. Navigate to the directory containing the `LogModule` folder
2. Import the module directly:
   ```powershell
   Import-Module .\LogModule
   ```

## Configuration

LogModule provides global variables to enable/disable individual logging destinations:

```powershell
# Enable/disable console logging (enabled by default)
$Global:EnableWriteLogsConsole = $true

# Enable/disable local file logging (enabled by default)
$Global:EnableWriteLogsLocal = $true

# Enable/disable Azure Application Insights logging (enabled by default)
$Global:EnableWriteLogsAI = $true
```

## Usage Examples

### Basic Logging

```powershell
# Simple information message
Write-Logs "Application started successfully"

# Warning message with yellow foreground
Write-Logs "Low disk space detected" -ForegroundColor Yellow -SeverityLevel Warning

# Error message with red foreground
Write-Logs "Connection failed: $($_.Exception.Message)" -ForegroundColor Red -SeverityLevel Error
```

### Log Levels

```powershell
# Verbose (only visible with -Verbose flag)
Write-Logs "Detailed debugging information" -SeverityLevel Verbose

# Debug
Write-Logs "Debug information" -SeverityLevel Debug

# Information (default)
Write-Logs "General information" -SeverityLevel Information

# Warning
Write-Logs "Potential issue detected" -SeverityLevel Warning

# Error
Write-Logs "Operation failed" -SeverityLevel Error

# Critical
Write-Logs "System failure" -SeverityLevel Critical
```

### Local File Logging

```powershell
# Set custom log directory
Set-LogDirectory -Path "C:\Logs\MyApplication"

# View current log configuration
Get-LogConfig

# Write message that will be logged to local file
Write-Logs "This will be written to log file" -SeverityLevel Information
```

### Azure Application Insights

```powershell
# Initialize Application Insights with connection string
Initialize-AppInsights -ConnectionString "InstrumentationKey=your-key;IngestionEndpoint=https://your-region.applicationinsights.azure.com/"

# Check Application Insights status
Get-AppInsightsStatus

# Write message to Application Insights
Write-Logs "Telemetry data sent to AI" -SeverityLevel Information

# Write trace directly to Application Insights with custom properties
Write-AppInsightsTrace -Message "Custom trace" -SeverityLevel Information -Properties @{"CustomField" = "Value"}
```

## Functions Reference

### Write-Logs
Main logging function that writes to all enabled destinations.

```powershell
Write-Logs -Message <string[]> [-ForegroundColor <ConsoleColor>] [-BackgroundColor <ConsoleColor>] [-SeverityLevel <string>] [-NoNewline]
```

**Parameters:**
- `-Message`: The message content to write (mandatory)
- `-ForegroundColor`: Console output foreground color
- `-BackgroundColor`: Console output background color
- `-SeverityLevel`: Log severity level (Verbose, Debug, Information, Warning, Error, Critical)
- `-NoNewline`: Do not add a newline character

### Initialize-AppInsights
Initializes the Application Insights tracking module.

```powershell
Initialize-AppInsights [-ConnectionString <string>]
```

**Parameters:**
- `-ConnectionString`: Azure Application Insights connection string (optional, can be set via APPINSIGHTS_CONNECTION_STRING environment variable)

### Write-AppInsightsTrace
Writes trace logs directly to Application Insights.

```powershell
Write-AppInsightsTrace -Message <string> [-SeverityLevel <string>] [-Properties <hashtable>]
```

**Parameters:**
- `-Message`: The message content to write (mandatory)
- `-SeverityLevel`: Log severity level
- `-Properties`: Additional custom properties to include in the trace

### Write-LocalLog
Writes logs directly to local files.

```powershell
Write-LocalLog -Message <string[]> [-SeverityLevel <string>] [-NoNewline]
```

**Parameters:**
- `-Message`: The message content to write (mandatory)
- `-SeverityLevel`: Log severity level
- `-NoNewline`: Do not add a newline character

### Get-AppInsightsStatus
Returns the current status of Application Insights integration.

```powershell
Get-AppInsightsStatus
```

### Set-LogDirectory
Updates the default log directory for local logging.

```powershell
Set-LogDirectory -Path <string> [-CreateIfNotExists <bool>]
```

**Parameters:**
- `-Path`: The new log directory path (mandatory)
- `-CreateIfNotExists`: Create the directory if it doesn't exist (default: $true)

### Get-LogConfig
Returns the current local logging configuration.

```powershell
Get-LogConfig
```

### Log Destination Control Functions

```powershell
# Enable console logging
Enable-LogsConsole

# Disable console logging
Disable-LogsConsole

# Enable local file logging
Enable-LogsLocal

# Disable local file logging
Disable-LogsLocal

# Enable Application Insights logging
Enable-LogsAI

# Disable Application Insights logging
Disable-LogsAI
```

## Log File Management

- **Default Location**: `.\logs` directory relative to the running script
- **Naming Convention**: `<ScriptName>_<YYYYMMDD>.log`
- **Rotation**: Log files are rotated when they exceed 10 MB (configurable)
- **Retention**: Rotated logs are named with timestamps (`<LogName>.yyyyMMdd_HHmmss`)

## Troubleshooting

### Application Insights Issues

- **Initialization Failure**: Verify connection string is correct and accessible
- **SDK Download Issues**: Ensure internet connectivity for automatic SDK download
- **No Data in AI**: Check if $Global:EnableWriteLogsAI is set to $true

### Local Logging Issues

- **Permission Errors**: Ensure the current user has write access to the log directory
- **Log File Not Created**: Check if $Global:EnableWriteLogsLocal is set to $true
- **Large Log Files**: Adjust MaxLogFileSizeMB in the module configuration

### Console Output Issues

- **No Color**: Ensure console supports ANSI colors (PowerShell Core on Windows 10+)
- **No Output**: Check if $Global:EnableWriteLogsConsole is set to $true

## Module Configuration

The following internal configuration settings can be modified if needed:

```powershell
# Log configuration
$script:LogConfig = @{
    DefaultLogDirectory = ".\logs"
    LogFileExtension = ".log"
    DefaultEncoding = "UTF8"
    MaxLogFileSizeMB = 10
}

# Application Insights configuration
$script:AppInsightsConfig = @{
    DefaultConnectionString = $null
    SdkVersion = "2.23.0"
    LogFlushDelayMs = 700
}
```

## Requirements

- PowerShell 5.1 or PowerShell Core 7+
- Internet access (for Application Insights SDK download)
- Azure subscription (for Application Insights logging)

## Notes

- The module automatically includes metadata like script names and timestamps in log entries
- Log file paths are automatically determined based on the calling script name
- Application Insights SDK is cached locally for subsequent use
- The module cleans up resources when removed

## Version History

- **1.0.0**: Initial release
  - Multi-destination logging support
  - Azure Application Insights integration
  - Log rotation and management
  - Configurable logging destinations
  - Rich metadata support
