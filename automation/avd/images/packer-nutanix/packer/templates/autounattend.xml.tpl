<?xml version="1.0" encoding="utf-8"?>
<!-- Build-only answer file (reference template, not run in the lab). The local build account uses PlainText because unattended
     Setup needs the supplied password; the account exists only in the build VM and sysprep /generalize removes it before the
     image is distributed. The file is rendered into a CD that Packer attaches to the build VM: isolate the build network,
     do not retain or publish that media. No identity and no product key literal: ${product_key} may be empty.
     The windowsPE driver paths load the VirtIO storage (viostor, vioscsi) and network (NetKVM) drivers from the VirtIO ISO; Setup
     ignores a path that does not exist, so several candidate drive letters are listed. Confirm the letters on the first run. -->
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-PnpCustomizationsWinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DriverPaths>
        <PathAndCredentials wcm:action="add" wcm:keyValue="1"><Path>D:\viostor\w11\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="2"><Path>D:\NetKVM\w11\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="3"><Path>D:\vioscsi\w11\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="4"><Path>E:\viostor\w11\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="5"><Path>E:\NetKVM\w11\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="6"><Path>E:\vioscsi\w11\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="7"><Path>F:\viostor\w11\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="8"><Path>F:\NetKVM\w11\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="9"><Path>F:\vioscsi\w11\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="10"><Path>G:\viostor\w11\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="11"><Path>G:\NetKVM\w11\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="12"><Path>G:\vioscsi\w11\amd64</Path></PathAndCredentials>
      </DriverPaths>
    </component>
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage>
        <UILanguage>en-US</UILanguage>
      </SetupUILanguage>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>100</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label></ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>Windows 11 Enterprise</Value></MetaData>
          </InstallFrom>
          <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
          <WillShowUI>OnError</WillShowUI>
        </OSImage>
      </ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
%{ if product_key != "" ~}
        <ProductKey><Key>${product_key}</Key></ProductKey>
%{ endif ~}
      </UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>*</ComputerName>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>${build_username}</Name>
            <Group>Administrators</Group>
            <Password><Value>${build_password}</Value><PlainText>true</PlainText></Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <LogonCount>2</LogonCount>
        <Username>${build_username}</Username>
        <Password><Value>${build_password}</Value><PlainText>true</PlainText></Password>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add"><Order>1</Order><CommandLine>cmd /c winrm quickconfig -q</CommandLine></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>2</Order><CommandLine>cmd /c winrm set winrm/config/service @{AllowUnencrypted="true"}</CommandLine></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>3</Order><CommandLine>cmd /c winrm set winrm/config/service/auth @{Basic="true"}</CommandLine></SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
