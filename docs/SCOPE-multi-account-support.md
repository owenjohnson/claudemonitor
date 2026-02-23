# Scope: Multi-Account Support

## Problem Statement
Add multi-account support to the ClaudeUsage macOS menubar app. The simplest approach: automatically capture and store OAuth tokens as users switch accounts in Claude Code CLI, then fetch and display usage for all known accounts. Key features: detect account changes from keychain, persist multiple account credentials in app's own storage, fetch usage data per account, update UI to show all accounts.

## Pipeline Autonomy
This pipeline should run **hands-off** through all 7 stages. The scope description above is the complete design brief.
