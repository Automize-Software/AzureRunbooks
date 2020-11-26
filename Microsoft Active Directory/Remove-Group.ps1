param (
  [Parameter(Mandatory=$true)]
	[string] $samAccountName
)

# * Environment variabels * #
# Set the below to match your environment #
$domainController = "" #IP or FQDN of Domain Controller
$credentialsName = "" #Name of stored credentials to use for authentication with Domain Controller

### Script ###
try {
  $metadata = @{
    startTime = Get-Date
    samAccountName = $samAccountName
  }
  
  Write-Verbose "Runbook started - $($metadata.startTime)"

  $credentials = Get-AutomationPSCredential -Name $credentialsName
  
  Remove-ADGroup -Credential $credentials -Identity $samAccountName -Server $domainController -Confirm $false

} catch {
  Write-Error ("Exception caught at line $($_.InvocationInfo.ScriptLineNumber), $($_.Exception.Message)")
  throw
} finally {
  Write-Verbose "Runbook has completed. Total runtime $((([DateTime]::Now) - $($metadata.startTime)).TotalSeconds) Seconds"
  Write-Output $metadata | ConvertTo-Json
}