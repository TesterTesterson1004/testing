# ============================================================
# Azure Databricks Lab Cleanup
#
# Purpose:
#   Find Azure Databricks workspaces associated with the
#   current user during the last 4 hours and clean them up.
#
# Requirements:
#   - Azure Cloud Shell PowerShell
#   - Student is signed in as the user who created the resources
#   - No Databricks CLI extension required
#
# Behavior:
#   - No confirmation prompts
#   - Deletes Databricks workspaces sequentially
#   - Uses forceDeletion=true
#   - Waits for Databricks managed resource groups to disappear
#   - Deletes the containing resource group only if it is empty
#   - NEVER uses "exit", so it cannot terminate the Cloud Shell
#     PowerShell session when pasted directly into Cloud Shell
# ============================================================

$ErrorActionPreference = "Continue"

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

$activityLogHours = 4
$waitSeconds = 1800
$pollSeconds = 15
$databricksApiVersion = "2026-01-01"

Write-Host ""
Write-Host "============================================================"
Write-Host " Azure Databricks Lab Cleanup"
Write-Host "============================================================"
Write-Host ""

# ------------------------------------------------------------
# Get current Azure account
# ------------------------------------------------------------

$caller = az account show `
    --query user.name `
    -o tsv `
    --only-show-errors 2>$null

if ([string]::IsNullOrWhiteSpace($caller)) {
    Write-Host "ERROR: Unable to determine the current Azure user."
    Write-Host "Nothing will be deleted."
    return
}

Write-Host "Current user:"
Write-Host "  $caller"
Write-Host ""

# ------------------------------------------------------------
# Get current subscription
# ------------------------------------------------------------

$subscriptionId = az account show `
    --query id `
    -o tsv `
    --only-show-errors 2>$null

if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
    Write-Host "ERROR: Unable to determine the current subscription."
    Write-Host "Nothing will be deleted."
    return
}

Write-Host "Subscription:"
Write-Host "  $subscriptionId"
Write-Host ""

# ------------------------------------------------------------
# Find recent Azure Activity Log events for this user
# ------------------------------------------------------------

Write-Host "Searching Azure Activity Log..."
Write-Host "  Caller:  $caller"
Write-Host "  Window:  last $activityLogHours hours"
Write-Host ""

$activityLogJson = az monitor activity-log list `
    --caller $caller `
    --offset "${activityLogHours}h" `
    --max-events 1000 `
    --only-show-errors `
    -o json 2>$null

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($activityLogJson)) {
    Write-Host "No Activity Log data was returned."
    Write-Host "Nothing will be deleted."
    return
}

try {
    $activityLog = $activityLogJson | ConvertFrom-Json
}
catch {
    Write-Host "ERROR: Unable to parse Activity Log data."
    Write-Host "Nothing will be deleted."
    return
}

Write-Host "Activity Log events returned: $($activityLog.Count)"
Write-Host ""

# ------------------------------------------------------------
# Find Databricks workspace WRITE operations for this user.
#
# Databricks workspace creation in the lab may produce:
#
#   Started
#   Accepted
#   Succeeded
#
# We accept any of those states.
#
# IMPORTANT:
#   We intentionally do NOT use "read" operations for discovery.
#   A read only proves that the user accessed the workspace; it
#   does not establish that the user created/modified it.
# ------------------------------------------------------------

$workspaceEvents = @(
    $activityLog |
    Where-Object {
        $_.operationName.value -eq "Microsoft.Databricks/workspaces/write" -and
        $_.status.value -in @("Started", "Accepted", "Succeeded") -and
        $_.resourceId -match "/providers/Microsoft\.Databricks/workspaces/"
    }
)

if ($workspaceEvents.Count -eq 0) {
    Write-Host "No Databricks workspace write activity was found for this user"
    Write-Host "during the last $activityLogHours hours."
    Write-Host ""
    Write-Host "Nothing will be deleted."
    return
}

# ------------------------------------------------------------
# Get unique workspace IDs
# ------------------------------------------------------------

$workspaceIds = @(
    $workspaceEvents |
    Select-Object -ExpandProperty resourceId -Unique
)

Write-Host "Databricks workspaces identified: $($workspaceIds.Count)"
Write-Host ""

foreach ($id in $workspaceIds) {
    Write-Host "  $id"
}

Write-Host ""

# ------------------------------------------------------------
# Build workspace information
# ------------------------------------------------------------

$workspaces = @()
$managedResourceGroups = @()
$containingResourceGroups = @()

foreach ($workspaceId in $workspaceIds) {

    Write-Host "------------------------------------------------------------"
    Write-Host "Inspecting workspace:"
    Write-Host "  $workspaceId"

    # --------------------------------------------------------
    # Retrieve workspace directly through ARM
    # --------------------------------------------------------

    $workspaceResourceJson = az resource show `
        --ids $workspaceId `
        --only-show-errors `
        -o json 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($workspaceResourceJson)) {
        Write-Host "ERROR: Unable to retrieve workspace:"
        Write-Host "  $workspaceId"
        Write-Host ""
        Write-Host "Cleanup stopped for safety."
        return
    }

    try {
        $workspaceResource = $workspaceResourceJson | ConvertFrom-Json
    }
    catch {
        Write-Host "ERROR: Unable to parse workspace information."
        Write-Host ""
        Write-Host "Cleanup stopped for safety."
        return
    }

    # --------------------------------------------------------
    # Extract workspace resource group and name
    # --------------------------------------------------------

    if ($workspaceResource.id -notmatch "/resourceGroups/([^/]+)/providers/Microsoft\.Databricks/workspaces/([^/]+)$") {
        Write-Host "ERROR: Unable to determine workspace/resource-group information."
        Write-Host ""
        Write-Host "Cleanup stopped for safety."
        return
    }

    $workspaceResourceGroup = $Matches[1]
    $workspaceName = $Matches[2]

    Write-Host "  Workspace:       $workspaceName"
    Write-Host "  Resource group:  $workspaceResourceGroup"

    # --------------------------------------------------------
    # Extract Databricks managed resource group
    # --------------------------------------------------------

    $managedResourceGroupId = $workspaceResource.properties.managedResourceGroupId

    if ([string]::IsNullOrWhiteSpace($managedResourceGroupId)) {
        Write-Host "ERROR: Workspace does not expose managedResourceGroupId."
        Write-Host ""
        Write-Host "Cleanup stopped for safety."
        return
    }

    if ($managedResourceGroupId -notmatch "/resourceGroups/([^/]+)$") {
        Write-Host "ERROR: Unable to determine Databricks managed resource group."
        Write-Host "  $managedResourceGroupId"
        Write-Host ""
        Write-Host "Cleanup stopped for safety."
        return
    }

    $managedResourceGroup = $Matches[1]

    Write-Host "  Managed RG:      $managedResourceGroup"
    Write-Host ""

    # --------------------------------------------------------
    # Save information
    # --------------------------------------------------------

    $workspaces += [PSCustomObject]@{
        Id                   = $workspaceId
        Name                 = $workspaceName
        ResourceGroup        = $workspaceResourceGroup
        ManagedResourceGroup = $managedResourceGroup
    }

    if ($managedResourceGroups -notcontains $managedResourceGroup) {
        $managedResourceGroups += $managedResourceGroup
    }

    if ($containingResourceGroups -notcontains $workspaceResourceGroup) {
        $containingResourceGroups += $workspaceResourceGroup
    }
}

# ------------------------------------------------------------
# Delete workspaces sequentially
# ------------------------------------------------------------

Write-Host ""
Write-Host "============================================================"
Write-Host " Deleting Databricks Workspaces"
Write-Host "============================================================"
Write-Host ""

foreach ($workspace in $workspaces) {

    Write-Host "Deleting workspace:"
    Write-Host "  $($workspace.Name)"
    Write-Host "  Resource group: $($workspace.ResourceGroup)"
    Write-Host "  Managed RG:     $($workspace.ManagedResourceGroup)"
    Write-Host ""

    # --------------------------------------------------------
    # Construct REST DELETE URL.
    #
    # ${workspace.Id} is intentional. The braces make the
    # PowerShell variable boundary explicit before "?..."
    # --------------------------------------------------------

    $deleteUrl = "https://management.azure.com${workspace.Id}?api-version=$databricksApiVersion&forceDeletion=true"

    Write-Host "Submitting workspace deletion..."

    az rest `
        --method delete `
        --url $deleteUrl `
        --only-show-errors `
        -o none 2>$null

    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "ERROR: Workspace deletion failed:"
        Write-Host "  $($workspace.Name)"
        Write-Host ""
        Write-Host "Cleanup stopped."
        return
    }

    Write-Host "Delete request submitted."
    Write-Host ""

    # --------------------------------------------------------
    # Wait for workspace to disappear
    # --------------------------------------------------------

    Write-Host "Waiting for workspace to disappear..."

    $workspaceDeleted = $false
    $elapsed = 0

    while ($elapsed -lt $waitSeconds) {

        az resource show `
            --ids $workspace.Id `
            --only-show-errors `
            -o none 2>$null

        if ($LASTEXITCODE -ne 0) {
            $workspaceDeleted = $true
            break
        }

        Start-Sleep -Seconds $pollSeconds
        $elapsed += $pollSeconds

        Write-Host "  Still deleting... ($elapsed seconds)"
    }

    if (-not $workspaceDeleted) {
        Write-Host ""
        Write-Host "ERROR: Workspace did not disappear within $waitSeconds seconds."
        Write-Host "  $($workspace.Name)"
        Write-Host ""
        Write-Host "Cleanup stopped."
        return
    }

    Write-Host "Workspace deleted."
    Write-Host ""
}

# ------------------------------------------------------------
# Wait for Databricks managed resource groups
#
# Do NOT manually delete these. forceDeletion=true requests
# that Databricks remove them as part of workspace deletion.
# ------------------------------------------------------------

Write-Host "============================================================"
Write-Host " Waiting for Databricks Managed Resource Groups"
Write-Host "============================================================"
Write-Host ""

foreach ($managedResourceGroup in $managedResourceGroups) {

    Write-Host "Managed resource group:"
    Write-Host "  $managedResourceGroup"

    $managedRgDeleted = $false
    $elapsed = 0

    while ($elapsed -lt $waitSeconds) {

        az group show `
            --name $managedResourceGroup `
            --only-show-errors `
            -o none 2>$null

        if ($LASTEXITCODE -ne 0) {
            $managedRgDeleted = $true
            break
        }

        Start-Sleep -Seconds $pollSeconds
        $elapsed += $pollSeconds

        Write-Host "  Still present... ($elapsed seconds)"
    }

    if (-not $managedRgDeleted) {
        Write-Host ""
        Write-Host "ERROR: Databricks managed resource group did not disappear"
        Write-Host "within $waitSeconds seconds:"
        Write-Host "  $managedResourceGroup"
        Write-Host ""
        Write-Host "Cleanup stopped."
        return
    }

    Write-Host "Managed resource group removed."
    Write-Host ""
}

# ------------------------------------------------------------
# Clean up containing resource groups
#
# Only delete a containing RG if it is completely empty.
# ------------------------------------------------------------

Write-Host "============================================================"
Write-Host " Cleaning Containing Resource Groups"
Write-Host "============================================================"
Write-Host ""

foreach ($resourceGroup in $containingResourceGroups) {

    Write-Host "Checking resource group:"
    Write-Host "  $resourceGroup"

    $remainingResourcesJson = az resource list `
        --resource-group $resourceGroup `
        --only-show-errors `
        -o json 2>$null

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Unable to inspect resource group."
        Write-Host "Skipping: $resourceGroup"
        Write-Host ""
        continue
    }

    try {
        $remainingResources = @(
            $remainingResourcesJson | ConvertFrom-Json
        )
    }
    catch {
        Write-Host "Unable to parse resource list."
        Write-Host "Skipping: $resourceGroup"
        Write-Host ""
        continue
    }

    if ($remainingResources.Count -eq 0) {

        Write-Host "Resource group is empty."
        Write-Host "Deleting: $resourceGroup"
        Write-Host ""

        az group delete `
            --name $resourceGroup `
            --yes `
            --no-wait `
            --only-show-errors

        if ($LASTEXITCODE -ne 0) {
            Write-Host "WARNING: Resource group deletion request failed:"
            Write-Host "  $resourceGroup"
            Write-Host ""
            continue
        }

        # ----------------------------------------------------
        # Wait for resource group deletion
        # ----------------------------------------------------

        $rgDeleted = $false
        $elapsed = 0

        while ($elapsed -lt $waitSeconds) {

            az group show `
                --name $resourceGroup `
                --only-show-errors `
                -o none 2>$null

            if ($LASTEXITCODE -ne 0) {
                $rgDeleted = $true
                break
            }

            Start-Sleep -Seconds $pollSeconds
            $elapsed += $pollSeconds

            Write-Host "  Still deleting... ($elapsed seconds)"
        }

        if ($rgDeleted) {
            Write-Host "Resource group deleted."
        }
        else {
            Write-Host "WARNING: Resource group deletion is still in progress."
            Write-Host "  $resourceGroup"
        }

    }
    else {

        Write-Host "Resource group is NOT empty."
        Write-Host "It will NOT be deleted."
        Write-Host "Remaining resources: $($remainingResources.Count)"
    }

    Write-Host ""
}

# ------------------------------------------------------------
# Complete
# ------------------------------------------------------------

Write-Host "============================================================"
Write-Host " Cleanup Complete"
Write-Host "============================================================"
Write-Host ""
Write-Host "Databricks workspaces identified from the current user's"
Write-Host "Activity Log were processed."
Write-Host ""
Write-Host "Cloud Shell session remains active."
Write-Host ""
