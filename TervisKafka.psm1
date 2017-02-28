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
    #$Sessions = New-PSSession -ComputerName $KafakVMVMNetworkAdapters.vmname

    $KafkaBrokerOU = Get-ADOrganizationalUnit -Filter {Name -eq "KafkaBroker"}
    $ADDomain = Get-ADDomain
    $DomainJoinCredential = Get-PasswordstateCredential -PasswordID 2643

    $TervisKafkaModulePath = (Get-Module -ListAvailable TervisKafka).ModuleBase

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

        $NodeNumber = $KafakVMVMNetworkAdapters.IndexOf($VMVMNetworkAdapter) + 1
        ${broker.id} = $NodeNumber
        ${log.dirs} = "C:/tmp/kafka-logs"
        $KafkaHome = Get-ChildItem -Directory  "\\$($VMVMNetworkAdapter.VMName)\C$\ProgramData\chocolatey\lib\kafka\tools\"

        "$TervisKafkaModulePath\server.properties.pstemplate" | Invoke-ProcessTemplateFile |
        Out-File -Encoding utf8 -NoNewline "$($KafkaHome.FullName)\config\server.properties"

        $ZookeeperNodeNames = $KafakVMVMNetworkAdapters.vmname
        $dataDir = "C:/tmp/zookeeper"

        "$TervisKafkaModulePath\zookeeper.properties.pstemplate" | Invoke-ProcessTemplateFile |
        Out-File -Encoding ascii -NoNewline "$($KafkaHome.FullName)\config\zookeeper.properties"

        $ZookeeperDataDirOnNode = "\\$($VMVMNetworkAdapter.VMName)\$($dataDir -replace ":","$")"
        New-Item -ItemType Directory $ZookeeperDataDirOnNode -Force

        $NodeNumber | Out-File -Force "\\$($VMVMNetworkAdapter.VMName)\$($dataDir -replace ":","$")\myid" -Encoding ascii -NoNewline
    }    
}

function New-KafkaBrokerGPO {
    $KafkaBrokerFirewallGPO = Get-GPO -Name "KafkaBrokerFirewall"
    if (-not $KafkaBrokerFirewallGPO) {    
        $KafkaBrokerFirewallGPO = New-GPO -Name "KafkaBrokerFirewall"
    }
    
    $KafkaBrokerOU = Get-ADOrganizationalUnit -Filter {Name -eq "KafkaBroker"}
    $KafkaBrokerFirewallGPO | New-GPLink -Target $KafkaBrokerOU
    $ADDomain = Get-ADDomain
    $GPOSession = Open-NetGPO –PolicyStore "$($ADDomain.DNSRoot)\KafkaBrokerFirewall"
    New-NetFirewallRule -GPOSession $GPOSession -Name Kafka-Zookeeper -DisplayName Kafka-Zookeeper -Direction Inbound -LocalPort 2181,2888,3888 -Protocol TCP -Action Allow -Group Kafka
    New-NetFirewallRule -GPOSession $GPOSession -Name Kafka-Broker -DisplayName Kafka-Broker -Direction Inbound -LocalPort 9092 -Protocol TCP -Action Allow -Group Kafka
    Save-NetGPO -GPOSession $GPOSession

    Remove-NetFirewallRule -GPOSession $GPOSession -Name zookeeper
    Save-NetGPO -GPOSession $GPOSession
    $KafakVMVMNetworkAdapters.vmname | % { Invoke-GPUpdate -Computer $_ -RandomDelayInMinutes 0}
}

function Get-KafkaZookeeperMyId {
    $Sessions = New-PSSession -ComputerName $KafakVMVMNetworkAdapters.vmname
    Invoke-Command -Session $Sessions -ScriptBlock {hostname;get-content "C:\tmp\zookeeper\myid"}
}

function Start-KafkaZookeeper {
    $Sessions = New-PSSession -ComputerName $KafakVMVMNetworkAdapters.vmname
    Invoke-Command -Session $Sessions -ScriptBlock {Start-Service kafka-zookeeper-service}
}

function Stop-KafkaZookeeper {
    $Sessions = New-PSSession -ComputerName $KafakVMVMNetworkAdapters.vmname
    Invoke-Command -Session $Sessions -ScriptBlock {Stop-Service kafka-zookeeper-service}
}

function Start-Kafka {
    $Sessions = New-PSSession -ComputerName $KafakVMVMNetworkAdapters.vmname
    Invoke-Command -Session $Sessions -ScriptBlock {Start-Service kafka-service}
}

function Stop-Kafka {
    $Sessions = New-PSSession -ComputerName $KafakVMVMNetworkAdapters.vmname
    Invoke-Command -Session $Sessions -ScriptBlock {Stop-Service kafka-service}
}

function Get-KafkaTopics {
    start-process "$($KafkaHome.FullName)\bin\windows\kafka-topics.bat" "--zookeeper $($KafakVMVMNetworkAdapters.vmname[0]):2181"
}

function Get-KafkaZookeeperService {
    Invoke-Command -Session $Sessions -ScriptBlock {get-service | where name -match zoo}
}

function Get-KafkaZookeeperStatus {    
    $KafakVMVMNetworkAdapters.vmname | % {$_; Send-NetworkData -Computer $_ -Port 2181 -Data "srvr" -ErrorAction SilentlyContinue}
    $KafakVMVMNetworkAdapters.vmname | % {$_; Send-NetworkData -Computer $_ -Port 2181 -Data "mntr" -ErrorAction SilentlyContinue}
    $KafakVMVMNetworkAdapters.vmname | % {$_; Send-NetworkData -Computer $_ -Port 2181 -Data "isro" -ErrorAction SilentlyContinue}
}

function Edit-KafkaServerProperties {
    param (
        $ComputerName
    )
    $KafkaHome = Get-ChildItem -Directory  "\\$ComputerName\C$\ProgramData\chocolatey\lib\kafka\tools\"
    Start-Process notepad++ "$($KafkaHome.FullName)\config\server.properties"
}

function Edit-KafkaZookeeperServerProperties {
    param (
        $ComputerName
    )
    $KafkaHome = Get-ChildItem -Directory  "\\$ComputerName\C$\ProgramData\chocolatey\lib\kafka\tools\"
    Start-Process notepad++ "$($KafkaHome.FullName)\config\server.properties"
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