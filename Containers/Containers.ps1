<# 
.Synopsis
  Installs the given WIM as a container OS image for use with Windows Server or Hyper-V Containers.

.Description
  Installs a base image from a WIM file into the shared central image store for the Windows Server and Hyper-V
  Containers feature.

.Parameter WimPath
  A path to the WIM file that will be installed.
  
.Parameter Force
  Restarts the Virtual Machine Management Service without prompting for confirmation.

.Example
  Install-ContainerOSImage -WimPath c:\baseimage.wim -Force
#>
function Install-ContainerOSImage(
    [parameter(Mandatory=$true,Position=0)]
    [string]$WimPath,
    
    [switch]$Force
    )
{
    $ErrorActionPreference = "Stop"
    $expanded = $false
    $imageFullName = ""
    
    try{
    Write-Host '###################'
        $wimImageIndexes = @{
            'Container' = 1;
            'UtilityVM' = 2;}

        $type = Get-VmComputeNativeMethods

        # Get image information from the WIM.
        $installUtilityVM = $false
        $basicImageInfo = @(Get-WindowsImage -ImagePath $WimPath -LogPath ($env:temp+"dism_$(random)_GetImageInfo.log"))

        switch ($basicImageInfo.Count)
        {
            0
            {
                throw "Unable to get extract image information from '$WimPath'."
            }
            {@(1,2) -contains $_}
            {
                $containerImageInfo = Get-WindowsImage -ImagePath $WimPath -Index $wimImageIndexes['Container'] -LogPath ($env:temp+"dism_$(random)_GetImageInfo_Container.log")

                if ($containerImageInfo -eq $null)
                {
                    throw "'$WimPath' does not contain an image with index $($wimImageIndexes['Container'])."
                }
            }
            2
            {
                $basicUtilityVMImageInfo = $basicImageInfo | ? {$_.ImageIndex -eq $wimImageIndexes['UtilityVM']} | select -First 1

                if ($basicUtilityVMImageInfo -eq $null)
                {
                    throw "'$WimPath' does not contain an image with index $($wimImageIndexes['UtilityVM'])."
                }
            
                $installUtilityVM = $true
            }
            default
            {
                throw "'$WimPath' contains an unexpected number of images ($($basicImageInfo.Count))."
            }
        }
    
        $containerImageName = $containerImageInfo.ImageName
        $containerImageSize = $containerImageInfo.ImageSize
        $containerImageVersion = $containerImageInfo.Version
        $containerImageDate = $containerImageInfo.CreatedTime
        $containerImageDescription = $containerImageInfo.ImageDescription

        # Set up the folders.
        $imageStore = ("Microsoft","Windows","Images") |%{$p = $env:programdata}{$p = join-path $p $_}{$p}
        $imageFullName = ("CN=Microsoft_" + $containerImageName + "_" + $containerImageVersion)
        $imageRoot = Join-Path $imageStore $imageFullName
    
        $baseImageAlreadyExits = $false;
        if (Test-Path $imageRoot) {
            $baseImageAlreadyExits = $true;
        }
    
        $filesPath = Join-Path $imageRoot "Files"
        $hivesPath = Join-Path $imageRoot "Hives"
    
        if(-not (Test-Path $imageRoot)) {
            mkdir $imageRoot > $null
        }

        $hasFiles = Test-Path $filesPath;

        if(-not $hasFiles) {
            mkdir $filesPath > $null
        }
        if(-not (Test-Path $hivesPath)) {
            mkdir $hivesPath > $null
        }
    
        if ($installUtilityVM)
        {
            $baseOsPath = Join-Path $imageRoot "BaseOs"
            mkdir $baseOsPath > $null
        }

        # Write out the json metadata file.
        $json = @{}
        $json.Name = $containerImageName
        $json.Version = $containerImageVersion
        $json.Path = $imageRoot
        $json.Size = $containerImageSize
        $json.CreatedTime = [string]($containerImageDate.ToUniversalTime().GetDateTimeFormats("o"))
    
        # Test for the presence of ConvertTo-Json (which is not currently available on Nano Server).
        if (Get-Command -Name "ConvertTo-Json" -ErrorAction SilentlyContinue)
        {
            $jsonString = ConvertTo-Json $json -Compress
        }
        else
        {
            # Note: this will only work for hash tables with a depth of 1.
            $jsonObjectStrings = @()
        
            foreach ($jsonObject in $json.GetEnumerator())
            {
                $jsonObjectString = "`"$($jsonObject.Key)`":"
            
                switch ($jsonObject.Value.GetType().FullName)
                {
                    "System.String"
                    {
                        $objectValue = $jsonObject.Value
                    
                        $objectValue = $objectValue -replace "\\", "\\"
                        $objectValue = $objectValue -replace "`"", "\`""
                        $objectValue = $objectValue -replace "/", "\/"
                   
                        $jsonObjectString += "`"$($objectValue)`""
                    }        
                    "System.UInt64"
                    {
                        $jsonObjectString += "$($jsonObject.Value)"
                    }
                    default
                    {
                        throw "JSON serialization of the type `"$($jsonObject.Value.GetType().FullName)`" is not supported."
                    }
                }
            
                $jsonObjectStrings += $jsonObjectString
            }
        
            $jsonString = "{$($jsonObjectStrings -join ',')}"
        }

        # Expand the WIM images.
        if(-not $hasFiles) {
            Write-Progress -Activity "Expanding..." -Id 1 -PercentComplete 0
            Expand-WindowsImage -ImagePath $WimPath -Index $wimImageIndexes['Container'] -ApplyPath $filesPath -LogPath ($env:temp+"dism_$(random)_ExpandContainerImage.log") > $null
        }


        if ($installUtilityVM -eq $true)
        {
            Write-Progress -Activity "Expanding..." -Id 1 -PercentComplete 50
            Expand-WindowsImage -ImagePath $WimPath -Index $wimImageIndexes['UtilityVM'] -ApplyPath $baseOsPath -LogPath ($env:temp+"dism_$(random)_ExpandUtilityVMImage.log") > $null
        }
    
        Write-Progress -Activity "Expanding..." -Id 1 -PercentComplete 100
        Write-Progress -Activity "Expanding..." -Id 1 -Completed

        $expanded = $true

        # Copy out the registry hives
        copy (Join-Path $filesPath "\Windows\System32\Config\SYSTEM") "$hivesPath\System_Base" > $null
        copy (Join-Path $filesPath "\Windows\System32\Config\SOFTWARE") "$hivesPath\Software_Base" > $null
        copy (Join-Path $filesPath "\Windows\System32\Config\SAM") "$hivesPath\Sam_Base" > $null
        copy (Join-Path $filesPath "\Windows\System32\Config\SECURITY") "$hivesPath\Security_Base" > $null
        copy (Join-Path $filesPath "\Windows\System32\Config\DEFAULT") "$hivesPath\DefaultUser_Base" > $null

        # We don't want to let users accidentally try and start a nano server 
        # package from their server core host, so mark down what version this 
        # package is so we can check against it at container start time.

        $versionFile = join-path $imageRoot "version.wcx"
        $keyPath = 'HKLM:\SiloPrep\Microsoft\Windows NT\CurrentVersion'

        # The containerImageInfo's version is of the form 10.0.12045.0, so splitnew-
        # it by periods and grab the third value.
        $buildNumber = $containerImageInfo.Version.Split('.')[2]
        $productName = $containerImageInfo.EditionId
        echo BuildNumber=$buildNumber | Out-file $versionFile -Encoding OEM
        echo ProductName=$productName | Out-file $versionFile -Encoding OEM -Append

        # Cache signing information for all files in the container base image (and
        # also in the utility VM base image if one isy present).
        $containerBaseImageFileCount = 0
        $utilityVmBaseImageFileCount = 0
    
        $containerBaseImageState = 0
    
        $returnValue = $type::ContainerCiCacheStart($filesPath, [ref]$containerBaseImageFileCount, [ref]$containerBaseImageState)  
        ThrowCustomErrorIfFailed $returnValue "Failed to start optimization with error:"
    
        $totalFileCount = $containerBaseImageFileCount
    
        if ($installUtilityVM)
        {
            $utilityVmBaseImageState = 0
        
            $returnValue = $type::ContainerCiCacheStart($baseOsPath, [ref]$utilityVmBaseImageFileCount, [ref]$utilityVmBaseImageState)  
            ThrowCustomErrorIfFailed $returnValue "Failed to start optimization with error:"
        
            $totalFileCount += $utilityVmBaseImageFileCount
        
            foreach($i in (1..$utilityVmBaseImageFileCount)){
                Write-Progress -Activity "Optimizing..." -PercentComplete (100*($i/$totalFileCount))
                $returnValue = $type::ContainerCiCacheNext($utilityVmBaseImageState)
               ThrowCustomErrorIfFailed $returnValue "Failed to process file in optimization with error:"
            }
        
            $type::ContainerCiCacheEnd($utilityVmBaseImageState)
        }
    
        foreach($i in (1..$containerBaseImageFileCount)){
            Write-Progress -Activity "Optimizing..." -PercentComplete (100*(($utilityVmBaseImageFileCount + $i)/$totalFileCount))
            $returnValue = $type::ContainerCiCacheNext($containerBaseImageState)
            ThrowCustomErrorIfFailed $returnValue "Failed to process file in optimization with error:"
        }
    
        $type::ContainerCiCacheEnd($containerBaseImageState)
        Write-Progress -Activity "Optimizing..." -Completed
    
        if ($installUtilityVM)
        {
            # Create the utility VM scratch VHD.
            $scratchVhdPath = Join-Path $imageRoot "SystemTemplateBase.vhdx"
            $scratchDiffVhdPath = Join-Path $imageRoot "SystemTemplate.vhdx"
            $scratchMountedVhdPath = Join-Path $env:temp "SystemTemplate_$(random)"
        
            $scratchVhd = New-VHD -Path $scratchVhdPath -Dynamic -SizeBytes 10GB -BlockSizeBytes 1MB
        
            try
            {
                # Mount, initialize, and format the scratch VHD.
                $disk = $scratchVhd | Mount-VHD -PassThru | Get-Disk
                Initialize-Disk -Number $disk.Number -PartitionStyle GPT
                $scratchWindowsPartition = New-Partition -DiskNumber $disk.Number -Size $disk.LargestFreeExtent -GptType "{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}"
                $scratchWindowsVolume = Format-Volume -Partition $scratchWindowsPartition -FileSystem NTFS -Force -Confirm:$false
            
                mkdir $scratchMountedVhdPath > $null
                $scratchWindowsPartition | Add-PartitionAccessPath -AccessPath $scratchMountedVhdPath
            
                $bcdStorePath = Join-Path $baseOsPath "BCD"
            
                if (Test-Path $bcdStorePath)
                {
                    #
                    # Point the scratch VHD's boot device to the base image volume.
                    #
                    Invoke-Win32Command {bcdedit.exe /store $bcdStorePath /set "{default}" device "vmbus={c63c9bdf-5fa5-4208-b03f-6b458b365592}"}
                    Invoke-Win32Command {bcdedit.exe /store $bcdStorePath /set "{default}" osdevice "vmbus={c63c9bdf-5fa5-4208-b03f-6b458b365592}"}
                    Invoke-Win32Command {bcdedit.exe /store $bcdStorePath /set "{default}" osarcdevice hd_partition=$scratchMountedVhdPath}
                }
            
                #
                # Initialize the sandbox.
                #
                $returnValue = $type::InitializeUtilityVMSandbox($scratchMountedVhdPath, [Guid]"{1b3979c8-279b-42eb-b2b9-750767ee9e3f}", $baseOsPath)
                ThrowCustomErrorIfFailed $returnValue "Failed to create blank base image VHD with error:"
            }
            finally
            {
                $scratchWindowsPartition | Remove-PartitionAccessPath -AccessPath $scratchMountedVhdPath -ErrorAction Continue
                $scratchVhd | Dismount-VHD
            }
        
            Defragment-DynamicVhd -Path $scratchVhdPath
        
            # Create a differencing disk on top of the base utility VM scratch VHD.
            $scratchDiffVhd = New-VHD -Path $scratchDiffVhdPath -Differencing -ParentPath $scratchVhdPath -BlockSizeBytes 1MB
        
            # Grant the "NT VIRTUAL MACHINE\Virtual Machines" user R/X permissions to the scratch VHDXs.
            $virtualMachinesCanReadAndExecuteFile = New-Object Security.AccessControl.FileSystemAccessRule("NT VIRTUAL MACHINE\Virtual Machines", "ReadAndExecute", "Allow")
        
            $filesToReAcl = @($scratchVhdPath, $scratchDiffVhdPath)
        
            foreach ($fileToReAcl in $filesToReAcl)
            {
                $acl = Get-Acl $fileToReAcl
                $acl.SetAccessRule($virtualMachinesCanReadAndExecuteFile)
                Set-Acl $fileToReAcl -AclObject $acl
            }
        }
    
        # Setup the blank.vhdx file.
        $basePath = Join-Path "$($env:ProgramData)" "Microsoft\Windows\Images"

        # See if we have already successfully created a blank.vhdx
        $blankPath = Join-Path "$basePath" "blank.vhdx"
        if (!(Test-Path -Path "$blankPath" -PathType Leaf))
        {
            # We dont have a blank.vhdx. Create a temp one.
            $id = Get-Random -Minimum 100 -Maximum 1000
            $tempBlankPath = Join-Path "$basePath" "blank-$id.vhdx"

            try {
                $returnValue = $type::CreateBaseImageVHD($tempBlankPath, 20, 1, "NTFS")
                ThrowCustomErrorIfFailed $returnValue "Failed to create blank base image VHD with error:"

                # If this fails its because blank.vhdx already exists. It could have been another invocation so oh well. We will just clean up our temp.
                try {
                    Move-Item -Path "$tempBlankPath" -Destination "$blankPath"
                } catch {
                    Remove-Item -Path "$tempBlankPath" -Force
                }
            } catch {
                if (Test-Path -Path "$tempBlankPath" -PathType Leaf) {
                    Remove-Item -Path "$tempBlankPath" -Force
                }

                throw
            }
        
            Defragment-DynamicVhd -Path $blankPath
        }

        # Explicitly output the JSON file in UTF8 with no BOM.
        [System.IO.File]::WriteAllLines((Join-Path $imageRoot "metadata.json"), [string[]]@($jsonString), (New-Object System.Text.UTF8Encoding($False)))

        Restart-VMMS -Force:$Force
    } catch {
        if ($expanded) 
        {
            # Try to clean up the directory.
            $type = Get-VmComputeNativeMethods
            $returnValue = $type::DeleteBaseImage($imageFullName)
            if ($returnValue)
            {
                Write-Warning "Failed to clean up image on failed install."
            }
        }

        throw
    }
}

<# 
.Synopsis
  Uninstalls a container OS image.

.Description
  Uninstalls a base image from the shared central image store for Windows Server and Hyper-V Containers.

.Parameter FullName
  Specifies the full name of the container image to uninstall.
  
.Parameter ContainerImage
  Specifies the container image to uninstall.
  
.Parameter Force
  Restarts the Virtual Machine Management Service without prompting for confirmation.

.Example
  Uninstall-ContainerOSImage -FullName "CN=Company_BaseImage_1.0.0.0" -Force
#>
function Uninstall-ContainerOSImage(
    [CmdletBinding(DefaultParametersetName="ByFullName")] 
    [parameter(Mandatory=$true,Position=0,ParameterSetName="ByFullName",ValueFromPipeline=$true)]
    [string]$FullName,

    [parameter(Mandatory=$true,Position=0,ParameterSetName="ByContainerImage",ValueFromPipeline=$true)]
    [Microsoft.Containers.PowerShell.Objects.ContainerImage]$ContainerImage,

    [switch]$Force
    )
{   
    $ErrorActionPreference = "Stop"

    if($ContainerImage){
        $FullName = $ContainerImage.FullName
    }

    $type = Get-VmComputeNativeMethods
    $returnValue = $type::DeleteBaseImage($FullName)
    ThrowCustomErrorIfFailed $returnValue "Failed to uninstall OS image '$FullName' with error:"

    Restart-VMMS -Force:$Force
}

function Invoke-Win32Command(
    [string]$ScriptBlock,
    
    [int[]]$SuccessExitCodes = @(0)
    )
{
    # Print the expanded script block.
    $command = Invoke-Expression ('"' + ($ScriptBlock -replace '"', '`"') + '"')
    
    # Invoke the script block.
    &([ScriptBlock]::Create($ScriptBlock)) | Out-Null

    # Validate that the script block succeeded.
    if ($SuccessExitCodes -notcontains $LASTEXITCODE)
    {
        throw "The command '$command' failed with exit code $LASTEXITCODE."
    }
}

function Restart-VMMS(
    [switch]$Force
    )
{
    if (!$Force)
    {
        Write-Host "You must restart the Virtual Machine Management Service in order to see your changes. Would you like to do that now?"
        $answer = Read-Host '[Y] Yes [N] No (default is "Y")'

        switch ($answer)
        {
            "Y" { $Force = $true }
            ""  { $Force = $true }
            "N" { $Force = $false }
        }
    }

    if ($Force)
    {
        Restart-Service -Name vmms -Force
    }
}

function Defragment-DynamicVhd(
    [string]$Path
    )
{
    $originalVhd = Get-VHD -Path $Path
    $fileExtension = [IO.Path]::GetExtension($Path)
    $tempVhdPath = Join-Path $env:temp "DefragmentVhd_$(random)$fileExtension"
    
    Move-Item -Path $Path -Destination $tempVhdPath
    
    try
    {
        $disk = Mount-VHD -Path $tempVhdPath -PassThru | Get-Disk
        New-VHD -Dynamic -Path $Path -BlockSizeBytes $originalVhd.BlockSize -SourceDisk $disk.Number | Out-Null
    }
    finally
    {
        $tempVhdPath | Dismount-VHD
        Remove-Item $tempVhdPath
    }
}

function ThrowCustomErrorIfFailed(
    [int64]$Hresult,
    [string]$Message
    )
{
    try {
        [System.Runtime.InteropServices.Marshal]::ThrowExceptionForHR(("0x{0:x}" -f $Hresult))
    } catch {
        throw [system.runtime.interopservices.externalexception]::new(
            $Message+" "+$_.exception.innerexception.message, $_.exception.hresult)
    }
}

function Get-VmComputeNativeMethods()
{
        $signature = @'
[DllImport("vmcompute.dll")]
public static extern long
ContainerCiCacheStart(
    [MarshalAs(UnmanagedType.LPWStr)]string Path,
    out UInt32 FileCount,
    out IntPtr State
    );

[DllImport("vmcompute.dll")]
public static extern long
ContainerCiCacheNext(
    IntPtr State
    );

[DllImport("vmcompute.dll")]
public static extern void
ContainerCiCacheEnd(
    IntPtr State
    );

[DllImport("vmcompute.dll")]
public static extern long
DeleteBaseImage(
    [MarshalAs(UnmanagedType.LPWStr)]string Path
    );

[DllImport("vmcompute.dll")]
public static extern long
CreateBaseImageVHD(
    [MarshalAs(UnmanagedType.LPWStr)]string Path,
    UInt32 DiskSizeGB,
    UInt32 BlockSizeMB,
    [MarshalAs(UnmanagedType.LPWStr)]string FileSystem
    );
    
[DllImport("vmcompute.dll")]
public static extern long
InitializeUtilityVMSandbox(
    [MarshalAs(UnmanagedType.LPWStr)]string SandboxRootPath,
    [MarshalAs(UnmanagedType.LPStruct)]Guid ParentLayerId,
    [MarshalAs(UnmanagedType.LPWStr)]string ParentLayerPath
    );

'@

    # Compile into runtime type or load existing type
    try{[Microsoft.Containers.PowerShell.Cmdlets.NativeMethods]}catch{
        Add-Type -MemberDefinition $signature -Namespace Microsoft.Containers.PowerShell.Cmdlets -Name NativeMethods -PassThru
        #[System.Diagnostics.Debug.Debugger]::Break();
    }
}
