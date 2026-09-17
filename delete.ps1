# ============================================================
# Azure Databricks Lab Cleanup
#
# Finds the student's msl-######## resource group and removes:
#
#   1. Databricks workspace(s)
#   2. Databricks-managed resource group(s)
#   3. The student's msl-######## resource group
#
# Databricks workspaces are deleted sequentially.
# The script waits for each deletion to complete.
#
# No confirmation is required.
# ============================================================

$ErrorActionPreference = "Continue"

Write-Host ""
Write-Host "============================================"
Write-Host " Azure Databricks Lab Cleanup"
Write-Host "============================================"
Write-Host ""


# ------------------------------------------------------------
# Find the student's lab resource group
# ------------------------------------------------------------

Write-Host "Searching for the lab resource group..."

$studentRGs = az group list `
    --query "[?starts_with(name, 'msl-')].name" `
    -o tsv

if (-not $studentRGs) {
    Write-Host "ERROR: No resource group beginning with 'msl-' was found."
    exit 1
}

$studentRGList = @(
    $studentRGs -split "`r?`n" |
    Where-Object { $_ }
)

# Only accept the expected msl-######## format.
$validRGs = @(
    $studentRGList | Where-Object {
        $_ -match '^msl-[A-Za-z0-9]{8}$'
    }
)

if ($validRGs.Count -eq 0) {
    Write-Host "ERROR: No resource group matching msl-######## was found."
    exit 1
}

# Don't risk deleting the wrong lab if multiple matches exist.
if ($validRGs.Count -gt 1) {
    Write-Host "ERROR: Multiple matching lab resource groups were found:"
    $validRGs | ForEach-Object {
        Write-Host "  $_"
    }
    Write-Host ""
    Write-Host "Cleanup stopped to avoid deleting the wrong lab."
    exit 1
}

$studentRG = $validRGs[0]

Write-Host "Found lab resource group:"
Write-Host "  $studentRG"
Write-Host ""


# ------------------------------------------------------------
# Find Databricks workspaces
# ------------------------------------------------------------

Write-Host "Searching for Azure Databricks workspaces..."

$workspaceNames = az databricks workspace list `
    --resource-group $studentRG `
    --query "[].name" `
    -o tsv 2>$null

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Unable to query Databricks workspaces."
    exit 1
}

$workspaces = @(
    $workspaceNames -split "`r?`n" |
    Where-Object { $_ }
)

# ------------------------------------------------------------
# Track only the managed RGs associated with these workspaces
# ------------------------------------------------------------

$managedRGsToTrack = @()

foreach ($workspace in $workspaces) {

    $managedResourceGroupId = az databricks workspace show `
        --resource-group $studentRG `
        --name $workspace `
        --query "managedResourceGroupId" `
        -o tsv 2>$null

    if ($managedResourceGroupId) {

        $managedRGName = Split-Path $managedResourceGroupId.Trim() -Leaf

        if ($managedRGName -and ($managedRGsToTrack -notcontains $managedRGName)) {
            $managedRGsToTrack += $managedRGName
        }
    }
}


# ------------------------------------------------------------
# Delete Databricks workspaces ONE AT A TIME
# ------------------------------------------------------------

if ($workspaces.Count -eq 0) {

    Write-Host "No Databricks workspaces were found."
    Write-Host ""

}
else {

    Write-Host "Found $($workspaces.Count) Databricks workspace(s):"

    $workspaces | ForEach-Object {
        Write-Host "  $_"
    }

    Write-Host ""

    foreach ($workspace in $workspaces) {

        Write-Host "--------------------------------------------"
        Write-Host "Deleting Databricks workspace:"
        Write-Host "  $workspace"
        Write-Host "--------------------------------------------"

        az databricks workspace delete `
            --resource-group $studentRG `
            --name $workspace `
            --force-deletion true `
            --yes

        if ($LASTEXITCODE -ne 0) {
            Write-Host ""
            Write-Host "ERROR: Failed to start deletion of:"
            Write-Host "  $workspace"
            Write-Host ""
            Write-Host "Cleanup stopped."
            exit 1
        }

        Write-Host ""
        Write-Host "Deletion submitted."
        Write-Host "Waiting for workspace to disappear..."

        # ----------------------------------------------------
        # Wait for workspace deletion
        # ----------------------------------------------------

        $timeoutSeconds = 1800
        $elapsed = 0
        $deleted = $false

        while ($elapsed -lt $timeoutSeconds) {

            Start-Sleep -Seconds 15
            $elapsed += 15

            az databricks workspace show `
                --resource-group $studentRG `
                --name $workspace `
                -o none 2>$null

            if ($LASTEXITCODE -ne 0) {
                $deleted = $true
                break
            }

            Write-Host "  Still deleting... ($elapsed seconds)"
        }

        if (-not $deleted) {
            Write-Host ""
            Write-Host "ERROR: Workspace did not disappear within"
            Write-Host "$timeoutSeconds seconds:"
            Write-Host "  $workspace"
            Write-Host ""
            Write-Host "Cleanup stopped."
            exit 1
        }

        Write-Host ""
        Write-Host "Workspace deleted:"
        Write-Host "  $workspace"
        Write-Host ""
    }
}


# ------------------------------------------------------------
# Allow Databricks time to clean up its managed RG
# ------------------------------------------------------------

Write-Host "Allowing Azure Databricks time to clean up"
Write-Host "its managed resource group..."

Start-Sleep -Seconds 30


# ------------------------------------------------------------
# Wait only for this workspace's managed resource groups
# ------------------------------------------------------------

Write-Host ""
Write-Host "Checking for Databricks-managed resource groups..."

if ($managedRGsToTrack.Count -gt 0) {

    Write-Host ""
    Write-Host "Tracking managed resource group(s):"

    $managedRGsToTrack | ForEach-Object {
        Write-Host "  $_"
    }

    Write-Host ""
    Write-Host "Waiting for Databricks to remove them..."

    $timeoutSeconds = 1800
    $elapsed = 0

    while ($elapsed -lt $timeoutSeconds) {

        Start-Sleep -Seconds 20
        $elapsed += 20

        $remainingManagedRGs = @()

        foreach ($managedRG in $managedRGsToTrack) {

            $exists = az group exists `
                --name $managedRG

            if ($exists -eq "true") {
                $remainingManagedRGs += $managedRG
            }
        }

        if ($remainingManagedRGs.Count -eq 0) {
            break
        }

        Write-Host "  Managed resource group(s) still present... ($elapsed seconds)"
    }

    if ($remainingManagedRGs.Count -gt 0) {

        Write-Host ""
        Write-Host "ERROR: Databricks-managed resource group(s)"
        Write-Host "did not disappear within the timeout period:"

        $remainingManagedRGs | ForEach-Object {
            Write-Host "  $_"
        }

        Write-Host ""
        Write-Host "The student's resource group will NOT be deleted."
        Write-Host "Cleanup stopped."
        exit 1
    }
}

Write-Host "No tracked Databricks-managed resource groups remain."
Write-Host ""


# ------------------------------------------------------------
# Delete the student's resource group
# ------------------------------------------------------------

Write-Host "Deleting student resource group:"
Write-Host "  $studentRG"
Write-Host ""

az group delete `
    --name $studentRG `
    --yes `
    --no-wait

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Failed to start resource group deletion."
    exit 1
}


# ------------------------------------------------------------
# Wait for student's RG to disappear
# ------------------------------------------------------------

Write-Host "Resource group deletion submitted."
Write-Host "Waiting for deletion to complete..."

$timeoutSeconds = 1800
$elapsed = 0
$deleted = $false

while ($elapsed -lt $timeoutSeconds) {

    Start-Sleep -Seconds 20
    $elapsed += 20

    $exists = az group exists `
        --name $studentRG

    if ($exists -ne "true") {
        $deleted = $true
        break
    }

    Write-Host "  Resource group still exists... ($elapsed seconds)"
}


# ------------------------------------------------------------
# Final result
# ------------------------------------------------------------

if (-not $deleted) {

    Write-Host ""
    Write-Host "ERROR: Resource group still exists after"
    Write-Host "$timeoutSeconds seconds:"
    Write-Host "  $studentRG"
    Write-Host ""
    Write-Host "Cleanup may still be in progress."
    exit 1
}


Write-Host ""
Write-Host "============================================"
Write-Host " Cleanup Complete"
Write-Host "============================================"
Write-Host ""

Write-Host "Student resource group:"
Write-Host "  $studentRG"
Write-Host "  DELETED"

Write-Host ""
Write-Host "Databricks-managed resource groups:"
Write-Host "  NONE DETECTED"

Write-Host ""
Write-Host "Azure Databricks lab cleanup completed successfully."
Write-Host ""
