<#
  This runbook will read all resources that can be accessed with the client id provided.
  All available data from the resource providers will be imported and Virtual Machines will be enriched with their vm size.
  The data will be pushed to the ServiceNow instance provided in the input. 
  A local ServiceNow user that can write to an import set table must be provided.
  The import set table must include the following fields
  location [string, 64]
  name [string, 64]
  namespace [string, 64]
  properties [string, 4096]
  resource_group [string, 128]
  resource_id [string, 256]
  resource_type [string, 128]
  subscription_id [string, 36]
  subscription_name [string, 128]
  sku [string, 512]
  tags [string, 1024]
  instance_view [string, 4096]
#>

param (
  [Parameter(Mandatory=$true)]
	[string] $ServiceNowInstance
)

# * Environment variabels * #
# Set the below to match your environment #
$tenantVariableName = "" # Provide the name of the variable that contains the id of tenant that you want to discover from
$appVariableName = "" # Provide the name of the variable containen the client id of the app registration that you will use to authenticate with
$appSecretVariableName = "" # Provide the name of the variable containen the secret to the app registration that you will use to authenticate with
$serviceNowUserCredName = ""  # Provide the name of the credentials that you wish to use to authenticate to ServiceNow with
$ServiceNowImportSet = "" # Provide the name of the import set table in ServiceNow to push the data to

### Script ###
function getAzureAuthHeaders {
  $headers = @{
    'Content-Type' = "application/x-www-form-urlencoded"
  }
  $body = "grant_type=client_credentials&client_id=$app&client_secret=$secret&scope=https://management.azure.com/.default"
  $now = [int](Get-Date -UFormat %s -Millisecond 0)
  if($global:tokenExpires -lt $now + 60){
    $token = Invoke-RestMethod -Method "POST" -Uri "https://login.microsoftonline.com/$tentant/oauth2/v2.0/token" -Headers $headers -Body $body
    Set-Variable -Name 'token' -Value $token -Scope Global 
    Set-Variable -Name 'tokenExpires' -Value ($now  + $token.expires_in) -Scope Global
  } 
  $headers = @{
    'Authorization' = "$($global:token.token_type) $($global:token.access_token)"
    'Content-Type' = "application/json"
  }
  return $headers
}
try { 
  $metadata = @{
    startTime = Get-Date
    serviceNowInstance = $ServiceNowInstance
  }
  $global:tokenExpires = 0
  $global:token = $null
  $tentant = Get-AutomationVariable -Name $tenantVariableName
  $app = Get-AutomationVariable -Name $appVariableName
  $secretValue = Get-AutomationVariable -Name $appSecretVariableName
  $secret = [System.Web.HttpUtility]::UrlEncode($secretValue)
  $ServiceNowCredential = Get-AutomationPSCredential -Name $serviceNowUserCredName
  $ServiceNowURI = "https://$ServiceNowInstance.service-now.com/api/now/import/$ServiceNowImportSet"
  
  $ServiceNowAuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $ServiceNowCredential.UserName, $ServiceNowCredential.GetNetworkCredential().Password)))
  $ServiceNowHeaders = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
  $ServiceNowHeaders.Add('Authorization',('Basic {0}' -f $ServiceNowAuthInfo))
  $ServiceNowHeaders.Add('Accept','application/json')
  $ServiceNowHeaders.Add('Content-Type','application/json; charset=utf-8')

  $req = Invoke-RestMethod -Method "GET" -Uri "https://management.azure.com/subscriptions?api-version=2016-06-01" -Headers $(getAzureAuthHeaders)
  $subscriptions = @()
  $subscriptions += $req.value
  while ($null -ne $req.'@odata.nextLink') {
      $uri = $req.'@odata.nextLink' 
      $req = Invoke-RestMethod -Method Get -Uri $uri -Headers $(getAzureAuthHeaders) -Verbose
      $subscriptions += $req.value
  }
  $req = Invoke-RestMethod -Method "GET" -Uri "https://management.azure.com$($subscription.id)/providers?api-version=2018-05-01" -Headers $(getAzureAuthHeaders)
  $providers = @()
  $providers += $req.value
  while ($null -ne $req.'@odata.nextLink') {
      $uri = $req.'@odata.nextLink' 
      $req = Invoke-RestMethod -Method "GET" -Uri $uri -Headers $(getAzureAuthHeaders) -Verbose
      $providers += $req.value
  }
  
  foreach($subscription in $subscriptions) {
      $subscription = Invoke-RestMethod -Method "GET" -Uri "https://management.azure.com$($subscription.id)?api-version=2020-01-01" -Headers $(getAzureAuthHeaders)
      $body = @{}
      $body.Add("subscription_name", $subscription.displayName)
      $body.Add("subscription_id", $subscription.subscriptionId)
      $body.Add("resource_id", $subscription.id)
      $body.Add("name", $subscription.displayName)
      $body.Add("namespace", "Microsoft.Subscription")
      $body.Add("resource_type", "Microsoft.Subscription/subscriptions")
      $body.Add("sku", "")
      $body.Add("instance_view","")
      $body.Add("location","")
      if($subscription.tags -ne ""){
        $body.Add("tags", ($subscription.tags | ConvertTo-Json -Depth 2 -Compress))
      } else {
        $body.Add("tags", "")
      }
      $properties = @{}
      $properties.Add("state", $subscription.state)
      $properties.Add("subscriptionPolicies", $subscription.subscriptionPolicies)
      $properties.Add("authorizationSource", $subscription.authorizationSource)
      $properties.Add("managedByTenants", $subscription.managedByTenants)
      $body.Add("properties", ($properties | ConvertTo-Json -Depth 16 -Compress))
      $json = $body | ConvertTo-Json -Depth 2 -Compress
      $body = [System.Text.Encoding]::UTF8.GetBytes($json)
      $req = Invoke-RestMethod -Headers $ServiceNowHeaders -Method 'POST' -Uri $ServiceNowURI -Body $body
      
      $req = Invoke-RestMethod -Method "GET" -Uri "https://management.azure.com$($subscription.id)/providers/Microsoft.Compute/locations/eastus/vmSizes?api-version=2022-08-01" -Headers $(getAzureAuthHeaders)
      $vmSizes = @()
      $vmSizes += $req.value
      while($null -ne $req.'@odata.nextLink') {
          $uri = $req.'@odata.nextLink' 
          $req = Invoke-RestMethod -Method Get -Uri $uri -Headers $(getAzureAuthHeaders) -Verbose
          $vmSizes += $req.value
      }
    
      $req = Invoke-RestMethod -Method "GET" -Uri "https://management.azure.com$($subscription.id)/resourcegroups?api-version=2021-04-01" -Headers $(getAzureAuthHeaders)
      $resourceGroups = @()
      $resourceGroups += $req.value
      while ($null -ne $req.'@odata.nextLink') {
          $uri = $req.'@odata.nextLink' 
          $req = Invoke-RestMethod -Method Get -Uri $uri -Headers $(getAzureAuthHeaders) -Verbose
          $resourceGroups += $req.value
      }
      foreach($resourceGroup in $resourceGroups) {
          $resourceTypeArray = $resourceGroup.type.Split("/",2)
          $body = @{}
          $properties = $resourceGroup.properties | ConvertTo-Json -Depth 32 -Compress
          $body.Add("location", $resourceGroup.location)
          $body.Add("name", $resourceGroup.name)
          $body.Add("namespace", $resourceTypeArray[0])
          if($properties.Length -lt 4096) {
              $body.Add("properties", $properties) 
          } else {
              $body.Add("properties", "")
          }
          $body.Add("resource_group", $resourceGroup.name)
          $body.Add("resource_id", $resourceGroup.id)
          $body.Add("resource_type", $resourceGroup.type)
          $body.Add("subscription_id", $subscription.subscriptionId)
          $body.Add("subscription_name", $subscription.displayName)
          $body.Add("sku", "")
          if($resourceGroup.tags -ne ""){
              $body.Add("tags", ($resourceGroup.tags | ConvertTo-Json -Depth 2 -Compress))
          } else {
              $body.Add("tags", "")
          }
          $json = $body | ConvertTo-Json -Depth 2 -Compress
          $body = [System.Text.Encoding]::UTF8.GetBytes($json)
          $req = Invoke-RestMethod -Headers $ServiceNowHeaders -Method 'POST' -Uri $ServiceNowURI -Body $body
        
          $req = Invoke-RestMethod -Method "GET" -Uri "https://management.azure.com$($resourceGroup.id)/resources?api-version=2021-04-01" -Headers $(getAzureAuthHeaders)
          $resources = @()
          $resources += $req.value
          while ($null -ne $req.'@odata.nextLink') {
              $uri = $req.'@odata.nextLink' 
              $req = Invoke-RestMethod -Method Get -Uri $uri -Headers $(getAzureAuthHeaders) -Verbose
              $resources += $req.value
          }
          foreach($resource in $resources) {
              $resourceTypeArray = $resource.type.Split("/",2)
              if($providers.namespace -contains $resourceTypeArray[0]){
                  $provider = $providers | Where-Object -Property "namespace" -eq $resourceTypeArray[0]
                  $resourceType = $provider.resourceTypes | Where-Object -Property "resourceType" -eq $resourceTypeArray[1]
                  try {
                      $uri = "https://management.azure.com$($resource.id.replace(' ','%20'))?api-version=$($resourceType.apiVersions[0])"
                      $req = Invoke-RestMethod -Method "GET" -Uri $uri -Headers $(getAzureAuthHeaders)
                  } catch {
                    try {
                      $uri = "https://management.azure.com$($resource.id.replace(' ','%20'))?api-version=$($resourceType.apiVersions[1])"
                      $req = Invoke-RestMethod -Method "GET" -Uri $uri -Headers $(getAzureAuthHeaders)
                    } catch {
                      Write-Warning "Could not get data from URI $uri"
                      $req = @{}
                      $req.add("properties","")
                    }
                  }
                  $body = @{}
                  if($resource.type -eq "Microsoft.Compute/virtualMachines") {
                    $vmSize = $vmSizes | Where-Object "name" -eq $req.properties.hardwareProfile.vmSize
                    if($null -ne $vmSize){
                      $req.properties.hardwareProfile = $vmSize
                    }
                    $instanceURI = "https://management.azure.com$($resource.id.replace(' ','%20'))/instanceView?api-version=2022-08-01"
                    $instanceView = Invoke-RestMethod  -Method "GET" -Uri $instanceURI -Headers $(getAzureAuthHeaders)
                    $body.Add("instance_view", ($instanceView | ConvertTo-Json -Depth 32 -Compress))
                  }
                  $properties = $req.properties | ConvertTo-Json -Depth 32 -Compress
                  $body.Add("location", $resource.location)
                  $body.Add("name", $resource.name)
                  $body.Add("namespace", $resourceTypeArray[0])
                  if($properties.Length -lt 4096) {
                      $body.Add("properties", $properties) 
                  } else {
                      $body.Add("properties", "")
                  }
                  $body.Add("resource_group", $resourceGroup.name)
                  $body.Add("resource_id", $resource.id)
                  $body.Add("resource_type", $resource.type)
                  $body.Add("subscription_id", $subscription.subscriptionId)
                  $body.Add("subscription_name", $subscription.displayName)
                  if($resource.sku -ne "") {
                      $body.Add("sku", ($resource.sku | ConvertTo-Json -Depth 2 -Compress))
                  } else {
                      $body.Add("sku", "")
                  }
                  if($resource.tags -ne ""){
                      $body.Add("tags", ($resource.tags | ConvertTo-Json -Depth 2 -Compress))
                  } else {
                      $body.Add("tags", "")
                  }
                  $json = $body | ConvertTo-Json -Depth 2 -Compress
                  $body = [System.Text.Encoding]::UTF8.GetBytes($json)
                  $req = Invoke-RestMethod -Headers $ServiceNowHeaders -Method 'POST' -Uri $ServiceNowURI -Body $body
              }
          }
      }
  }#>
} catch {
  Write-Error ("Exception caught at line $($_.InvocationInfo.ScriptLineNumber), $($_.Exception.Message)")
  throw
} finally {
  Write-Verbose "Runbook has completed. Total runtime $((([DateTime]::Now) - $($metadata.startTime)).TotalSeconds) Seconds"
  Write-Output $metadata | ConvertTo-Json
}