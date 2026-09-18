# ============================================================
# Azure Databricks Lab Cleanup
#
# Uses the student's fixed resource groups:
#
#   Student resource group:
#       ResourceGroup1
#
#   Databricks-managed resource group:
#       DatabricksRG
#
# Removes:
#
#   1. Databricks workspace(s) in ResourceGroup1
#   2. Databricks-managed resource group DatabricksRG
#   3. Student resource group ResourceGroup1
#
# Databricks workspaces are deleted sequentially.
# The script waits for each deletion to complete.
#
# The Azure CLI Databricks extension is installed automatically
# if it is not already installed.
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
# Fixed resource group names
# ------------------------------------------------------------

$studentRG = "ResourceGroup1"
$managedRG = "DatabricksRG"


# ------------------------------------------------------------
# Ensure Azure CLI Databricks extension is installed
# ------------------------------------------------------------

Write-Host "Checking for Azure CLI Databricks extension..."

az extension show `
    --name databricks `
    --only-show-errors 2>$null

if ($LASTEXITCODE -ne 0) {

    Write-Host "Databricks extension not found."
    Write-Host "Installing Azure CLI Databricks extension..."
    Write-Host ""

    az extension add `
        --name databricks `
        --yes `
        --only-show-errors

    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "ERROR: Failed to install the Azure CLI Databricks extension."
        exit 1
    }

    Write-Host "Databricks extension installed."
    Write-Host ""

}
else {

    Write-Host "Databricks extension is already installed."
    Write-Host ""
}


# ------------------------------------------------------------
# Verify the student's resource group exists
# ------------------------------------------------------------

Write-Host "Checking for student resource group:"
Write-Host "  $studentRG"
Write-Host ""

az group show `
    --name $studentRG `
    --query "name" `
    -o tsv `
    --only-show-errors 2>$null

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Resource group '$studentRG' was not found."
    exit 1
}

Write-Host "Found student resource group:"
Write-Host "  $studentRG"
Write-Host ""


# ------------------------------------------------------------
# Find Databricks workspaces
#
# Use Azure Resource Manager directly rather than
# 'az databricks workspace list'.
#
# This avoids depending on the Databricks CLI extension
# for workspace discovery.
# ------------------------------------------------------------

Write-Host "Searching for Azure Databricks workspaces..."

$workspaceNames = az resource list `
    --resource-group $studentRG `
    --resource-type "Microsoft.Databricks/workspaces" `
    --query "[].name" `
    -o tsv `
    --only-show-errors 2>$null

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "ERROR: Unable to query resources in '$studentRG'."
    exit 1
}

$workspaces = @(
    $workspaceNames -split "`r?`n" |
    Where-Object { $_ }
)

Write-Host ""


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
            --yes `
            --only-show-errors

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
                -o none `
                --only-show-errors 2>$null

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
# Wait specifically for DatabricksRG to disappear
# ------------------------------------------------------------

Write-Host ""
Write-Host "Checking for Databricks-managed resource group:"
Write-Host "  $managedRG"
Write-Host ""

$managedRGExists = az group exists `
    --name $managedRG `
    --only-show-errors

if ($managedRGExists -eq "true") {

    Write-Host "Databricks-managed resource group still exists:"
    Write-Host "  $managedRG"
    Write-Host ""
    Write-Host "Waiting for Databricks to remove it..."

    $timeoutSeconds = 1800
    $elapsed = 0
    $managedRGDeleted = $false

    while ($elapsed -lt $timeoutSeconds) {

        Start-Sleep -Seconds 20
        $elapsed += 20

        $managedRGExists = az group exists `
            --name $managedRG `
            --only-show-errors

        if ($managedRGExists -ne "true") {
            $managedRGDeleted = $true
            break
        }

        Write-Host "  Managed resource group still present... ($elapsed seconds)"
    }

    if (-not $managedRGDeleted) {

        Write-Host ""
        Write-Host "ERROR: Databricks-managed resource group"
        Write-Host "did not disappear within the timeout period:"
        Write-Host "  $managedRG"
        Write-Host ""
        Write-Host "The student's resource group will NOT be deleted."
        Write-Host "Cleanup stopped."
        exit 1
    }

}
else {

    Write-Host "Databricks-managed resource group is already gone:"
    Write-Host "  $managedRG"
    Write-Host ""
}


Write-Host "Databricks-managed resource group is no longer present."
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
    --no-wait `
    --only-show-errors

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
        --name $studentRG `
        --only-show-errors

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
Write-Host "Databricks-managed resource group:"
Write-Host "  $managedRG"
Write-Host "  DELETED"

Write-Host ""
Write-Host "Azure Databricks lab cleanup completed successfully."
Write-Host ""
