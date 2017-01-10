# Publish-WebApp

Downloads an artifact from a VSTS build and deploys it to an Azure web site.

This script facilitates setting up an developer-specific dev environment on Azure. Often, it is overkill to place
every developer's development environment in Visual Studio Team Services release management as a separate environment,
this script automates the fetch-and-deploy part.

Typically, a developer will:

1. Create a resource group
2. Run the ARM template for the web app, providing a specific parameter file
3. Run this script, possibly for several web apps
4. Do work (e.g. deploy debug builds from Visual Studio, remote debug, etc.)
5. Remove the resource group

## Example

    E:\Publish-WebApp.ps1 -Verbose -VstsInstanceName myvsts -VstsCredential $vstsCred -VstsProjectName Experiments -VstsBuildDefinitionName webmvc -WebAppName webmvc-dev -VstsBuildNumber 16

Deploys _webmvc_ build 16 from the _Experiments_ team space to an existing web app called _webmvc-dev_.
`$vstsCred` has been created using `$vstsCred = Get-Credential` (can be alternate credentials, or any
non-empty user name and a personal access token as password).

## Parameters

*   `VstsInstanceName` (**Mandatory**): the Visual Studio Team Services account to use: `https://$VstsInstanceName.visualstudio.com`
*   `VstsProjectName` (**Mandatory**): the team project space name in Visual Studio Team Services
*   `VstsBuildDefinitionName` (**Mandatory**): the name of the build definition to get the build artifact from
*   `VstsBuildNumber` (**Optional**, defaults to latest successful build): the build number to use (e.g. '20161212.1' for a build
    whose page has heading 'Build 20161212.1'). If not specified, the last successful build will be used.
*   `VstsBuildArtifactName` (**Optional**, defaults to _drop_): the name of the artifact to deploy. By default this will be `drop`,
    but might be different if a build definition publishes to a different artifact.
*   `DeployPackagePathInArtifact` (**Optional**, defaults to all `.zip` files in the build artifact): the path of the deployment
    package stored in the artifact. If not specified, all deployment packages found in the build artifact (all zip files) will be
    deployed to the same web application.
*   `VstsCredential` (**Mandatory**): a `PSCredential` object that allows access to Visual Studio Team Services builds. Typically this
    will be a Personal Access Token for a user, with at least read access to builds. For a Personal Access Token the user
    name is ignored, the token should be in the password field (supply any user name, e.g. 'user').
*   `MsDeployPath` (**Optional**, defaults to `C:\Program Files\IIS\Microsoft Web Deploy V3\msdeploy.exe`): the absolute path to
    `msdeploy.exe`. The default value assumes a default installation of MsDeployPath (Web Deploy). Must be downloaded and installed
    first, see https://www.iis.net/downloads/microsoft/web-deploy.
*   `WebAppName` (**Mandatory**): the name of the web app (Web Site) to deploy to. Note that to use this script, a call to
    `Login-AzureRmAccount` will have to be made first, to enable access to Azure, followed by `Select-AzureRmSubscription` to activate
    the proper subscription.
*   `DoNotDeleteCurrentWebAppContents` (**Optional**, defaults to `$false`): when passed, the current contents of the web application
    will not be removed, only new content will be added (which might overwrite existing files). When not passed, any files that exist
    in the web application but not in the deployment package will be removed.

    If there are several deployment packages in the build artifact, when deploying the first package will any other contents
    be removed, not for following packages.

## License

[MIT](LICENSE.md)