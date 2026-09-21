# ============================================================
# Azure Databricks Lab Cleanup
#
# Purpose:
#   Clean up Databricks resources created by the current student
#   during the current lab session.
#
# Safety:
#   - Uses the current signed-in user's identity.
#   - Looks back only 4 hours in the Azure Activity Log.
#   - Only processes Databricks workspaces associated with
#     successful operations by that user.
#   - Does NOT blindly delete subscription-wide Databricks
#     resources or resource groups.
#   - Resource groups are deleted only when empty.
#   - No confirmation prompts.
#
# Implementation:
#   Uses Azure Resource Manager directly.
#   Does NOT require the Azure CLI Databricks extension.
#
# Intended for:
#   Azure Cloud Shell - PowerShell
# ============================================================

$ErrorActionPreference = "Continue"

# ------------------------------------------------------------
# Settings
# ------------------------------------------------------------

$activityLogHours = 4
$workspaceDeleteTimeoutSeconds = 1800
$managedRGTimeoutSeconds = 1800
$resourceGroupDeleteTimeoutSeconds = 1800

# Current Databricks ARM API version.
$databricksApiVersion = "2026-01-01"

Write-Host ""
Write-Host "============================================================"
Write-Host " Azure Databricks Lab Cleanup"
Write-Host "============================================================"
Write-Host ""

# ------------------------------------------------------------
# 1. Determine the current Azure user
# ------------------------------------------------------------

Write-Host "Determining current Azure user..."

$caller = az account show `
    --query user.name `
    -o tsv `
    --only-show-errors `
    2>$null

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($caller)) {
    Write-Host "ERROR: Unable to determine the current Azure user."
    exit 1
}

Write-Host "Current user: $caller"
Write-Host "Activity Log lookback: $activityLogHours hours"
Write-Host ""

# ------------------------------------------------------------
# 2. Retrieve recent Activity Log entries for this user
# ------------------------------------------------------------

Write-Host "Checking Azure Activity Log for Databricks workspace operations..."

$activityLogJson = az monitor activity-log list `
    --caller $caller `
    --offset "${activityLogHours}h" `
    --max-events 1000 `
    --only-show-errors `
    -o json 2>$null

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($activityLogJson)) {
    Write-Host "ERROR: Unable to retrieve the Azure Activity Log."
    exit 1
}

try {
    $activityEvents = $activityLogJson | ConvertFrom-Json
}
catch {
    Write-Host "ERROR: Unable to parse Azure Activity Log results."
    exit 1
}

# ------------------------------------------------------------
# 3. Find successful Databricks workspace write operations
#
#    Microsoft.Databricks/workspaces/write covers creation and
#    modification of a workspace.
#
#    In this lab environment, the combination of:
#
#       - current student's identity
#       - recent 4-hour window
#       - Databricks workspace resource
#
#    identifies the lab workspace(s).
# ------------------------------------------------------------

$workspaceIds = @()

foreach ($event in $activityEvents) {

    $operationName = [string]$event.operationName.value
    $resourceId    = [string]$event.resourceId
    $status        = [string]$event.status.value

    if (
        $operationName -eq "Microsoft.Databricks/workspaces/write" -and
        $status -eq "Succeeded" -and
        $resourceId -match "/providers/Microsoft\.Databricks/workspaces/[^/]+$"
    ) {
        $workspaceIds += $resourceId
    }
}

$workspaceIds = $workspaceIds |
    Sort-Object -Unique

if ($workspaceIds.Count -eq 0) {
    Write-Host "No Databricks workspaces created or modified by $caller"
    Write-Host "within the last $activityLogHours hours."
    Write-Host ""
    Write-Host "Nothing to clean up."
    exit 0
}

Write-Host "Found $($workspaceIds.Count) Databricks workspace candidate(s)."
Write-Host ""

# ------------------------------------------------------------
# Arrays used to track cleanup
# ------------------------------------------------------------

$workspaceRecords = @()
$managedResourceGroups = @()
$containingResourceGroups = @()

# ------------------------------------------------------------
# 4. Resolve each workspace and its resource groups
#
#    "az resource show" is a normal Azure CLI command and does
#    not require the Databricks extension.
#
#    The ARM resource contains:
#
#       properties.managedResourceGroupId
# ------------------------------------------------------------

foreach ($workspaceId in $workspaceIds) {

    Write-Host "Inspecting workspace:"
    Write-Host "  $workspaceId"

    $workspaceJson = az resource show `
        --ids $workspaceId `
        --only-show-errors `
        -o json 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($workspaceJson)) {
        Write-Host "  Workspace no longer exists. Skipping."
        Write-Host ""
        continue
    }

    try {
        $workspaceResource = $workspaceJson | ConvertFrom-Json
    }
    catch {
        Write-Host "  ERROR: Unable to parse workspace information."
        exit 1
    }

    # Make sure this really is a Databricks workspace.
    if ($workspaceResource.type -ne "Microsoft.Databricks/workspaces") {
        Write-Host "  Resource type is not a Databricks workspace. Skipping."
        Write-Host ""
        continue
    }

    $workspaceName = $workspaceResource.name
    $resourceGroup = $workspaceResource.resourceGroup
    $location      = $workspaceResource.location

    if ([string]::IsNullOrWhiteSpace($resourceGroup)) {
        Write-Host "  ERROR: Unable to determine containing resource group."
        exit 1
    }

    Write-Host "  Workspace:       $workspaceName"
    Write-Host "  Resource group:  $resourceGroup"
    Write-Host "  Location:        $location"

    # --------------------------------------------------------
    # Get managed RG directly from ARM resource properties.
    # --------------------------------------------------------

    $managedRG = $null
    $managedRGName = $null

    if ($workspaceResource.properties) {
        $managedRG = [string]$workspaceResource.properties.managedResourceGroupId
    }

    if ([string]::IsNullOrWhiteSpace($managedRG)) {

        Write-Host "  WARNING: No managed resource group reported."

    }
    else {

        if ($managedRG -match "/resourceGroups/([^/]+)") {

            $managedRGName = $matches[1]

            Write-Host "  Managed RG:      $managedRGName"

            $managedResourceGroups += $managedRGName
        }
        else {

            Write-Host "  ERROR: Unable to parse managed resource group:"
            Write-Host "         $managedRG"
            exit 1
        }
    }

    $containingResourceGroups += $resourceGroup

    $workspaceRecords += [PSCustomObject]@{
        Id            = $workspaceId
        Name          = $workspaceName
        ResourceGroup = $resourceGroup
        ManagedRG     = $managedRGName
    }

    Write-Host ""
}

# Remove duplicates.
$managedResourceGroups = $managedResourceGroups |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Sort-Object -Unique

$containingResourceGroups = $containingResourceGroups |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Sort-Object -Unique

if ($workspaceRecords.Count -eq 0) {

    Write-Host "No existing Databricks workspaces require cleanup."
    exit 0
}

# ------------------------------------------------------------
# 5. Display cleanup targets
# ------------------------------------------------------------

Write-Host "============================================================"
Write-Host " Workspaces to delete"
Write-Host "============================================================"

foreach ($workspace in $workspaceRecords) {

    Write-Host "  $($workspace.Name)"
    Write-Host "    Resource group: $($workspace.ResourceGroup)"

    if ($workspace.ManagedRG) {
        Write-Host "    Managed RG:     $($workspace.ManagedRG)"
    }
}

Write-Host ""

# ------------------------------------------------------------
# 6. Delete Databricks workspaces sequentially
#
#    This uses the ARM REST API directly.
#
#    No Databricks CLI extension is required.
#
#    forceDeletion=true ensures the Databricks managed
#    resources/catalog are included in the deletion operation.
# ------------------------------------------------------------

Write-Host "============================================================"
Write-Host " Deleting Databricks workspaces"
Write-Host "============================================================"
Write-Host ""

foreach ($workspace in $workspaceRecords) {

    Write-Host "Deleting workspace: $($workspace.Name)"
    Write-Host "  Resource group: $($workspace.ResourceGroup)"

    $deleteUrl = "https://management.azure.com$($workspace.Id)?api-version=$databricksApiVersion&forceDeletion=true"

    az rest `
        --method delete `
        --url $deleteUrl `
        --only-show-errors `
        -o none 2>$null

    if ($LASTEXITCODE -ne 0) {

        Write-Host ""
        Write-Host "ERROR: Workspace deletion request failed:"
        Write-Host "  $($workspace.Name)"
        Write-Host ""
        Write-Host "Cleanup stopped. No containing resource groups will be deleted."
        exit 1
    }

    Write-Host "  Delete request submitted."

    # --------------------------------------------------------
    # Wait for workspace itself to disappear.
    #
    # The ARM delete operation may be asynchronous, so poll
    # the resource until it no longer exists.
    # --------------------------------------------------------

    $elapsed = 0
    $workspaceGone = $false

    while ($elapsed -lt $workspaceDeleteTimeoutSeconds) {

        Start-Sleep -Seconds 10
        $elapsed += 10

        az resource show `
            --ids $workspace.Id `
            --only-show-errors `
            -o none 2>$null

        if ($LASTEXITCODE -ne 0) {

            $workspaceGone = $true
            break
        }

        Write-Host "  Waiting for workspace deletion... $elapsed seconds"
    }

    if (-not $workspaceGone) {

        Write-Host ""
        Write-Host "ERROR: Workspace did not disappear within"
        Write-Host "$workspaceDeleteTimeoutSeconds seconds:"
        Write-Host "  $($workspace.Name)"
        Write-Host ""
        Write-Host "Cleanup stopped. No containing resource groups will be deleted."
        exit 1
    }

    Write-Host "  Workspace deleted."
    Write-Host ""
}

# ------------------------------------------------------------
# 7. Wait for Databricks-managed resource groups
#
#    Databricks normally removes its managed RG as part of
#    workspace deletion.
#
#    We wait rather than issuing a second independent delete
#    against the managed RG.
# ------------------------------------------------------------

if ($managedResourceGroups.Count -gt 0) {

    Write-Host "============================================================"
    Write-Host " Waiting for Databricks managed resource groups"
    Write-Host "============================================================"
    Write-Host ""

    foreach ($managedRG in $managedResourceGroups) {

        Write-Host "Waiting for managed resource group to disappear:"
        Write-Host "  $managedRG"

        $elapsed = 0
        $managedRGGone = $false

        while ($elapsed -lt $managedRGTimeoutSeconds) {

            az group show `
                --name $managedRG `
                --only-show-errors `
                -o none 2>$null

            if ($LASTEXITCODE -ne 0) {

                $managedRGGone = $true
                break
            }

            Start-Sleep -Seconds 10
            $elapsed += 10

            Write-Host "  Still present... $elapsed seconds"
        }

        if (-not $managedRGGone) {

            Write-Host ""
            Write-Host "ERROR: Managed resource group did not disappear"
            Write-Host "within $managedRGTimeoutSeconds seconds:"
            Write-Host "  $managedRG"
            Write-Host ""
            Write-Host "Containing resource groups will NOT be deleted."
            exit 1
        }

        Write-Host "  Managed resource group is gone."
        Write-Host ""
    }
}

# ------------------------------------------------------------
# 8. Check containing resource groups
#
#    Only delete a containing RG if it is empty.
#
#    This prevents the cleanup script from destroying unrelated
#    lab resources that happen to share the same RG.
# ------------------------------------------------------------

Write-Host "============================================================"
Write-Host " Checking containing resource groups"
Write-Host "============================================================"
Write-Host ""

foreach ($resourceGroup in $containingResourceGroups) {

    Write-Host "Checking resource group: $resourceGroup"

    az group show `
        --name $resourceGroup `
        --only-show-errors `
        -o none 2>$null

    if ($LASTEXITCODE -ne 0) {

        Write-Host "  Resource group is already gone."
        Write-Host ""
        continue
    }

    # Get remaining resources in the containing RG.
    $remainingResources = az resource list `
        --resource-group $resourceGroup `
        --only-show-errors `
        -o json 2>$null

    if ($LASTEXITCODE -ne 0) {

        Write-Host "  ERROR: Unable to inspect resource group."
        Write-Host "  Resource group will NOT be deleted."
        Write-Host ""
        continue
    }

    try {
        $remaining = $remainingResources | ConvertFrom-Json
    }
    catch {

        Write-Host "  ERROR: Unable to parse remaining resources."
        Write-Host "  Resource group will NOT be deleted."
        Write-Host ""
        continue
    }

    if ($null -eq $remaining) {
        $remaining = @()
    }

    if ($remaining.Count -eq 0) {

        Write-Host "  Resource group is empty."
        Write-Host "  Deleting: $resourceGroup"

        az group delete `
            --name $resourceGroup `
            --yes `
            --no-wait `
            --only-show-errors

        if ($LASTEXITCODE -ne 0) {

            Write-Host "  ERROR: Resource group deletion request failed."
            Write-Host ""
            continue
        }

        Write-Host "  Delete request submitted."

        # ----------------------------------------------------
        # Wait for the resource group to disappear.
        # ----------------------------------------------------

        $elapsed = 0
        $resourceGroupGone = $false

        while ($elapsed -lt $resourceGroupDeleteTimeoutSeconds) {

            az group show `
                --name $resourceGroup `
                --only-show-errors `
                -o none 2>$null

            if ($LASTEXITCODE -ne 0) {

                $resourceGroupGone = $true
                break
            }

            Start-Sleep -Seconds 10
            $elapsed += 10

            Write-Host "  Waiting for resource group deletion... $elapsed seconds"
        }

        if ($resourceGroupGone) {

            Write-Host "  Resource group deleted."
        }
        else {

            Write-Host "  WARNING: Resource group is still present after"
            Write-Host "  $resourceGroupDeleteTimeoutSeconds seconds."
        }

    }
    else {

        Write-Host "  Resource group contains $($remaining.Count) resource(s)."
        Write-Host "  Leaving it intact."

        foreach ($resource in $remaining) {
            Write-Host "    $($resource.type) / $($resource.name)"
        }
    }

    Write-Host ""
}

# ------------------------------------------------------------
# 9. Complete
# ------------------------------------------------------------

Write-Host "============================================================"
Write-Host " Cleanup complete"
Write-Host "============================================================"
Write-Host ""
Write-Host "Databricks workspaces associated with the current user"
Write-Host "during the last $activityLogHours hours have been processed."
Write-Host ""
