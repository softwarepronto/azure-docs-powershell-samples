Param(
    [parameter(Mandatory=$true)]
    $CsvFilePath
)

$ErrorActionPreference = "Stop"

$scriptsPath = $PSScriptRoot
if ($PSScriptRoot -eq "") {
    $scriptsPath = "."
}

. "$scriptsPath\AzMigrate_Logger.ps1"
. "$scriptsPath\AzMigrate_Shared.ps1"
. "$scriptsPath\AzMigrate_CSV_Processor.ps1"

Function ProcessItemImpl($processor, $csvItem, $reportItem) {

    $reportItem | Add-Member NoteProperty "AdditionalInformation" $null

    $sourceMachineName = $csvItem.SOURCE_MACHINE_NAME
    if ([string]::IsNullOrEmpty($sourceMachineName)) {
        $processor.Logger.LogError("SOURCE_MACHINE_NAME is not mentioned in the csv file")
        $reportItem.AdditionalInformation = "SOURCE_MACHINE_NAME is not mentioned in the csv file" 
        return
    }
    $azMigrateRG = $csvItem.AZMIGRATEPROJECT_RESOURCE_GROUP_NAME
    if ([string]::IsNullOrEmpty($azMigrateRG)) {
        $processor.Logger.LogError("AZMIGRATEPROJECT_RESOURCE_GROUP_NAME is not mentioned for: '$($sourceMachineName)'")
        $reportItem.AdditionalInformation = "AZMIGRATEPROJECT_RESOURCE_GROUP_NAME is not mentioned for: '$($sourceMachineName)'"
        return
    }
    $azMigrateProjName = $csvItem.AZMIGRATEPROJECT_NAME
    if ([string]::IsNullOrEmpty($azMigrateProjName)) {
        $processor.Logger.LogError("AZMIGRATEPROJECT_NAME is not mentioned for: '$($sourceMachineName)'")
        $reportItem.AdditionalInformation = "AZMIGRATEPROJECT_NAME is not mentioned for: '$($sourceMachineName)'"
        return
    }
    $azMigrateApplianceName = $csvItem.AZMIGRATE_APPLIANCE_NAME
    if ([string]::IsNullOrEmpty($azMigrateApplianceName)) {
        $processor.Logger.LogError("AZMIGRATE_APPLIANCE_NAME is not mentioned for: '$($sourceMachineName)'")
        $reportItem.AdditionalInformation = "AZMIGRATE_APPLIANCE_NAME is not mentioned for: '$($sourceMachineName)'"
        return
    }
    
    #lets validate if we can/should run TestMigrate at all for this machine
    $ReplicatingServermachine = $AzMigrateShared.GetReplicationServer($azMigrateRG, $azMigrateProjName, $sourceMachineName, $azMigrateApplianceName)
    if((-not $ReplicatingServermachine) -or ($csvItem.OK_TO_TESTMIGRATE -ne 'Y') `
        -or ($ReplicatingServermachine.TestMigrateState -ne "None") -or ($ReplicatingServermachine.TestMigrateStateDescription -ne "None") `
        -or (($ReplicatingServermachine.MigrationState -ne "Replicating") -and ($ReplicatingServermachine.MigrationStateDescription -ne "Ready to migrate")) `
        -or (-not ($ReplicatingServermachine.AllowedOperation -contains "TestMigrate"))){

        $processor.Logger.LogError("We cannot initiate Test Migration as either is it not configured in csv file OR the state of this machine replication is not suitable for initiating Test Migration Now: '$($sourceMachineName)'")
        $reportItem.AdditionalInformation = "We cannot initiate Test Migration as either is it not configured in csv file OR the state of this machine replication is not suitable for initiating Test Migration Now: '$($sourceMachineName)'. Please Run AzMigrate_UpdateReplicationStatus.ps1 and look at the output csv file which may provide more details"
        $processor.Logger.LogTrace("Current Migration State of machine: '$($ReplicatingServermachine.MigrationState)'")
        $processor.Logger.LogTrace("Current Migration State Description of machine: '$($ReplicatingServermachine.MigrationStateDescription)'")
        $processor.Logger.LogTrace("Current Test Migration State of machine: '$($ReplicatingServermachine.TestMigrateState)'")
        $processor.Logger.LogTrace("Current Test Migration State Description of machine: '$($ReplicatingServermachine.TestMigrateStateDescription)'")
        foreach($AO in $ReplicatingServermachine.AllowedOperation)
        {
            $processor.Logger.LogTrace("Allowed Operation: '$($AO)'")
        }
        return
    }
    
    #Code added to accommodate for Target Subscription if the replicated machine is suppose to land in a different Target subscription
    $targetSubscriptionID = $csvItem.TARGET_SUBSCRIPTION_ID
    if ([string]::IsNullOrEmpty($targetSubscriptionID)) {
        $processor.Logger.LogTrace("TARGET_SUBSCRIPTION_ID is not mentioned for: '$($sourceMachineName)'")
        $reportItem.AdditionalInformation = "TARGET_SUBSCRIPTION_ID is not mentioned for: '$($sourceMachineName)'"         
    }
    else {
        Set-AzContext -SubscriptionId $targetSubscriptionID
    }    
    #End Code for Target Subscription

    $targetVnetName = $csvItem.TESTMIGRATE_VNET_NAME
    if ([string]::IsNullOrEmpty($targetVnetName)) {
        $processor.Logger.LogError("TESTMIGRATE_VNET_NAME is not mentioned for: '$($sourceMachineName)'")
        $reportItem.AdditionalInformation = "TESTMIGRATE_VNET_NAME is not mentioned for: '$($sourceMachineName)'"
        return
    }
    
    #Get the testmigrate VirtualNetwork Name where we want to provision the VM in Azure
    $Target_VNet = Get-AzVirtualNetwork -Name $targetVnetName
    if (-not $Target_VNet) {
        $processor.Logger.LogError("VNET could not be retrieved for: '$($targetVnetName)'")
        $reportItem.AdditionalInformation = "VNET could not be retrieved for: '$($targetVnetName)'"
        return
    }
    

    #Code added to accommodate for Target Subscription if the replicated machine is suppose to land in a different Target subscription
    #We are reverting to Azure Migrate Subscription
    if (-not([string]::IsNullOrEmpty($targetSubscriptionID))) {
        $azMigProjSubscriptionID = $csvItem.AZMIGRATEPROJECT_SUBSCRIPTION_ID
        if ([string]::IsNullOrEmpty($azMigProjSubscriptionID)){
            $processor.Logger.LogTrace("AZMIGRATEPROJECT_SUBSCRIPTION_ID is not mentioned for: '$($sourceMachineName)'")
            $reportItem.AdditionalInformation = "AZMIGRATEPROJECT_SUBSCRIPTION_ID is not mentioned for: '$($sourceMachineName)'"
            return
        }
        else {
            Set-AzContext -SubscriptionId $azMigProjSubscriptionID
        }        
    } 
    #End Code for Target Subscription

    $osUpgradeVersion = $csvItem.OS_UPGRADE_VERSION
    
    if([string]::IsNullOrEmpty($osUpgradeVersion)){
        $processor.Logger.LogTrace("OS_UPGRADE_VERSION is not mentioned for: '$($sourceMachineName)'")
        $reportItem.AdditionalInformation = "OS_VERSION_UPGRADE is not mentioned for: '$($sourceMachineName)'"
        $TestMigrationJob = Start-AzMigrateTestMigration -InputObject $ReplicatingServermachine -TestNetworkID $Target_VNet.Id
    } 
    else{
        $TestMigrationJob = Start-AzMigrateTestMigration -InputObject $ReplicatingServermachine -TestNetworkID $Target_VNet.Id -OsUpgradeVersion $osUpgradeVersion
    }

    if (-not $TestMigrationJob){
        $processor.Logger.LogError("Test Migration Job couldn't be initiated for the specified machine: '$($sourceMachineName)'")    
        $reportItem.AdditionalInformation = "Test Migration Job couldn't be initiated for the specified machine: '$($sourceMachineName)'"
    }
    else {
        $processor.Logger.LogTrace("Test Migration Job is initiated for the specified machine: '$($sourceMachineName)'")    
    }   
    
}

Function ProcessItem($processor, $csvItem, $reportItem) {
    try {
        ProcessItemImpl $processor $csvItem $reportItem
    }
    catch {
        $exceptionMessage = $_ | Out-String
        $reportItem.Exception = $exceptionMessage
        $processor.Logger.LogErrorAndThrow($exceptionMessage)                
    }
}

$logger = New-AzMigrate_LoggerInstance -CommandPath $PSCommandPath
$AzMigrateShared = New-AzMigrate_SharedInstance -Logger $logger
$processor = New-CsvProcessorInstance -logger $logger -processItemFunction $function:ProcessItem
$processor.ProcessFile($CsvFilePath)
