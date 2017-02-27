#Requires -version 5.0
#Requires -modules PasswordstatePowershell, TervisChocolatey, TervisNetTCPIP
#Requires -RunAsAdministrator

function Get-KafkaVM {
    Invoke-Command -ComputerName hypervc5n2 -ScriptBlock { 
        get-vm  | 
        where name -match kafka | 
        foreach {
            $_ | Add-Member -Name VMNetworkAdapter -MemberType NoteProperty -PassThru -Value $( 
                $_ | Get-VMNetworkAdapter
            )
        }
    }
}

function Get-KafakVMVMNetworkAdapter {
    Invoke-Command -ComputerName hypervc5n2 -ScriptBlock { get-vm  | where name -match kafka | Get-VMNetworkAdapter}
}

function Invoke-KafkaBrokerProvision {
    $Credential = Get-PasswordstateCredential -PasswordID 4084
    $KafakVMVMNetworkAdapters = Get-KafakVMVMNetworkAdapter
    
    $KafkaBrokerIPAddresses = $KafakVMVMNetworkAdapters.ipaddresses |
    where { $_ -NotMatch ":" } 
    
    $KafkaBrokerIPAddresses | Add-IPAddressToWSManTrustedHosts
    
    #Needs to be run on the remote systems for remoting to work
    #Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private
    
    #$Sessions = New-PSSession -ComputerName $KafkaBrokerIPAddresses -Credential $Credential

    $KafkaBrokerOU = Get-ADOrganizationalUnit -Filter {Name -eq "KafkaBroker"}
    $ADDomain = Get-ADDomain
    $DomainJoinCredential = Get-PasswordstateCredential -PasswordID 2643

    foreach ($VMVMNetworkAdapter in $KafakVMVMNetworkAdapters) {
        $VMIPv4Address = $VMVMNetworkAdapter.IPAddresses[0]
        $CurrentHostname = Get-ComputerNameOnOrOffDomain -IPAddress $VMIPv4Address -Credential $Credential -ComputerName $VMVMNetworkAdapter.VMName

        if ($CurrentHostname -ne $VMVMNetworkAdapter.VMName) {
            Rename-Computer -NewName $VMVMNetworkAdapter.VMName -Force -Restart -LocalCredential $Credential -ComputerName $VMIPv4Address
            Wait-ForEndpointRestart -IPAddress $VMIPv4Address -PortNumbertoMonitor 5985
            $HostnameAfterRestart = Get-ComputerNameOnOrOffDomain -IPAddress $VMIPv4Address -Credential $Credential -ComputerName $VMVMNetworkAdapter.VMName
            if ($HostnameAfterRestart -ne $VMVMNetworkAdapter.VMName) {
                Throw "Rename of VM $($VMVMNetworkAdapter.VMName) with ip address $($VMVMNetworkAdapter.IPAddresses[0]) failed"
            }
        }

        $CurrentDomainName = Get-DomainNameOnOrOffDomain -ComputerName $VMVMNetworkAdapter.VMName -IPAddress $VMIPv4Address -Credential $Credential
        if ($CurrentDomainName -ne $ADDomain.Name) {
            Add-Computer -DomainName $ADDomain.forest -Force -Restart -OUPath $KafkaBrokerOU.DistinguishedName -ComputerName $VMIPv4Address -LocalCredential $Credential -Credential $DomainJoinCredential
            
            Wait-ForEndpointRestart -IPAddress $VMIPv4Address -PortNumbertoMonitor 5985
            $DomainNameAfterRestart = Get-DomainNameOnOrOffDomain -ComputerName $VMVMNetworkAdapter.VMName -IPAddress $VMIPv4Address -Credential $Credential
            if ($DomainNameAfterRestart -ne $ADDomain.forest) {
                Throw "Joining the domain for VM $($VMVMNetworkAdapter.VMName) with ip address $($VMVMNetworkAdapter.IPAddresses[0]) failed"
            }
        }

        Install-TervisChocolatey -ComputerName $VMVMNetworkAdapter.VMName
        Install-TervisChocolateyPackages -ChocolateyPackageGroupNames KafkaBroker -ComputerName $VMVMNetworkAdapter.VMName
    }

}


function Get-ComputerNameOnOrOffDomain {
    [CmdletBinding()]
    param (
        $ComputerName,
        $IPAddress,
        $Credential = [System.Management.Automation.PSCredential]::Empty
    )

    try {
        Get-ComputerName -ComputerName $VMIPv4Address -Credential $Credential -ErrorAction Stop
    } catch {
        Get-ComputerName -ComputerName $VMVMNetworkAdapter.VMName
    }
}

function Get-DomainNameOnOrOffDomain {
    [CmdletBinding()]
    param (
        $ComputerName,
        $IPAddress,
        $Credential = [System.Management.Automation.PSCredential]::Empty
    )

    try {
        Get-DomainName -ComputerName $VMIPv4Address -Credential $Credential -ErrorAction Stop
    } catch {
        Get-DomainName -ComputerName $VMVMNetworkAdapter.VMName
    }
}

function Get-ComputerName {
    [CmdletBinding()]
    param (
        $ComputerName,
        $Credential = [System.Management.Automation.PSCredential]::Empty
    )
    Invoke-Command -Credential $Credential -ComputerName $ComputerName -ScriptBlock {         
            $env:COMPUTERNAME
    }
}

function Get-DomainName {
    [CmdletBinding()]
    param (
        $ComputerName,
        $Credential = [System.Management.Automation.PSCredential]::Empty
    )
    Invoke-Command -Credential $Credential -ComputerName $ComputerName -ScriptBlock {         
        $env:USERDOMAIN
    }
}


function Get-TervisKafkaBrocker {
    param (
        $Environment
    )

    Get-ADComputer -filter {Name -like "*Kafka*"}

}

function Invoke-DeployTervisKafka {
    param (

    )

}