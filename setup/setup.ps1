write-host "Starting script at $(Get-Date)"

Install-Module -Name Az.Synapse

$sqlDatabaseName = "sqldw"
$sqlUser = "SQLUser"

# Prompt user for a password for the SQL Database
write-host ""
$sqlPassword = ""
$complexPassword = 0

while ($complexPassword -ne 1)
{
    $SqlPassword = Read-Host "Enter a password to use for your database server.
    `The password must meet complexity requirements:
    ` - Minimum 8 characters. 
    ` - At least one upper case English letter [A-Z
    ` - At least one lower case English letter [a-z]
    ` - At least one digit [0-9]
    ` - At least one special character (!,@,#,%,^,&,$)
    ` "

    if(($SqlPassword -cmatch '[a-z]') -and ($SqlPassword -cmatch '[A-Z]') -and ($SqlPassword -match '\d') -and ($SqlPassword.length -ge 8) -and ($SqlPassword -match '!|@|#|%|^|&|$'))
    {
        $complexPassword = 1
	  Write-Output "Password $SqlPassword accepted. Make sure you remember this!"
    }
    else
    {
        Write-Output "$SqlPassword does not meet the compexity requirements."
    }
}

# Register resource providers
Write-Host "Registering resource providers...";
Register-AzResourceProvider -ProviderNamespace Microsoft.Synapse
Register-AzResourceProvider -ProviderNamespace Microsoft.Sql
Register-AzResourceProvider -ProviderNamespace Microsoft.Storage
Register-AzResourceProvider -ProviderNamespace Microsoft.Compute

# Generate unique random suffix
[string]$suffix =  -join ((48..57) + (97..122) | Get-Random -Count 7 | % {[char]$_})
Write-Host "Your randomly-generated suffix for Azure resources is $suffix"
$resourceGroupName = "dp500-$suffix"

# Choose a random region
Write-Host "Finding an available region. This may take several minutes...";
$preferred_list = "australiaeast","centralus","southcentralus","eastus2","northeurope","southeastasia","uksouth","westeurope","westus","westus2"
$locations = Get-AzLocation | Where-Object {
    $_.Providers -contains "Microsoft.Synapse" -and
    $_.Providers -contains "Microsoft.Sql" -and
    $_.Providers -contains "Microsoft.Storage" -and
    $_.Providers -contains "Microsoft.Compute" -and
    $_.Location -in $preferred_list
}
$max_index = $locations.Count - 1
$rand = (0..$max_index) | Get-Random
$Region = $locations.Get($rand).Location

# Try to create a SQL Database resource to test for capacity constraints
# (for some subsription types, quotas are adjusted dynamically based on capacity)
 $success = 0
 $tried_list = New-Object Collections.Generic.List[string]
 $testPassword = ConvertTo-SecureString $SqlPassword -AsPlainText -Force
 $testCred = New-Object System.Management.Automation.PSCredential ("SQLUser", $testPassword)
 $testServer = "testsql$suffix"
 while ($success -ne 1){
     try {
         write-host "Trying $Region"
         $success = 1
         New-AzResourceGroup -Name $resourceGroupName -Location $Region | Out-Null
         New-AzSqlServer -ResourceGroupName $resourceGroupName -Location $Region -ServerName $testServer -ServerVersion "12.0" -SqlAdministratorCredentials $testCred -ErrorAction Stop | Out-Null
     }
     catch {
       Remove-AzResourceGroup -Name $resourceGroupName -Force
       $success = 0
       $tried_list.Add($Region)
       $locations = $locations | Where-Object {$_.Location -notin $tried_list}
       $rand = (0..$($locations.Count - 1)) | Get-Random
       $Region = $locations.Get($rand).Location
     }
}
Remove-AzSqlServer -ResourceGroupName $resourceGroupName -ServerName $testServer | Out-Null

Write-Host "Selected region: $Region"

# Create Synapse workspace
$synapseWorkspace = "synapsews$suffix"

write-host "Creating $synapseWorkspace Synapse Analytics workspace in $resourceGroupName resource group..."
New-AzResourceGroupDeployment -ResourceGroupName $resourceGroupName `
  -TemplateFile "setup.json" `
  -Mode Complete `
  -workspaceName $synapseWorkspace `
  -uniqueSuffix $suffix `
  -sqlDatabaseName $sqlDatabaseName `
  -sqlUser $sqlUser `
  -sqlPassword $sqlPassword `
  -Force

# Create database
write-host "Creating database schema..."
sqlcmd -S "$synapseWorkspace.sql.azuresynapse.net" -U $sqlUser -P $sqlPassword -d $sqlDatabaseName -I -i setup.sql

# Load data
write-host "Loading data..."
foreach($file in Get-ChildItem "./data")
{
    Write-Host "$file"
    bcp "dbo.$file" in $file -S "$synapseWorkspace.sql.azuresynapse.net" -U -U $sqlUser -P $sqlPassword -d $sqlDatabaseName
}

# Pause SQL Pool
write-host "Pausing the $sqlDatabaseName SQL Pool..."
Suspend-AzSynapseSqlPool -WorkspaceName $synapseWorkspace -Name $sqlDatabaseName

write-host "Script completed at $(Get-Date)"