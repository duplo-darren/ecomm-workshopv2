---
name: duplo-helpdesk
description: Use this skill whenever the user wants to work on helpdesk tickets, retrieve support tickets from DuploCloud, process a ticket queue, work through a project's open issues, or action any task that involves the duplo-helpdesk MCP. Trigger when the user mentions "tickets", "helpdesk", "work on issues", "next ticket", or references a project ID or ticket number in a DuploCloud support context.
---

# DuploCloud Helpdesk Ticket Workflow

A sequential workflow for retrieving and resolving helpdesk tickets via the `duplo-helpdesk` MCP.

---

## Before Starting

**MANDATORY REQUIREMENTS: Project ID must be provided before any work can begin. Also a project name should be used as a prefix for all resources** 

### Project ID Validation

1. **Check for Project ID** — Before retrieving tickets or performing any work, verify that a project ID has been provided
2. **If Project ID is missing** — STOP and ask: *"I need a project ID to proceed. What is the project ID you'd like to work on?"*
3. **Do not proceed without a valid Project ID** — Do not retrieve tickets, do not start work, do not perform any helpdesk operations until a project ID is confirmed
4. **Confirm the Project ID** — Once provided, confirm with the user: *"Working on project ID: [PROJECT_ID]. Is this correct?"*

### Additional Confirmations

Once the Project ID is confirmed:

1. **Ticket number** — if a specific ticket was mentioned, confirm it; otherwise retrieve the queue for the confirmed project ID
2. **Final Confirmation** — display the project ID and the first ticket to action, then ask: *"Does this look right? Should I proceed?"*

**Do not begin any work until:**
- A valid project ID has been provided and confirmed
- The user has confirmed they want to proceed

---

## Workflow

### Step 1: Retrieve Tickets

Use the `duplo-helpdesk` MCP to fetch open tickets for the given project. Present a summary to the user:

- Ticket number
- Title / short description
- Priority or status (if available)

Ask the user to confirm which ticket to start with, or proceed in queue order if they say "all" or "next".

### Step 2: Work the Ticket

For each ticket:

1. **Read the full ticket** — retrieve all details, description, comments, and attachments via the MCP
2. **Check original plan documentation** — before taking action, review any plan or specification documents associated with the project to identify:
   - Environmental variables and configuration values
   - Architecture decisions and approach patterns
   - Naming conventions and standards
   - Previously established solutions or patterns
   - This ensures consistency across tickets and avoids unnecessary validation unless explicitly requested
3. **Understand the ask** — summarize what the ticket is requesting before taking action
4. **Mark the ticket as in progress** - indicates that the ticket is being worked on
4. **Take action** — perform the required work (investigation, configuration change, documentation, etc.)
5. **Verify success** — confirm the resolution is complete and correct before marking done
6. **Update the ticket** — post a resolution comment and update the ticket status via the MCP

### Step 3: Confirm Before Continuing

After each ticket is resolved and updated:

- Report back: *"Ticket #[X] is complete — [brief summary of what was done]."*
- Ask: *"Ready to move to the next ticket?"*
- Only proceed to the next ticket after explicit confirmation

---

## Rules

- **MANDATORY: Project ID Required** — NEVER proceed with any ticket operations without a confirmed project ID. If missing, STOP and request it immediately
- **Check plan documentation first** — always review the original project plan or specification documents before implementing solutions to ensure consistency in approach, environmental variables, naming conventions, and architecture patterns
- **Avoid redundant validation** — use information from plan documentation as the source of truth; only validate or ask for confirmation if explicitly requested or if the plan documentation is unclear or missing critical information
- **Never skip verification** — always confirm a ticket is fully resolved before marking it done or moving on
- **Never assume the project** — if a project ID is ambiguous or missing, always ask and wait for confirmation
- **No implicit project IDs** — do not use cached, remembered, or inferred project IDs. Always require explicit confirmation
- **Work sequentially** — complete one ticket fully before starting the next
- **Surface blockers early** — if a ticket cannot be resolved (missing info, access, dependencies), flag it immediately rather than moving on silently

