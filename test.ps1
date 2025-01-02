RunElevated({
try {
    # Attempt to remove the directory and its contents
    Remove-Item "C:\Program Files\BackInfo\" -Recurse -Force
    Write-Host "The BackInfo directory was removed successfully from C:\Program Files\." -ForegroundColor Green
} catch {
    try {
        # Attempt to remove the directory and its contents
        Remove-Item "c:\Program Files (x86)\BackInfo\" -Recurse -Force
        Write-Host "The BackInfo directory was removed successfully from C:\Program Files (x86)\." -ForegroundColor Green
    } catch {
        # Handle any errors that occur
        Write-Host "An error occurred while trying to remove the directory:" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Yellow
    }
}

try {
    # Attempt to remove the directory and its contents
    Remove-Item "$env:TEMP\backinfo.bmp" -Recurse -Force
    Write-Host "The directory was removed successfully." -ForegroundColor Green
} catch {
    # Handle any errors that occur
    Write-Host "An error occurred while trying to remove the directory:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
}

Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name WallPaper -Value ''
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers" -Name BackgroundType -Type DWORD -Value 1
Set-ItemProperty -Path "HKCU:\Control Panel\Colors" -Name Background -Value "0 0 0"

# Specify the username and password for the target user
$username = $env:USERNAME
$securePassword = ConvertTo-SecureString "Pa55w.rd" -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential($username, $securePassword)

# Get explorer processes for the specific user
$userExplorer = Get-WmiObject -Class Win32_Process | Where-Object { $_.Name -eq "explorer.exe" -and $_.GetOwner().User -eq $username }

# Restart explorer for the user
foreach ($process in $userExplorer) {
    Stop-Process -Id $process.ProcessId -Force
    Start-Process -FilePath "C:\Windows\explorer.exe" -Credential $cred
}

Write-Host "Explorer has been restarted for user $username." -ForegroundColor Green

})
