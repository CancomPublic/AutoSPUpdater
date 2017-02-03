﻿#region Install Updates
function InstallUpdatesFromPatchPath ($patchPath, $spVer)
{
    Write-Host -ForegroundColor White " - Looking for SharePoint updates to install in $patchPath..."
    # Result codes below are from http://technet.microsoft.com/en-us/library/cc179058(v=office.14).aspx
    $oPatchInstallResultCodes = @{"17301" = "Error: General Detection error";
                                  "17302" = "Error: Applying patch";
                                  "17303" = "Error: Extracting file";
                                  "17021" = "Error: Creating temp folder";
                                  "17022" = "Success: Reboot flag set";
                                  "17023" = "Error: User cancelled installation";
                                  "17024" = "Error: Creating folder failed";
                                  "17025" = "Patch already installed";
                                  "17026" = "Patch already installed to admin installation";
                                  "17027" = "Installation source requires full file update";
                                  "17028" = "No product installed for contained patch";
                                  "17029" = "Patch failed to install";
                                  "17030" = "Detection: Invalid CIF format";
                                  "17031" = "Detection: Invalid baseline";
                                  "17034" = "Error: Required patch does not apply to the machine";
                                  "17038" = "You do not have sufficient privileges to complete this installation for all users of the machine. Log on as administrator and then retry this installation";
                                  "17044" = "Installer was unable to run detection for this package"}

    # Get all CUs and PUs
    $updatesToInstall = Get-ChildItem -Path "$patchPath" -Include office2010*.exe,ubersrv*.exe,ubersts*.exe,*pjsrv*.exe,sharepointsp2013*.exe,coreserver201*.exe,sts201*.exe,wssloc201*.exe,svrproofloc201*.exe -Recurse -ErrorAction SilentlyContinue | Sort-Object -Descending
    # Look for Server Update installers
    if ($updatesToInstall)
    {
        # Display warning about missing March 2013 PU only if we are actually installing SP2013 and SP1 isn't already installed and the SP1 installer isn't found
        if ($spYear -eq "2013" -and !($sp2013SP1 -or (CheckFor2013SP1)) -and !$marchPublicUpdate)
        {
            Write-Host -ForegroundColor Yellow "  - Note: the March 2013 PU package wasn't found in ..\$spYear\Updates; it may need to be installed first if it wasn't slipstreamed."
        }
        # Now attempt to install any other CUs found in the \Updates folder
        Write-Host -ForegroundColor White "  - Installing SharePoint Updates on " -NoNewline
        Write-Host -ForegroundColor Black -BackgroundColor Yellow "$env:COMPUTERNAME"
        ForEach ($updateToInstall in $updatesToInstall)
        {
            # Get the file name only, in case $updateToInstall includes part of a path (e.g. is in a subfolder)
            $splitUpdate = Split-Path -Path $updateToInstall -Leaf
            Write-Host -ForegroundColor Cyan "   - Installing $splitUpdate..." -NoNewline
            $startTime = Get-Date
            Start-Process -FilePath "$updateToInstall" -ArgumentList "/passive /norestart" -LoadUserProfile
            Show-Progress -Process $($splitUpdate -replace ".exe", "") -Color Cyan -Interval 5
            $delta,$null = (New-TimeSpan -Start $startTime -End (Get-Date)).ToString() -split "\."
            $oPatchInstallLog = Get-ChildItem -Path (Get-Item $env:TEMP).FullName | ? {$_.Name -like "opatchinstall*.log"} | Sort-Object -Descending -Property "LastWriteTime" | Select-Object -first 1
            # Get install result from log
            $oPatchInstallResultMessage = $oPatchInstallLog | Select-String -SimpleMatch -Pattern "OPatchInstall: Property 'SYS.PROC.RESULT' value" | Select-Object -Last 1
            If (!($oPatchInstallResultMessage -like "*value '0'*")) # Anything other than 0 means unsuccessful but that's not necessarily a bad thing
            {
                $null,$oPatchInstallResultCode = $oPatchInstallResultMessage.Line -split "OPatchInstall: Property 'SYS.PROC.RESULT' value '"
                $oPatchInstallResultCode = $oPatchInstallResultCode.TrimEnd("'")
                # OPatchInstall: Property 'SYS.PROC.RESULT' value '17028' means the patch was not needed or installed product was newer
                if ($oPatchInstallResultCode -eq "17028") {Write-Host -ForegroundColor White "   - Patch not required; installed product is same or newer."}
                elseif ($oPatchInstallResultCode -eq "17031")
                {
                    Write-Warning "Error 17031: Detection: Invalid baseline"
                    Write-Warning "A baseline patch (e.g. March 2013 PU for SP2013, SP1 for SP2010) is missing!"
                    Write-Host -ForegroundColor Yellow "   - Either slipstream the missing patch first, or include the patch package in the ..\$spYear\Updates folder."
                    Pause "continue"
                }
                else 
                {
                    Write-Host -ForegroundColor Yellow "   - $($oPatchInstallResultCodes.$oPatchInstallResultCode)"
                    Write-Host -ForegroundColor Yellow "   - Please log on to this server ($env:COMPUTERNAME) now, and install the update manually."
                    Pause "continue once the update has been successfully installed manually" "y"
                }
            }
            Write-Host -ForegroundColor White "   - $splitUpdate install completed in $delta."
        }
        Write-Host -ForegroundColor White "  - Update installation complete."
    }
    Write-Host -ForegroundColor White " - Finished installing SharePoint updates on " -NoNewline
    Write-Host -ForegroundColor Black -BackgroundColor Yellow "$env:COMPUTERNAME"
    WriteLine
}
#endregion

#region Remote Install
function Install-Remote ($skipParallelInstall, $remoteFarmServers, $credential, $launchPath, $patchPath)
{
    if (!$RemoteStartDate) {$RemoteStartDate = Get-Date}
    $spYears = @{"14" = "2010"; "15" = "2013"; "16" = "2016"}
    $spVersions = @{"2010" = "14"; "2013" = "15"; "2016" = "16"}
    if ($null -eq $spVer)
    {
        [string]$spVer = (Get-SPFarm).BuildVersion.Major
        if (!$?)
        {
            Start-Sleep 10
            throw "Could not determine version of farm."
        }
    }
    $spYear = $spYears.$spVer
<#  Write-Host -ForegroundColor Green "-----------------------------------"
    Write-Host -ForegroundColor Green "| Automated SP$spYear Patch Install |"
    Write-Host -ForegroundColor Green "| Started on: $RemoteStartDate |"
    Write-Host -ForegroundColor Green "-----------------------------------"
#>
    Write-Host -ForegroundColor White " - Starting remote installs..."
    Enable-CredSSP $remoteFarmServers
    foreach ($server in $remoteFarmServers)
    {
        if (!($skipParallelInstall)) # Launch each farm server install simultaneously
        {
            # Add the -Version 2 switch in case we are installing SP2010 on Windows Server 2012 or 2012 R2
            if (((Get-WmiObject Win32_OperatingSystem).Version -like "6.2*" -or (Get-WmiObject Win32_OperatingSystem).Version -like "6.3*") -and ($spVer -eq "14"))
            {
                $versionSwitch = "-Version 2"
            }
            else {$versionSwitch = ""}
            Start-Process -FilePath "$PSHOME\powershell.exe" -ArgumentList "$versionSwitch `
                                                                            -ExecutionPolicy Bypass Invoke-Command -ScriptBlock {
                                                                            Import-Module -Name `"$launchPath\AutoSPUpdaterModule.psm1`" -DisableNameChecking -Global -Force `
                                                                            StartTracing -Server $server; `
                                                                            Test-ServerConnection -Server $server; `
                                                                            Enable-RemoteSession -Server $server -Password $(ConvertFrom-SecureString $($credential.Password)) -launchPath $launchPath; `
                                                                            Start-RemoteUpdate -Server $server -Password $(ConvertFrom-SecureString $($credential.Password)) -launchPath $launchPath -patchPath $patchPath -spVer $spver; `
                                                                            Pause `"exit`"; `
                                                                            Stop-Transcript}" -Verb Runas
            Start-Sleep 10
        }
        else # Launch each farm server install in sequence, one-at-a-time, or run these steps on the current $targetServer
        {
            WriteLine
            Write-Host -ForegroundColor Green " - Server: $server"
            Import-Module -Name "$launchPath\AutoSPUpdaterModule.psm1" -DisableNameChecking -Global -Force
            Test-ServerConnection -Server $server
            Enable-RemoteSession -Server $server -Password $(ConvertFrom-SecureString $($credential.Password)) -launchPath $launchPath; `
            InstallUpdatesFromPatchPath `
        }
    }
}
function Start-RemoteUpdate ($server, $password, $launchPath, $patchPath, $spVer)
{
    If ($password) {$credential = New-Object System.Management.Automation.PsCredential $env:USERDOMAIN\$env:USERNAME,$(ConvertTo-SecureString $password)}
    If (!$credential) {$credential = $host.ui.PromptForCredential("AutoSPInstaller - Remote Install", "Re-Enter Credentials for Remote Authentication:", "$env:USERDOMAIN\$env:USERNAME", "NetBiosUserName")}
    If ($session.Name -ne "AutoSPUpdaterSession-$server")
    {
        Write-Host -ForegroundColor White " - Starting remote session to $server..."
        $session = New-PSSession -Name "AutoSPUpdaterSession-$server" -Authentication Credssp -Credential $credential -ComputerName $server
    }
    # Create a hash table with major version to product year mappings
    $spYears = @{"14" = "2010"; "15" = "2013"; "16" = "2016"}
    $spYear = $spYears.$spVer
    # Set some remote variables that we will need...
    Invoke-Command -ScriptBlock {param ($value) Set-Variable -Name launchPath -Value $value} -ArgumentList $launchPath -Session $session
    Invoke-Command -ScriptBlock {param ($value) Set-Variable -Name spVer -Value $value} -ArgumentList $spVer -Session $session
    Invoke-Command -ScriptBlock {param ($value) Set-Variable -Name patchPath -Value $value} -ArgumentList $patchPath -Session $session
    Invoke-Command -ScriptBlock {param ($value) Set-Variable -Name credential -Value $value} -ArgumentList $credential -Session $session
    Write-Host -ForegroundColor White " - Launching AutoSPUpdater..."
    Invoke-Command -ScriptBlock {& "$launchPath\AutoSPUpdaterLaunch.ps1" -patchPath $patchPath -remoteAuthPassword $(ConvertFrom-SecureString $($credential.Password))} -Session $session
    Write-Host -ForegroundColor White " - Removing session `"$($session.Name)...`""
    Remove-PSSession $session
}
#endregion

#region Utility Functions
function Pause($action, $key)
{
    # From http://www.microsoft.com/technet/scriptcenter/resources/pstips/jan08/pstip0118.mspx
    if ($key -eq "any" -or ([string]::IsNullOrEmpty($key)))
    {
        $actionString = " - Press any key to $action..."
        if (-not $unattended)
        {
            Write-Host $actionString
            $null = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }
        else
        {
            Write-Host " - Skipping pause due to -unattended switch: $actionString"
        }
    }
    else
    {
        $actionString = " - Enter `"$key`" to $action"
        $continue = Read-Host -Prompt $actionString
        if ($continue -ne $key) {pause $action $key}

    }
}
function Import-SharePointPowerShell
{
    if ($null -eq (Get-PsSnapin |?{$_.Name -eq "Microsoft.SharePoint.PowerShell"}))
    {
        Write-Host -ForegroundColor White " - (Re-)Loading SharePoint PowerShell Snapin..."
        # Added the line below to match what the SharePoint.ps1 file implements (normally called via the SharePoint Management Shell Start Menu shortcut)
        if (Confirm-LocalSession) {$Host.Runspace.ThreadOptions = "ReuseThread"}
        Add-PsSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue | Out-Null
    }
}
function Confirm-LocalSession
{
    if ($Host.Name -eq "ServerRemoteHost") {return $false}
    else {return $true}
}
function Enable-CredSSP ($remoteFarmServers)
{
    foreach ($server in $remoteFarmServers)
    {
        Write-Host -ForegroundColor White " - Enabling WSManCredSSP for `"$server`""
        Enable-WSManCredSSP -Role Client -Force -DelegateComputer $server | Out-Null
        if (!$?) {Pause "exit"; throw $_}
    }
}
function Test-ServerConnection ($server)
{
    Write-Host -ForegroundColor White " - Testing connection (via Ping) to `"$server`"..." -NoNewline
    $canConnect = Test-Connection -ComputerName $server -Count 1 -Quiet
    If ($canConnect) {Write-Host -ForegroundColor Cyan -BackgroundColor Black $($canConnect.ToString() -replace "True","Success.")}
    If (!$canConnect)
    {
        Write-Host -ForegroundColor Yellow -BackgroundColor Black $($canConnect.ToString() -replace "False","Failed.")
        Write-Host -ForegroundColor Yellow " - Check that `"$server`":"
        Write-Host -ForegroundColor Yellow "  - Is online"
        Write-Host -ForegroundColor Yellow "  - Has the required Windows Firewall exceptions set (or turned off)"
        Write-Host -ForegroundColor Yellow "  - Has a valid DNS entry for $server.$($env:USERDNSDOMAIN)"
    }
}
function Enable-RemoteSession ($server, $password, $launchPath)
{
    If ($password) {$credential = New-Object System.Management.Automation.PsCredential $env:USERDOMAIN\$env:USERNAME,$(ConvertTo-SecureString $password)}
    If (!$credential) {$credential = $host.ui.PromptForCredential("AutoSPUpdater - Remote Install", "Re-Enter Credentials for Remote Authentication:", "$env:USERDOMAIN\$env:USERNAME", "NetBiosUserName")}
    $username = $credential.Username
    $password = ConvertTo-PlainText $credential.Password
    $configureTargetScript = "$launchPath\AutoSPUpdaterConfigureRemoteTarget.ps1"
    $psExec = $launchPath+"\PsExec.exe"
    If (!(Get-Item ($psExec) -ErrorAction SilentlyContinue))
    {
        Write-Host -ForegroundColor White " - PsExec.exe not found; downloading..."
        $psExecUrl = "http://live.sysinternals.com/PsExec.exe"
        Import-Module BitsTransfer | Out-Null
        Start-BitsTransfer -Source $psExecUrl -Destination $psExec -DisplayName "Downloading Sysinternals PsExec..." -Priority Foreground -Description "From $psExecUrl..." -ErrorVariable err
        If ($err) {Write-Warning "Could not download PsExec!"; Pause "exit"; break}
        $sourceFile = $destinationFile
    }
    Write-Host -ForegroundColor White " - Updating PowerShell execution policy on `"$server`" via PsExec..."
    Start-Process -FilePath "$psExec" `
                  -ArgumentList "/acceptEula \\$server -h powershell.exe -Command `"Set-ExecutionPolicy Bypass -Force ; Stop-Process -Id `$PID`"" `
                  -Wait -NoNewWindow
    # Another way to exit powershell when running over PsExec from http://www.leeholmes.com/blog/2007/10/02/using-powershell-and-PsExec-to-invoke-expressions-on-remote-computers/
    # PsExec \\server cmd /c "echo . | powershell {command}"
    Write-Host -ForegroundColor White " - Enabling PowerShell remoting on `"$server`" via PsExec..."
    Start-Process -FilePath "$psExec" `
                  -ArgumentList "/acceptEula \\$server -u $username -p $password -h powershell.exe -Command `"$configureTargetScript`"" `
                  -Wait -NoNewWindow
}
function StartTracing ($server)
{
    if (!$isTracing)
    {
        # Look for an existing log file start time in the registry so we can re-use the same log file
        $regKey = Get-Item -Path "HKLM:\SOFTWARE\AutoSPUpdater\" -ErrorAction SilentlyContinue
        If ($regKey) {$script:Logtime = $regkey.GetValue("LogTime")}
        If ([string]::IsNullOrEmpty($logtime)) {$script:Logtime = Get-Date -Format yyyy-MM-dd_h-mm}
        If ($server) {$script:LogFile = "$env:USERPROFILE\Desktop\AutoSPUpdater-$server-$script:Logtime.rtf"}
        else {$script:LogFile = "$env:USERPROFILE\Desktop\AutoSPUpdater-$script:Logtime.rtf"}
        Start-Transcript -Path $logFile -Append -Force
        If ($?) {$script:isTracing = $true}
    }
}
function UnblockFiles ($path)
{
    # Ensure that if we're running from a UNC path, the host portion is added to the Local Intranet zone so we don't get the "Open File - Security Warning"
    If ($path -like "\\*")
    {
        WriteLine
        if (Get-Command -Name "Unblock-File" -ErrorAction SilentlyContinue)
        {
            Write-Host -ForegroundColor White " - Unblocking executable files in $path to prevent security prompts..." -NoNewline
            # Leverage the Unblock-File cmdlet, if available to prevent security warnings when working with language packs, CUs etc.
            Get-ChildItem -Path $path -Recurse | Where-Object {($_.Name -like "*.exe") -or ($_.Name -like "*.ms*") -or ($_.Name -like "*.zip") -or ($_.Name -like "*.cab")} | Unblock-File -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host -ForegroundColor White "Done."
        }
        $safeHost = ($path -split "\\")[2]
        Write-Host -ForegroundColor White " - Adding location `"$safeHost`" to local Intranet security zone to prevent security prompts..." -NoNewline
        New-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains" -Name $safeHost -ItemType Leaf -Force | Out-Null
        New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains\$safeHost" -Name "file" -value "1" -PropertyType dword -Force | Out-Null
        Write-Host -ForegroundColor White "Done."
        WriteLine
    }
}
function WriteLine
{
    Write-Host -ForegroundColor White "--------------------------------------------------------------"
}
<# 
# ===================================================================================
# Func: ConvertTo-PlainText
# Desc: Convert string to secure phrase
#       Used (for example) to get the Farm Account password into plain text as input to provision the User Profile Sync Service
#       From http://www.vistax64.com/powershell/159190-read-host-assecurestring-problem.html
# ===================================================================================
#>
function ConvertTo-PlainText( [security.securestring]$secure )
{
    $marshal = [Runtime.InteropServices.Marshal]
    $marshal::PtrToStringAuto( $marshal::SecureStringToBSTR($secure) )
}
<#
# ====================================================================================
# Func: Show-Progress
# Desc: Shows a row of dots to let us know that $process is still running
# From: Brian Lalancette, 2012
# ====================================================================================
#>
function Show-Progress ($process, $color, $interval)
{
    While (Get-Process -Name $process -ErrorAction SilentlyContinue)
    {
        Write-Host -ForegroundColor $color "." -NoNewline
        Start-Sleep $interval
    }
    Write-Host -ForegroundColor Green "Done."
}
<#
# ====================================================================================
# Func: Test-UpgradeRequired
# Desc: Returns $true if the server or farm requires an upgrade (i.e. requires PSConfig or the corresponding PowerShell commands to be run)
# ====================================================================================
#>
Function Test-UpgradeRequired
{
if ($null -eq $spVer)
{
    $spVer = (Get-SPFarm).BuildVersion.Major
    if (!$?)
    {
        throw "Could not determine version of farm."
    }
}
    $setupType = (Get-Item -Path "HKLM:\SOFTWARE\Microsoft\Shared Tools\Web Server Extensions\$spVer.0\WSS\").GetValue("SetupType")
    If ($setupType -ne "CLEAN_INSTALL") # For example, if the value is "B2B_UPGRADE"
    {
        Return $true
    }
    Else
    {
        Return $false
    }
}
function Check-PSConfig
{
    $PSConfigLogLocation = $((Get-SPDiagnosticConfig).LogLocation) -replace "%CommonProgramFiles%","$env:CommonProgramFiles"
    $PSConfigLog = Get-ChildItem -Path $PSConfigLogLocation | ? {$_.Name -like "PSCDiagnostics*"} | Sort-Object -Descending -Property "LastWriteTime" | Select-Object -first 1
    If ($PSConfigLog -eq $null)
    {
        Throw " - Could not find PSConfig log file!"
    }
    Else
    {
        # Get error(s) from log
        $PSConfigLastError = $PSConfigLog | select-string -SimpleMatch -CaseSensitive -Pattern "ERR" | Select-Object -Last 1
        return $PSConfigLastError
    }
}
function Request-SPSearchServiceApplicationStatus ()
{
    param
    (
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()]
        [ValidateSet("Paused","Online")]
        [String]$desiredStatus
    )

# From https://technet.microsoft.com/en-ca/library/dn745901.aspx
<#
($ssa.IsPaused() -band 0x01) -ne 0 #A change in the number of crawl components or crawl databases is in progress.

($ssa.IsPaused() -band 0x02) -ne 0 #A backup or restore procedure is in progress.

($ssa.IsPaused() -band 0x04) -ne 0 #A backup of the Volume Shadow Copy Service (VSS) is in progress.

($ssa.IsPaused() -band 0x08) -ne 0 #One or more servers in the search topology that host query components are offline.

($ssa.IsPaused() -band 0x20) -ne 0 #One or more crawl databases in the search topology are being rebalanced.

($ssa.IsPaused() -band 0x40) -ne 0 #One or more link databases in the search topology are being rebalanced.

($ssa.IsPaused() -band 0x80) -ne 0 #An administrator has manually paused the Search service application.

($ssa.IsPaused() -band 0x100) -ne 0 #The search index is being deleted. 

($ssa.IsPaused() -band 0x200) -ne 0 #The search index is being repartitioned.
#>

    switch ($desiredStatus)
    {
        "Paused" {$actionWord = "Pausing"; $color = "Yellow"; $action = "Pause"; $cmdlet = "Suspend-SPEnterpriseSearchServiceApplication"; $statusCheck = "((Get-SPEnterpriseSearchServiceApplication -Identity `$searchServiceApplication -ErrorAction SilentlyContinue).IsPaused() -band 0x80) -ne 0"}
        "Online" {$actionWord = "Resuming"; $color = "Green"; $action = "Resume"; $cmdlet = "Resume-SPEnterpriseSearchServiceApplication"; $statusCheck = "(Get-SPEnterpriseSearchServiceApplication -Identity `$searchServiceApplication -ErrorAction SilentlyContinue).IsPaused() -eq 0"}
    }
    if (Get-SPEnterpriseSearchServiceApplication -ErrorAction SilentlyContinue)
    {
        Write-Host -ForegroundColor White " - $actionWord Search Service Application(s)..."
        foreach ($searchServiceApplication in (Get-SPEnterpriseSearchServiceApplication))
        {
            try
            {
                $status = (Invoke-Expression -Command "$statusCheck")
                if ($null -eq $status) {throw}
                if (Invoke-Expression -Command "$statusCheck")
                {
                    Write-Host -ForegroundColor White "  - `"$($searchServiceApplication.Name)`" is already $desiredStatus."
                }
                else
                {
                    if ($action -eq "Resume")
                    {
                        Pause "$($action.ToLower()) `"$($searchServiceApplication.Name)`" after all installs have completed" "y"
                    }
                    Write-Host -ForegroundColor White "  - $actionWord `"$($searchServiceApplication.Name)`"; this can take several minutes..." -NoNewline
                    try
                    {
                        Invoke-Expression -Command "`$searchServiceApplication | $cmdlet"
                        if (!$?) {throw}
                        Invoke-Expression -Command "$statusCheck"
                        if (!$?) {throw}
    ##                    While (!(Invoke-Expression -Command "$statusCheck"))
    ##                    {
    ##                        Write-Host -ForegroundColor White "." -NoNewline
    ##                        Start-Sleep -Seconds 1
    ##                        $searchServiceApplication = Get-SPEnterpriseSearchServiceApplication -Identity $searchServiceApplication
    ##                    }
    ##                    Write-Host -ForegroundColor White "."
                        if (Invoke-Expression -Command "$statusCheck")
                        {
                            Write-Host -ForegroundColor White "  - `"$($searchServiceApplication.Name)`" is now " -NoNewline
                            Write-Host -ForegroundColor $color "$desiredStatus"
                        }
                        else
                        {
                            throw
                        }
                    }
                    catch
                    {
                        Write-Warning "Could not $action `"$($searchServiceApplication.Name)`""
                    }
                }
            }
            catch
            {
             Write-Warning "Could not get status of `"$($searchServiceApplication.Name)`""
            }
        }
        Write-Host -ForegroundColor White " - Done $($actionWord.ToLower()) Search Service Application(s)."
    }
}
function Upgrade-ContentDatabases
{
    Write-Host -ForegroundColor White " - Upgrading SharePoint content databases:"
    [array]$contentDatabases = Get-SPContentDatabase
    foreach ($contentDatabase in $contentDatabases)
    {
        Write-Host -ForegroundColor White "  - $($contentDatabase.Name)..."
        $contentDatabase | Upgrade-SPContentDatabase -Confirm:$false
    }
    Write-Host -ForegroundColor White " - Done upgrading databases."
}
#endregion
