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
        The path of the deployment package stored in the artifact. If there is only one deployment package (.zip file)
        in the artifact, that will be deployed, but if there are more, one must be specified.

    .PARAMETER VstsCredential
        A `PSCredential` object that allows access to Visual Studio Team Services builds. Typically this will be a Personal
        Access Token for a user, with at least read access to builds. For a Personal Access Token the user name is ignored,
        the token should be in the password field (supply any user name, e.g. 'user').

    .PARAMETER MsDeployPath
        The absolute path to `msdeploy.exe`. The default value assumes a default installation of MsDeploy (Web Deploy).
        Must be downloaded and installed first, see https://www.iis.net/downloads/microsoft/web-deploy.

    .PARAMETER WebAppName
        The name of the web app (Web Site) to deploy to. Note that to use this script, a call to `Login-AzureRmAccount`
        will have to be made first, to enable access to Azure.
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
    [string] $WebAppName
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

Set-Variable -Option Constant -Name WorkingDir -Value $env:TMP
Set-Variable -Option Constant -Name ArtifactFilePath -Value (Join-Path $WorkingDir "$VstsBuildArtifactName.zip")
Set-Variable -Option Constant -Name DeployPackageDir -Value $WorkingDir

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
        $list = ([System.Collections.ArrayList] $params)
        $list.Add($VstsApiVersionParam)
        $list -join '&'
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

    Write-Verbose "Downloading build artifact to $ArtifactFilePath"
    Invoke-WebRequest -Uri $artifactUrl -Headers $VstsHeaders -OutFile $ArtifactFilePath
}

<#
.SYNOPSIS
    Opens a build artifact zip file. The zip file will have been downloaded by `Get-BuildArtifact`.
#>
function Open-ArtifactArchive {
    return [System.IO.Compression.ZipFile]::OpenRead($ArtifactFilePath)
}

<#
.SYNOPSIS
    If DeployPackagePathInArtifact has not been specified, checks if there is only one web deployment package in
    the build artifact and if so, returns the path to it, otherwise throws an error.
#>
function Find-DeployPackageInArchive([System.IO.Compression.ZipArchive] $archive) {
    $entryName = if (-not $DeployPackagePathInArtifact) {
        $packages = ($archive.Entries | where FullName -match '\.zip$')
        if ($packages.Count -eq 0) {
            throw "No zip files found in $VstsBuildArtifactName"
        } elseif ($packages.Count -gt 1) {
            throw "Too many zip files found in $VstsBuildArtifactName ($($packages.Count)), use -DeployPackagePathInArtifact with one of $($packages.FullName)"
        }
        Write-Host "Using deploy package $($packages.FullName)"
        $packages.FullName
    } else {
        $DeployPackagePathInArtifact
    }

    return $archive.GetEntry($entryName)
}

<#
.SYNOPSIS
    Expands a Zip file entry to a file in `$DeployPackageDir` and returns the local path to the deployment package.
#>
function Expand-DeployPackageFromArchive([System.IO.Compression.ZipArchiveEntry] $entry) {
    $localFile = Join-Path $DeployPackageDir $entry.Name
    Write-Verbose "Saving deploy package to $localFile"

    $inStream = $entry.Open()
    try {
        $outStream = [System.IO.File]::Create($localFile)
        try {
            $inStream.CopyTo($outStream)
        } finally {
            $outStream.Dispose();
        }
    } finally {
        $inStream.Dispose()
    }

    return $localFile
}

<#
.SYNOPSIS
    Extracts the web deployment package from the build artifact and returns the path to the local file.
#>
function Get-DeployPackage {
    $archive = Open-ArtifactArchive
    try {
        $entry = Find-DeployPackageInArchive $archive
        Expand-DeployPackageFromArchive $entry
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
function Publish-DeployPackage([string] $packagePath) {
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
        -dest:contentPath=`'$WebAppName`'`,ComputerName=`'https://$WebAppName.scm.azurewebsites.net:443/msdeploy.axd?site=$WebAppName`'`,UserName=`'$($config.publishingUserName)`'`,Password=`'$($config.publishingPassword)`'`,AuthType=`'Basic`' `
        -enableRule:AppOffline
    if ($LastExitCode -ne 0) {
        throw "$MsDeployPath returns non-zero exit code: $LastExitCode"
    }
}

<#
.SYNOPSIS
    Removes (temporary) working files created by this script.
#>
function Remove-WorkingFiles([string] $packagePath) {
    Write-Verbose "Removing $ArtifactFilePath"
    Remove-Item -Force $ArtifactFilePath
    if ($packagePath) {
        Write-Verbose "Removing $packagePath"
        Remove-Item -Force $packagePath
    }
}

#
# Main program
#

Assert-MsDeployPath

try {
    # 1. Download the build artifact to a local file
    Get-BuildArtifact

    # 2. Extract the deployment package from that
    $packagePath = Get-DeployPackage

    # 3. Deploy the deployment package
    Publish-DeployPackage $packagePath
} finally {
    Remove-WorkingFiles $packagePath
}
