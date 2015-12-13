
$references = ('Microsoft.Containers.PowerShell.Cmdlets')

foreach($ref in $references) {
    $assembly = [System.Reflection.Assembly]::LoadWithPartialName($ref);
    $mod = Import-Module  -Scope Global -Assembly $assembly -PassThru -Force
    $mod = Import-Module  -Scope Global -Assembly $assembly -PassThru -Force -Function 'Install-ContainerOSImage'

}
