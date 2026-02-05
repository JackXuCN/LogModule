#Requires -Version 5.1

<#
.SYNOPSIS
    PowerShell logging module with console, local file, and Azure Application Insights support.

.DESCRIPTION
    LogModule combines logging module and Application Insights tracking functionality.
    It provides three logging functions: console output, local log files, and Azure Application Insights.
    Each function can be independently enabled/disabled.

.NOTES
Version: 1.0.0
Author: Jack Xu
Company: Jack Xu
#>

# ===================== Module Initialization =====================
# Set strict mode for better error handling
Set-StrictMode -Version Latest

# ===================== Module Configuration =====================
# Application Insights Configuration
$script:AppInsightsConfig = @{
    DefaultConnectionString = $null # Default connection string (can be overridden)
    SdkVersion = "2.23.0" # Application Insights SDK version
    SdkCacheName = "ApplicationInsightsSdk_v2230" # Cache folder name
    SdkDllRelativePath = "lib\net452\Microsoft.ApplicationInsights.dll" # Relative path inside NuGet package
    LogFlushDelayMs = 700 # Default flush delay in milliseconds
    TempCachePath = $env:TEMP # Use system temp directory for caching
}

# Log Configuration
$script:LogConfig = @{
    DefaultLogDirectory = ".\logs" # Default log directory
    LogFileExtension = ".log" # Log file extension
    DefaultEncoding = "UTF8" # UTF8 encoding for log files
    MaxLogFileSizeMB = 10 # Maximum log file size in MB before rotation
}

# ===================== Global State Variables =====================
# SDK State
$script:AppInsightsState = @{
    IsInitialized = $false # Initialization state
    SdkLoaded = $false # SDK loaded state
    ConnectionString = $null # Connection string for Application Insights
    SdkCachePath = $null # Path to cache folder
    SdkDllPath = $null # Path to SDK DLL
    TelemetryClient = $null  # Cached TelemetryClient instance
}

# Log Switches ($true=enabled, $false=disabled)
$Global:EnableWriteLogsConsole = $true  # Console output switch (enabled by default)
$Global:EnableWriteLogsLocal = $true    # Local log switch (enabled by default)
$Global:EnableWriteLogsAI = $true      # Application Insights switch (enabled by default)

# Preserve original Write-Host function
$script:OriginalWriteHost = Get-Command -Name Write-Host -CommandType Cmd

# ===================== Helper Functions =====================
function Get-CallingScriptName {
    <#
    .SYNOPSIS
    Gets the name of the actual calling script (not this module).
    
    .RETURNS
    [string] Name of the calling script without extension, or "UnknownScript" if not found.
    #>
    [CmdletBinding()]
    param()
    
    try {
        # Get call stack - limit depth to improve performance
        $callStack = Get-PSCallStack -ErrorAction Stop
        
        # Find the first frame that's not from this module
        foreach ($frame in $callStack) {
            if ($frame.ScriptName -and $frame.ScriptName -notlike "*LogModule.psm1") {
                return [System.IO.Path]::GetFileNameWithoutExtension($frame.ScriptName)
            }
        }
        
        return "UnknownScript"
    }
    catch {
        Write-Debug "[Get-CallingScriptName] Error getting script name from call stack: $($_.Exception.Message)"
        return "UnknownScript"
    }
}

function Test-LogFileSize {
    <#
    .SYNOPSIS
    Tests if a log file exceeds the maximum size and rotates it if needed.
    
    .PARAMETER LogPath
    Path to the log file to check.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$LogPath
    )
    
    try {
        if (Test-Path -Path $LogPath -PathType Leaf) {
            $logFile = Get-Item -Path $LogPath -ErrorAction Stop
            $maxSizeBytes = $script:LogConfig.MaxLogFileSizeMB * 1MB
            
            if ($logFile.Length -gt $maxSizeBytes) {
                # Rotate log file
                $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
                $rotatedLogPath = "$LogPath.$timestamp"
                Move-Item -Path $LogPath -Destination $rotatedLogPath -Force -ErrorAction Stop
                Write-Verbose "Rotated log file: $LogPath -> $rotatedLogPath"
            }
        }
    }
    catch {
        Write-Verbose "[Test-LogFileSize] Log file rotation error: $($_.Exception.Message)"
        Write-Debug "[Test-LogFileSize] Log file rotation error: $($_.Exception.Message)"
        # Continue logging even if rotation fails
    }
}

# ===================== Application Insights Core Functions =====================

function Initialize-AppInsights {
    <#
    .SYNOPSIS
    Initializes the Application Insights tracking module.
    
    .PARAMETER ConnectionString
    Azure Application Insights connection string. If not provided, will attempt to get from APPINSIGHTS_CONNECTION_STRING environment variable.
    
    .EXAMPLE
    Initialize-AppInsights -ConnectionString "InstrumentationKey=your-key;IngestionEndpoint=..."
    
    .EXAMPLE
    # Using environment variable
    $env:APPINSIGHTS_CONNECTION_STRING = "InstrumentationKey=your-key;IngestionEndpoint=..."
    Initialize-AppInsights
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$ConnectionString
    )

    try {
        # Only initialize if not already initialized
        if ($script:AppInsightsState.IsInitialized) {
            Write-Verbose "[Initialize-AppInsights] Application Insights already initialized"
            return $true
        }

        # Resolve connection string (priority: parameter > environment variable)
        $appInsightsConnectionString = $ConnectionString
        if ([string]::IsNullOrWhiteSpace($appInsightsConnectionString)) {
            $appInsightsConnectionString = $env:APPINSIGHTS_CONNECTION_STRING
        }

        if ([string]::IsNullOrWhiteSpace($appInsightsConnectionString)) {
            Write-Warning "[Initialize-AppInsights] Application Insights connection string not found. Please provide it via parameter or set APPINSIGHTS_CONNECTION_STRING environment variable."
            return $false
        }

        # Set up SDK cache path
        $script:AppInsightsState.SdkCachePath = Join-Path -Path $script:AppInsightsConfig.TempCachePath -ChildPath $script:AppInsightsConfig.SdkCacheName
        $script:AppInsightsState.SdkDllPath = Join-Path -Path $script:AppInsightsState.SdkCachePath -ChildPath $script:AppInsightsConfig.SdkDllRelativePath

        # Check if SDK is already downloaded
        if (-not (Test-Path -Path $script:AppInsightsState.SdkDllPath -PathType Leaf)) {
            Write-Verbose "[Initialize-AppInsights] Downloading Application Insights SDK..."
            
            # Create cache directory
            if (-not (Test-Path -Path $script:AppInsightsState.SdkCachePath -PathType Container)) {
                $null = New-Item -Path $script:AppInsightsState.SdkCachePath -ItemType Directory -Force -ErrorAction Stop
            }

            # Download NuGet package
            $nugetPackageId = "Microsoft.ApplicationInsights"
            $nugetZipUrl = "https://www.nuget.org/api/v2/package/$nugetPackageId/$($script:AppInsightsConfig.SdkVersion)"
            $zipTempFile = Join-Path -Path $script:AppInsightsState.SdkCachePath -ChildPath "$nugetPackageId.zip"

            Invoke-WebRequest -Uri $nugetZipUrl -OutFile $zipTempFile -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            Expand-Archive -Path $zipTempFile -DestinationPath $script:AppInsightsState.SdkCachePath -Force -ErrorAction Stop
            Remove-Item -Path $zipTempFile -Force -ErrorAction Stop
        }

        # Load SDK assembly
        if (-not ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.Location -eq $script:AppInsightsState.SdkDllPath })) {
            Write-Verbose "[Initialize-AppInsights] Loading Application Insights SDK assembly..."
            [Reflection.Assembly]::LoadFrom($script:AppInsightsState.SdkDllPath) | Out-Null
        }

        # Create and cache telemetry client
        $telemetryConfig = New-Object -TypeName "Microsoft.ApplicationInsights.Extensibility.TelemetryConfiguration" -ErrorAction Stop
        $telemetryConfig.ConnectionString = $appInsightsConnectionString
        
        $telemetryClient = New-Object -TypeName "Microsoft.ApplicationInsights.TelemetryClient" -ArgumentList $telemetryConfig -ErrorAction Stop
        $script:AppInsightsState.TelemetryClient = $telemetryClient

        # Update state
        $script:AppInsightsState.SdkLoaded = $true
        $script:AppInsightsState.ConnectionString = $appInsightsConnectionString
        $script:AppInsightsState.IsInitialized = $true

        Write-Verbose "[Initialize-AppInsights] Application Insights initialized successfully"
        return $true
    }
    catch {
        Write-Warning "[Initialize-AppInsights] Application Insights initialization failed: $($_.Exception.Message)"
        Write-Debug "[Initialize-AppInsights] Detailed error information: $($_.Exception.ToString())"
        
        # Reset resources on failure
        Reset-AppInsightsResources
        
        return $false
    }
}

function Get-AppInsightsStatus {
    <#
    .SYNOPSIS
    Gets current Application Insights status and configuration information.
    
    .EXAMPLE
    Get-AppInsightsStatus
    
    .EXAMPLE
    $status = Get-AppInsightsStatus
    if ($status.IsInitialized) {
        Write-Host "Application Insights is initialized"
    }
    #>
    [CmdletBinding()]
    param()

    # Return a copy of current state
    return [PSCustomObject]@{
        IsInitialized = $script:AppInsightsState.IsInitialized
        SdkLoaded = $script:AppInsightsState.SdkLoaded
        ConnectionStringConfigured = -not [string]::IsNullOrWhiteSpace($script:AppInsightsState.ConnectionString)
        HasCachedTelemetryClient = $null -ne $script:AppInsightsState.TelemetryClient
        SdkVersion = $script:AppInsightsConfig.SdkVersion
        CachePath = $script:AppInsightsState.SdkCachePath
        DllPath = $script:AppInsightsState.SdkDllPath
    }
}

function Write-AppInsightsTrace {
    <#
    .SYNOPSIS
    Writes trace logs to Application Insights.
    
    .PARAMETER Message
    The message content to write.
    
    .PARAMETER SeverityLevel
    Log severity level: Verbose, Debug, Information, Warning, Error, Critical (default: Information).
    
    .PARAMETER Properties
    Hashtable of additional properties to include.
    
    .EXAMPLE
    Write-AppInsightsTrace -Message "Application started" -SeverityLevel Information
    
    .EXAMPLE
    Write-AppInsightsTrace -Message "Error occurred" -SeverityLevel Error -Properties @{ "ErrorCode" = "123" ; "ErrorType" = "CustomError" }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [string]$Message,
        
        [Parameter(Mandatory=$false)]
        [ValidateSet("Verbose", "Debug", "Information", "Warning", "Error", "Critical")] # Validate severity levels, if the level is Debug, map to Verbose in AI
        [string]$SeverityLevel = "Information",
        
        [Parameter(Mandatory=$false)]
        [hashtable]$Properties = @{}
    )

    try {
        # Check if AI is initialized
        if (-not $script:AppInsightsState.IsInitialized) {
            Write-Verbose "[Write-AppInsightsTrace] Application Insights not initialized, attempting automatic initialization"
            $initResult = Initialize-AppInsights
            if (-not $initResult) {
                return $false
            }
        }
        
        # Only send if initialization successful and we have a telemetry client
        if ($script:AppInsightsState.IsInitialized -and $script:AppInsightsState.TelemetryClient) {
            # Map severity level if the level is Debug, map to Verbose in AI
            if ($SeverityLevel -eq "Debug") {
                $SeverityLevel = "Verbose"
            }
            # Convert severity level to Application Insights enum
            $aiSeverity = [Microsoft.ApplicationInsights.DataContracts.SeverityLevel]::$SeverityLevel
            $utcTime = [DateTime]::UtcNow

            # Create trace telemetry
            $traceTelemetry = New-Object -TypeName "Microsoft.ApplicationInsights.DataContracts.TraceTelemetry" -ArgumentList $Message -ErrorAction Stop
            $traceTelemetry.SeverityLevel = $aiSeverity
            $traceTelemetry.Timestamp = $utcTime
            
            # Add all properties to telemetry
            foreach ($key in $Properties.Keys) {
                $traceTelemetry.Properties[$key] = $Properties[$key]
            }

            # Add standard properties if not already present
            if (-not $Properties.ContainsKey("SdkVersion")) {
                $traceTelemetry.Properties["SdkVersion"] = $script:AppInsightsConfig.SdkVersion
            }

            if (-not $Properties.ContainsKey("ScriptName")) {
                $traceTelemetry.Properties["ScriptName"] = Get-CallingScriptName
            }

            if (-not $Properties.ContainsKey("LocalTimestamp")) {
                $traceTelemetry.Properties["LocalTimestamp"] = $utcTime.ToString('MM/dd/yyyy HH:mm:ss.fff')

            }

            # Send telemetry
            Write-Verbose "[Write-AppInsightsTrace] Sending trace log to Application Insights (Level: $SeverityLevel)"
            $script:AppInsightsState.TelemetryClient.TrackTrace($traceTelemetry)
            $script:AppInsightsState.TelemetryClient.Flush()
            
            # Wait briefly to ensure telemetry is sent
            Start-Sleep -Milliseconds $script:AppInsightsConfig.LogFlushDelayMs
            
            Write-Verbose "[Write-AppInsightsTrace] Trace log sent successfully to Application Insights"
        }
        else {
            Write-Warning "[Write-AppInsightsTrace] Application Insights is not properly initialized. Cannot send trace log."
        }
    }
    catch {
        Write-Warning "[Write-AppInsightsTrace] Failed to send trace log to Application Insights: $($_.Exception.ToString())"
    }
}

# ===================== Local Log Functions =====================

function Write-LocalLog {
    <#
    .SYNOPSIS
    Writes directly to local log files without console output.
    
    .PARAMETER Message
    The message content to write.
    
    .PARAMETER SeverityLevel
    Log severity level: Verbose, Debug, Information, Warning, Error, Critical (default: Information).
    
    .PARAMETER NoNewline
    Whether to not add a newline character at the end of the message (default: add).
    
    .EXAMPLE
    Write-LocalLog "Application started" -SeverityLevel Information
    
    .EXAMPLE
    Write-LocalLog "Processing error: $($_.Exception.Message)" -SeverityLevel Error
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [Alias('Msg')]
        [string[]]$Message,
        
        [Parameter(Mandatory=$false)]
        [ValidateSet("Verbose", "Debug", "Information", "Warning", "Error", "Critical")]
        [string]$SeverityLevel = "Information",
        
        [Parameter(Mandatory=$false)]
        [switch]$NoNewline
    )

    # Check local log switch
    if (-not $Global:EnableWriteLogsLocal) {
        Write-Verbose "[Write-LocalLog] Local logging feature is disabled, skipping write"
        return
    }

    try {
        # Process message content
        $logContent = $Message -join ' '
        if (-not $NoNewline) {
            $logContent += [Environment]::NewLine
        }

        # Get current script name from helper function
        $scriptName = Get-CallingScriptName
        $logFileName = "{0}_{1}{2}" -f $scriptName, (Get-Date -Format 'yyyyMMdd'), $script:LogConfig.LogFileExtension
        $logPath = Join-Path -Path $script:LogConfig.DefaultLogDirectory -ChildPath $logFileName

        # Ensure log directory exists
        $logDirectory = Split-Path -Path $logPath -Parent
        if (-not (Test-Path -Path $logDirectory -PathType Container)) {
            Write-Verbose "[Write-LocalLog] Creating log directory: $logDirectory"
            $null = New-Item -Path $logDirectory -ItemType Directory -Force -ErrorAction Stop
        }

        # Check log file size and rotate if needed
        Test-LogFileSize -LogPath $logPath

        # Write to log
        $logEntry = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $SeverityLevel, $logContent
        Add-Content -Path $logPath -Value $logEntry -Encoding $script:LogConfig.DefaultEncoding -ErrorAction Stop
        
        Write-Verbose "[Write-LocalLog] Successfully wrote to local log: $logPath"
    }
    catch {
        Write-Warning "[Write-LocalLog] Failed to write to local log: $($_.Exception.Message)"
        Write-Debug "[Write-LocalLog] Detailed error information: $($_.Exception.ToString())"
    }
}

# ===================== Main Log Function =====================

function Write-Logs { 
    <#
    .SYNOPSIS
    Enhanced logging function that supports console output, local files, and Application Insights.
    
    .PARAMETER Message
    The message content to write.
    
    .PARAMETER ForegroundColor
    Console output foreground color.
    
    .PARAMETER BackgroundColor
    Console output background color.
    
    .PARAMETER SeverityLevel
    Log severity level: Verbose, Debug, Information, Warning, Error, Critical (default: Information).
    
    .PARAMETER NoNewline
    Whether to not add a newline character at the end of the message (default: add).
    
    .EXAMPLE
    Write-Logs "Application started" -ForegroundColor Green -SeverityLevel Information
    
    .EXAMPLE
    Write-Logs "Error occurred" -ForegroundColor Red -BackgroundColor White -SeverityLevel Error
    
    .EXAMPLE
    Write-Logs "Verbose debugging information" -SeverityLevel Verbose
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [Alias('Msg')]
        [string[]]$Message,
        
        [Parameter(Mandatory=$false)]
        [System.ConsoleColor]$ForegroundColor,
        
        [Parameter(Mandatory=$false)]
        [System.ConsoleColor]$BackgroundColor,
        
        [Parameter(Mandatory=$false)]
        [ValidateSet("Verbose", "Debug", "Information", "Warning", "Error", "Critical")]
        [string]$SeverityLevel = "Information",
        
        [Parameter(Mandatory=$false)]
        [switch]$NoNewline
    )

    try {
        # Process message content
        $processedMessage = $Message -join ' '

        # 1. Console output
        if ($Global:EnableWriteLogsConsole) {
            Write-Verbose "[Write-Logs] Writing to console"
            
            # Create parameter hashtable
            $consoleParams = @{
                Object = $processedMessage
                NoNewline = $NoNewline
                Verbose = $false  # Don't let Write-Host produce verbose output
            }
            
            # Add color parameters if provided
            if ($PSBoundParameters.ContainsKey('ForegroundColor')) {
                $consoleParams.ForegroundColor = $ForegroundColor
            }
            
            if ($PSBoundParameters.ContainsKey('BackgroundColor')) {
                $consoleParams.BackgroundColor = $BackgroundColor
            }
            
            # Call original Write-Host
            & $script:OriginalWriteHost @consoleParams
        }

        # 2. Local log
        if ($Global:EnableWriteLogsLocal) {
            Write-Verbose "[Write-Logs] Writing to local log"
            Write-LocalLog -Message $processedMessage -SeverityLevel $SeverityLevel -NoNewline:$NoNewline
        }

        # 3. Application Insights
        if ($Global:EnableWriteLogsAI) {
            Write-Verbose "[Write-Logs] Writing to Application Insights"           
            # Add standard properties
            $aiProperties = @{
                "SdkVersion" = $script:AppInsightsConfig.SdkVersion;
                "ScriptName" = Get-CallingScriptName;
                "LocalTimestamp" = [DateTime]::UtcNow.ToString('MM/dd/yyyy HH:mm:ss.fff')
            }
            Write-AppInsightsTrace -Message $processedMessage -SeverityLevel $SeverityLevel -Properties $aiProperties

        }

        Write-Verbose "[Write-Logs] Log write operation completed successfully"
    }
    catch {
        Write-Warning "[Write-Logs] Error occurred while writing logs: $($_.Exception.Message)"
        Write-Debug "[Write-Logs] Detailed error information: $($_.Exception.ToString())"
    }
}

# ===================== Log Control Functions =====================

function Enable-LogsConsole {
    <#
    .SYNOPSIS
    Enables console output functionality for Write-Logs.
    #>
    [CmdletBinding()]
    param()
    
    $Global:EnableWriteLogsConsole = $true
    Write-Verbose "[Enable-LogsConsole] Console log output enabled"
}

function Disable-LogsConsole {
    <#
    .SYNOPSIS
    Disables console output functionality for Write-Logs.
    #>
    [CmdletBinding()]
    param()
    
    $Global:EnableWriteLogsConsole = $false
    Write-Verbose "[Disable-LogsConsole] Console log output disabled"
}

function Enable-LogsLocal {
    <#
    .SYNOPSIS
    Enables local logging functionality for Write-Logs.
    #>
    [CmdletBinding()]
    param()
    
    $Global:EnableWriteLogsLocal = $true
    Write-Verbose "[Enable-LogsLocal] Local logging enabled"
}

function Disable-LogsLocal {
    <#
    .SYNOPSIS
    Disables local logging functionality for Write-Logs.
    #>
    [CmdletBinding()]
    param()
    
    $Global:EnableWriteLogsLocal = $false
    Write-Verbose "[Disable-LogsLocal] Local logging disabled"
}

function Enable-LogsAI {
    <#
    .SYNOPSIS
    Enables Azure Application Insights logging functionality for Write-Logs.
    #>
    [CmdletBinding()]
    param()
    
    $Global:EnableWriteLogsAI = $true
    Write-Verbose "[Enable-LogsAI] Application Insights logging enabled"
}

function Disable-LogsAI {
    <#
    .SYNOPSIS
    Disables Azure Application Insights logging functionality for Write-Logs.
    #>
    [CmdletBinding()]
    param()
    
    $Global:EnableWriteLogsAI = $false
    Write-Verbose "[Disable-LogsAI] Application Insights logging disabled"
}

function Set-LogDirectory {
    <#
    .SYNOPSIS
    Updates the default log directory path for local logging.
    
    .PARAMETER Path
    The new log directory path. Can be absolute or relative.
    
    .PARAMETER CreateIfNotExists
    If the directory doesn't exist, create it. Default: $true.
    
    .EXAMPLE
    Set-LogDirectory -Path "C:\Logs\MyApp"
    
    .EXAMPLE
    Set-LogDirectory -Path ".\myapp_logs" -CreateIfNotExists $false
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        
        [Parameter(Mandatory=$false)]
        [bool]$CreateIfNotExists = $true
    )
    
    try {
        $resolvedPath = $null
        
        # Handle different scenarios based on CreateIfNotExists
        if ($CreateIfNotExists) {
            # For creating directories, ensure parent exists and create the final directory
            $parentPath = Split-Path -Path $Path -Parent
            $leafName = Split-Path -Path $Path -Leaf
            
            if ([string]::IsNullOrEmpty($leafName)) {
                # Path ends with a separator, use it directly
                $leafName = Split-Path -Path $parentPath -Leaf
                $parentPath = Split-Path -Path $parentPath -Parent
            }
            
            # Create parent directories if they don't exist
            if (-not [string]::IsNullOrEmpty($parentPath) -and -not (Test-Path -Path $parentPath -PathType Container)) {
                New-Item -Path $parentPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
                Write-Verbose "[Set-LogDirectory] Created parent directory: $parentPath"
            }
            
            # Create the final directory
            $resolvedPath = New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Select-Object -ExpandProperty FullName
            Write-Verbose "[Set-LogDirectory] Created/Verified log directory: $resolvedPath"
        }
        else {
            # For existing directories only, check if path exists first
            if (Test-Path -Path $Path -PathType Container) {
                $resolvedPath = Resolve-Path -Path $Path -ErrorAction Stop
            }
            else {
                throw "[Set-LogDirectory] Log directory does not exist: $Path"
            }
        }
        
        # Update the default log directory
        $oldPath = $script:LogConfig.DefaultLogDirectory
        $script:LogConfig.DefaultLogDirectory = $resolvedPath
        Write-Verbose "[Set-LogDirectory] Updated default log directory from '$oldPath' to '$resolvedPath'"
        
        return $true
    }
    catch {
        Write-Warning "[Set-LogDirectory] Failed to update log directory: $($_.Exception.Message)"
        Write-Debug "[Set-LogDirectory] Detailed error information: $($_.Exception.ToString())"
        return $false
    }
}

function Get-LogConfig {
    <#
    .SYNOPSIS
    Gets the current log configuration settings.
    
    .EXAMPLE
    Get-LogConfig
    
    .EXAMPLE
    $config = Get-LogConfig
    Write-Host "Current log directory: $($config.DefaultLogDirectory)"
    #>
    [CmdletBinding()]
    param()
    
    # Return a copy of the current log configuration
    return [PSCustomObject]$script:LogConfig
}

# ===================== Internal Helper Functions =====================

function Reset-AppInsightsResources {
    <#
    .SYNOPSIS
    Disposes of the TelemetryClient if it exists and resets the state variables.    
    #>
    [CmdletBinding()]
    param()
    
    if ($script:AppInsightsState.TelemetryClient -is [System.IDisposable]) {
        try {
            $script:AppInsightsState.TelemetryClient.Dispose()
        }
        catch {
            Write-Debug "[Reset-AppInsightsResources] Error disposing telemetry client: $($_.Exception.Message)"
        }
    }
    
    # Reset state
    $script:AppInsightsState.IsInitialized = $false
    $script:AppInsightsState.SdkLoaded = $false
    $script:AppInsightsState.TelemetryClient = $null
}

# ===================== Module Cleanup =====================
$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
    # Reset Application Insights resources when module is removed
    Reset-AppInsightsResources
}

# ===================== Module Exports =====================
Export-ModuleMember -Function `
    Write-Logs, `
    Write-LocalLog, `
    Initialize-AppInsights, `
    Write-AppInsightsTrace, `
    Get-AppInsightsStatus, `
    Enable-LogsConsole, Disable-LogsConsole, `
    Enable-LogsLocal, Disable-LogsLocal, `
    Enable-LogsAI, Disable-LogsAI, `
    Set-LogDirectory, Get-LogConfig
# ===================== End of LogModule.psm1 =====================