# PREREQS
# * Install Azure Powershell
# * Install MS Web Deploy: https://www.iis.net/downloads/microsoft/web-deploy
# * Log in to Azure using `Login-AzureRmAccount`

<#
    .DESCRIPTION
        Downloads an artifact from a VSTS build and deploys it to an Azure web site.

    .SYNOPSIS
        This script facilitates setting up an developer-specific dev environment on Azure. Often, it is overkill to place
        every developer's development environment in Visual Studio Team Services release management as a separate environment,
        this script automates the fetch-and-deploy part.

        Typically, a developer will:
        1. Create a resource group
        2. Run the ARM template for the web app, providing a specific parameter file
        3. Run this script, possibly for several web apps
        4. Do work (e.g. deploy debug builds from Visual Studio, remote debug, etc.)
        5. Remove the resource group

    .EXAMPLE
        E:\Publish-WebApp.ps1 -Verbose -VstsInstanceName myvsts -VstsCredential $vstsCred -VstsProjectName Experiments -VstsBuildDefinitionName webmvc -WebAppName webmvc-dev -VstsBuildNumber 16

        Deploys 'webmvc' build 16 from the 'Experiments' team space to an existing web app 'webmvc-dev'.
        `$vstsCred` has been created using `$vstsCred = Get-Credential`.

    .PARAMETER VstsInstanceName
        The Visual Studio Team Services account to use: https://$VstsInstanceName.visualstudio.com

    .PARAMETER VstsProjectName
        The team project space name in Visual Studio Team Services

    .PARAMETER VstsBuildDefinitionName
        The name of the build definition to get the build artifact from

    .PARAMETER VstsBuildNumber
        The build number to use (e.g. '20161212.1' for a build whose page has heading 'Build 20161212.1').
        If not specified, the last successful build will be used.

    .PARAMETER VstsBuildArtifactName
        The name of the artifact to deploy. By default this will be `drop`, but might be different if a build definition
        publishes to a different artifact.

    .PARAMETER DeployPackagePathInArtifact
        The path of the deployment package stored in the artifact. If not specified, all deployment packages found
        in the build artifact (all zip files) will be deployed to the same web application.

    .PARAMETER VstsCredential
        A `PSCredential` object that allows access to Visual Studio Team Services builds. Typically this will be a Personal
        Access Token for a user, with at least read access to builds. For a Personal Access Token the user name is ignored,
        the token should be in the password field (supply any user name, e.g. 'user').

    .PARAMETER MsDeployPath
        The absolute path to `msdeploy.exe`. The default value assumes a default installation of MsDeploy (Web Deploy).
        Must be downloaded and installed first, see https://www.iis.net/downloads/microsoft/web-deploy.

    .PARAMETER WebAppName
        The name of the web app (Web Site) to deploy to. Note that to use this script, a call to `Login-AzureRmAccount`
        will have to be made first, to enable access to Azure, followed by `Select-AzureRmSubscription` to activate
        the proper subscription.

    .PARAMETER DoNotDeleteCurrentWebAppContents
        When passed, the current contents of the web application will not be removed, only new content will be added (which
        might overwrite existing files). When not passed, any files that exist in the web application but not in the deployment
        package will be removed.

        If there are several deployment packages in the build artifact, when deploying the first package will any other contents
        be removed, not for following packages.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string] $VstsInstanceName,

    [Parameter(Mandatory=$true)]
    [string] $VstsProjectName,

    [Parameter(Mandatory=$true)]
    [string] $VstsBuildDefinitionName,

    # when $null, we'll take the latest build
    [string] $VstsBuildNumber,

    [string] $VstsBuildArtifactName = 'drop',

    # when null, if there is only one zip file in the artifact, that will be used, if there are more an exception is thrown
    [string] $DeployPackagePathInArtifact,

    # If the password is a PAT, the user will be ignored and therefore can have any value
    # Typically, a PAT will be used that only has read access to builds.
    [Parameter(Mandatory=$true)]
    [pscredential] $VstsCredential,

    [string] $MsDeployPath = 'C:\Program Files\IIS\Microsoft Web Deploy V3\msdeploy.exe',

    [Parameter(Mandatory=$true)]
    [string] $WebAppName,

    [switch] $DoNotDeleteCurrentWebAppContents
)

# stop on errors
$ErrorActionPreference = 'Stop'

Write-Verbose "VstsInstanceName            = $VstsInstanceName"
Write-Verbose "VstsProjectName             = $VstsProjectName"
Write-Verbose "VstsBuildDefinitionName     = $VstsBuildDefinitionName"
Write-Verbose "VstsBuildNumber             = $VstsBuildNumber"
Write-Verbose "VstsBuildArtifactName       = $VstsBuildArtifactName"
Write-Verbose "DeployPackagePathInArtifact = $DeployPackagePathInArtifact"
Write-Verbose "VstsCredential              = $($VstsCredential.UserName)/***"
Write-Verbose "MsDeployPath                = $MsDeployPath"
Write-Verbose "WebAppName                  = $WebAppName"

Set-Variable -Option Constant -Name VstsBaseUrl -Value `
    "https://$VstsInstanceName.visualstudio.com/DefaultCollection/$VstsProjectName/_apis"

Set-Variable -Option Constant -Name VstsApiVersionParam -Value 'api-version=2.0'
Set-Variable -Option Constant -Name VstsAuth -Value ([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(
    "$($VstsCredential.UserName):$($VstsCredential.GetNetworkCredential().Password)"
)))
Set-Variable -Option Constant -Name VstsHeaders -Value @{Authorization = "Basic $VstsAuth"}

Set-Variable -Option Constant -Name WorkingDir -Value (Join-Path $env:TMP 'Publish-WebApp')

Write-Verbose "ArtifactFilePath            = $ArtifactFilePath"

# we need this for Zip support for our artifact
Add-Type -AssemblyName System.IO.Compression.FileSystem

<#
.SYNOPSIS
    Sends a request using VSTS Rest API and returns the result (from `Invoke-RestMethod`).
#>
function Send-VstsRequest([string] $resource, [string[]] $params) {
    $urlParams = if ($params -eq $null -or $params.Length -eq 0) {
        $VstsApiVersionParam
    } else {
        ($params += $VstsApiVersionParam) -join '&'
    }

    return Invoke-RestMethod -Uri "${VstsBaseUrl}${resource}?${urlParams}" -Headers $VstsHeaders
}

<#
.SYNOPSIS
    Returns the build ID for the given definition name (VstsBuildDefinitionName).
#>
function Find-BuildDefinitionID {
    $buildDef = (Send-VstsRequest '/build/definitions').value | where name -eq $VstsBuildDefinitionName

    if (-not $buildDef) {
        throw "No build definition with name $VstsBuildDefinitionName found."
    }

    Write-Verbose "Build def $VstsBuildDefinitionName has ID $($buildDef.id)"
    return $buildDef.id;
}

<#
.SYNOPSIS
    If VstsBuildNumber has been provided, returns the internal build ID for that build, or looks for the latest successful
    build and returns the ID from that.
#>
function Find-BuildID([string] $definitionID) {
    $params = @(
        "definitions=$definitionID",
        "statusFilter=completed"
    )
    $builds = (Send-VstsRequest '/build/builds' $params).value | where result -eq succeeded
    $build = if ($VstsBuildNumber) {
        $selectBuild = $builds | where buildNumber -eq $VstsBuildNumber
        if (-not $selectBuild) {
            throw "Build number not found: $VstsBuildNumber (available: $($builds.buildNumber))"
        }
        $selectBuild[0]
    } else {
        $builds[0]
    }
    Write-Host "Using $VstsBuildDefinitionName build with number $($build.buildNumber)"
    return $build.id
}

<#
.SYNOPSIS
    For a specific build ID, finds the artifact download URL, which will be used later to download it. Uses
    VstsBuildArtifactName to select the artifact.
#>
function Find-BuildArtifactUrl([string] $buildID) {
    $artifact = (Send-VstsRequest "/build/builds/$buildID/artifacts").value | where name -eq $VstsBuildArtifactName
    if (-not $artifact) {
        throw "No artifact with name '$VstsBuildArtifactName' found in $VstsBuildDefinitionName/$buildID"
    }
    $url = $artifact.resource.downloadUrl
    Write-Verbose "Artifact URL is $url"
    return $url
}

<#
.SYNOPSIS
    Aggregation method that downloads the build artifact, given the input parameters to this script.
#>
function Get-BuildArtifact {
    $buildDefId = Find-BuildDefinitionID
    $buildId = Find-BuildID $buildDefId
    $artifactUrl = Find-BuildArtifactUrl $buildId

    $targetDir = [System.IO.Path]::Combine($WorkingDir, $VstsInstanceName, $buildDefId, $buildId)
    $targetFile = Join-Path $targetDir "$VstsBuildArtifactName.zip"

    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }
    if (Test-Path $targetFile) {
        Write-Verbose "Skipping download of $targetFile; using cached version"
    } else {
        Write-Verbose "Downloading build artifact to $targetFile"
        Invoke-WebRequest -Uri $artifactUrl -Headers $VstsHeaders -OutFile $targetFile
    }
    return $targetFile
}

<#
.SYNOPSIS
    Opens a build artifact zip file. The zip file will have been downloaded by `Get-BuildArtifact`.
#>
function Open-ArtifactArchive([string] $artifactPath) {
    return [System.IO.Compression.ZipFile]::OpenRead($artifactPath)
}

<#
.SYNOPSIS
    If DeployPackagePathInArtifact has not been specified, finds all deployment packages (zip files) in the archive.
    If DeployPackagePathInArtifact has a value, that is symply returned.
#>
function Find-DeployPackagesInArchive([System.IO.Compression.ZipArchive] $archive) {
    $entryNames = if (-not $DeployPackagePathInArtifact) {
        $packages = ($archive.Entries | Where-Object FullName -match '\.zip$')
        if ($packages.Count -eq 0) {
            throw "No zip files found in $VstsBuildArtifactName"
        }
        $packages.FullName
    } else {
        @($DeployPackagePathInArtifact)
    }
    Write-Host "Using deploy packages $entryNames"

    return $entryNames | ForEach-Object { $archive.GetEntry($_) }
}

<#
.SYNOPSIS
    Expands a Zip file entry to a file in `$WorkingDir` and returns the local path to the deployment package.
#>
function Expand-DeployPackageFromArchive([System.IO.Compression.ZipArchiveEntry] $entry) {
    $localFile = Join-Path $WorkingDir $entry.Name
    Write-Verbose "Saving deploy package to $localFile"

    $inStream = $entry.Open()
    try {
        $outStream = [System.IO.File]::Create($localFile)
        try {
            $inStream.CopyTo($outStream)
        } finally {
            $outStream.Dispose()
        }
    } finally {
        $inStream.Dispose()
    }

    return $localFile
}

<#
.SYNOPSIS
    Extracts the web deployment packages from the build artifact and returns the path to the local file.
#>
function Get-DeployPackages([string] $artifactPath) {
    $archive = Open-ArtifactArchive $artifactPath
    try {
        Find-DeployPackagesInArchive $archive | ForEach-Object { Expand-DeployPackageFromArchive $_ }
    } finally {
        $archive.Dispose()
    }
}

<#
.SYNOPSIS
    Quick check if msdeploy has been installed and `MsDeployPath` points to it.
#>
function Assert-MsDeployPath {
    if (-not (Test-Path -PathType Leaf -Path $MsDeployPath)) {
        throw "msdeploy not found: $MsDeployPath. Specify the correct value using -MsDeployPath or install from https://www.iis.net/downloads/microsoft/web-deploy"
    }
    Write-Verbose "MsDeployPath appears valid"
}

<#
.SYNOPSIS
    Deploys the web deployment package at `packagePath` to the Azure web site with name `WebAppName`.
#>
function Publish-DeployPackage([string] $packagePath, [bool] $doNotDelete) {
    Write-Host "Publishing $packagePath to $WebAppName"
    # find the resource group for the web app
    $webApp = Get-AzureRmWebApp -Name $WebAppName -ErrorAction SilentlyContinue
    if (-not $webApp) {
        throw "Web app $WebAppName not found"
    }
    Write-Verbose "Web app $WebAppName is in resource group $($webApp.ResourceGroup)"

    # get the username and password for our deployment
    $config = (Invoke-AzureRmResourceAction -ResourceGroupName $webApp.ResourceGroup -ResourceType Microsoft.Web/sites/config `
        -ResourceName $WebAppName/publishingcredentials -Action list -ApiVersion 2015-08-01 -Force).Properties
    Write-Verbose "Got deployment credentials: $($config.publishingUserName)/***"

    # now run msdeploy to update the web site
    & $MsDeployPath -verb:sync -source:package=`'$packagePath`' `
        -dest:auto`,ComputerName=`'https://$WebAppName.scm.azurewebsites.net:443/msdeploy.axd?site=$WebAppName`'`,UserName=`'$($config.publishingUserName)`'`,Password=`'$($config.publishingPassword)`'`,AuthType=`'Basic`' `
        -setParam:name=`'IIS Web Application Name`',value=`'$WebAppName`' -enableRule:AppOffline `
        $(if ($doNotDelete) { '-enableRule:DoNotDeleteRule' })
    if ($LastExitCode -ne 0) {
        throw "$MsDeployPath returns non-zero exit code: $LastExitCode"
    }
}

<#
.SYNOPSIS
    Removes (temporary) working files created by this script.
#>
function Remove-WorkingFiles([string[]] $packagePaths) {
    if ($packagePaths) {
        $packagePaths | ForEach-Object {
            if (Test-Path -Path $_) {
                Write-Verbose "Removing $_"
                Remove-Item -Force $_
            }
        }
    }
}

#
# Main program
#

Assert-MsDeployPath

try {
    # 1. Download the build artifact to a local file
    $artifactPath = Get-BuildArtifact

    # 2. Extract the deployment packages from that
    $packagePaths = Get-DeployPackages $artifactPath

    # 3. Deploy the deployment packages
    $packagePaths | ForEach-Object {
        # if there are multiple deployment packages, only allow DoNotDelete for the first deployment
        $doNotDelete = if ($doneOne) { $true } else {
            $doneOne = $true
            $DoNotDeleteCurrentWebAppContents
        }
        Publish-DeployPackage $_ $doNotDelete
    }
} finally {
    Remove-WorkingFiles $packagePaths
}
