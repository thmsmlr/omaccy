#!/bin/bash

# Read JSON from stdin
input=$(cat)

# Extract values using jq
model=$(echo "$input" | jq -r '.model.display_name // "unknown"')
project_dir=$(echo "$input" | jq -r '.workspace.project_dir // "~"')
current_dir=$(echo "$input" | jq -r '.workspace.current_dir // "~"')

# Format project directory with ~ for home
project_name="${project_dir/#$HOME/~}"

# Build git status for project name section
if git rev-parse --git-dir > /dev/null 2>&1; then
    branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "detached")

    # Check for changes
    if [[ -n $(git status --porcelain) ]]; then
        status="*"
    else
        status="✓"
    fi

    git_status=" (\033[36m$branch\033[0m $status)"
else
    git_status=""
fi

# Working directory indicator (if different from project)
if [[ "$current_dir" == "$project_dir" ]]; then
    work_dir=""
else
    relative_dir="${current_dir#$project_dir/}"
    work_dir=" \033[33m→ $relative_dir\033[0m"
fi

# Build status line
echo -e "\033[34m$project_name\033[0m$git_status$work_dir | \033[35m$model\033[0m"
