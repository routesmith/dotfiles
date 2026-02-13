#!/bin/bash

# --- Configuration ---
MAIN_REPO_DIR="git_status_test"
REMOTE_REPO_DIR="git_status_test_remote" # Directory to act as our "remote"

# --- Script Start ---
echo "--- Setting up Comprehensive Git Status Test Repository ---"

# Clean up previous tests
echo "Cleaning up previous test directories if they exist..."
rm -rf "$MAIN_REPO_DIR" "$REMOTE_REPO_DIR"

# 1. Initialize the "remote" repository (bare repo)
echo "1. Initializing remote repository ($REMOTE_REPO_DIR)..."
mkdir "$REMOTE_REPO_DIR"
cd "$REMOTE_REPO_DIR" || {
    echo "Failed to enter $REMOTE_REPO_DIR"
    exit 1
}
git init --bare -b main # Set default branch for bare repo
git config user.email "remote@example.com"
git config user.name "Git Remote User" # Bare repos don't need this for themselves, but good practice

# 2. Initialize the main local repository
echo "2. Initializing main local repository ($MAIN_REPO_DIR)..."
cd .. # Go back to parent directory
mkdir "$MAIN_REPO_DIR"
cd "$MAIN_REPO_DIR" || {
    echo "Failed to enter $MAIN_REPO_DIR"
    exit 1
}
git init -b main

# Configure user identity for THIS REPOSITORY ONLY
git config user.email "test@example.com"
git config user.name "Git Test User"

# Add the local "remote"
echo "Adding local 'remote' origin..."
git remote add origin "../$REMOTE_REPO_DIR"
git fetch origin # Fetch initial empty state

# Initial commit in main_repo and push to remote
echo "Initial content" >initial_file.txt
git add initial_file.txt
git commit -m "Initial commit"
git push -u origin main # Push initial commit and set upstream

# --- Setup for Ahead/Behind/Diverged First ---
# These require commits and remote interaction, so we do them upfront.

# Simulate a "Behind" commit on the remote
echo "Simulating 'Behind' status setup..."
cd "../$REMOTE_REPO_DIR"
git clone . ../temp_clone -b main # Clone bare repo to a temp working copy, explicitly main
cd ../temp_clone
git config user.email "temp_clone@example.com"
git config user.name "Git Temp Clone User"
echo "Remote-only change" >remote_only_file.txt
git add remote_only_file.txt
git commit -m "Remote commit: To make main_repo behind"
git push origin main
cd ..
rm -rf temp_clone # Clean up temp clone

cd "$MAIN_REPO_DIR" # Go back to the main repo
git fetch origin    # Fetch the changes, so main is now behind origin/main

# Simulate an "Ahead" commit on the local main repo
echo "Simulating 'Ahead' status setup..."
echo "Local-only change" >local_only_file.txt
git add local_only_file.txt
git commit -m "Local commit: To make main_repo ahead"

# Now, main branch is both ahead and behind (Diverged)
# Starship should show "diverged" if both ahead and behind exist.

# --- Now create all the other statuses without committing them ---

# 3. Simulate "Stashed"
echo "3. Simulating 'Stashed' status..."
echo "work in progress (file1)" >>initial_file.txt # Modify a tracked file
echo "another WIP file" >wip_file.txt              # Add a new untracked file for the stash
git add wip_file.txt                               # Stage part of the stash to ensure both staged/unstaged in stash
git stash push -m "My work in progress stash"

# 4. Simulate "Untracked" (New files not added to Git)
echo "4. Simulating 'Untracked' status..."
echo "this file is untracked" >untracked_file.txt
echo "another untracked file" >untracked_file_2.txt

# 5. Simulate "Modified" (Tracked files with changes, not staged)
echo "5. Simulating 'Modified' status..."
echo "more local changes (not staged)" >>initial_file.txt
echo "file2 changes" >>local_only_file.txt # Modify a file that was just committed

# 6. Simulate "Deleted" (Tracked files, removed from working tree, not staged)
echo "6. Simulating 'Deleted' status..."
touch file_to_delete_later.txt
git add file_to_delete_later.txt
git commit -m "Added file to delete for status test" # Commit this addition
rm file_to_delete_later.txt                          # Now delete it, it will show as 'D' in git status

# 7. Simulate "Renamed" (Tracked files, renamed, not staged)
echo "7. Simulating 'Renamed' status..."
touch file_to_rename_later.txt
git add file_to_rename_later.txt
git commit -m "Added file to rename for status test" # Commit this addition
git mv file_to_rename_later.txt renamed_file.txt     # Renamed, will show as 'R'

# 8. Simulate "Staged" (Changes added to the staging area)
echo "8. Simulating 'Staged' status..."
echo "staged new file" >staged_new_file.txt
git add staged_new_file.txt # New file, staged

echo "staged modification to initial_file" >>initial_file.txt # Further modify and stage part of it
git add initial_file.txt                                      # Stage this *new* change

# 9. Simulate "Conflicted" (This is done last to ensure it's still active)
echo "9. Simulating 'Conflicted' status..."
# Create a new temporary branch for conflict
git checkout -b conflict_temp_branch

# Make a change on conflict_temp_branch
echo "Version A for conflict" >conflict_file.txt
git add conflict_file.txt
git commit -m "Conflict A commit"

# Go back to main
git checkout main

# Make a conflicting change on main at the same line
echo "Version B for conflict" >conflict_file.txt # Create/overwrite file
git add conflict_file.txt
git commit -m "Conflict B commit" # Commit this conflicting change on main

echo "Attempting to merge conflict_temp_branch into main..."
git merge conflict_temp_branch # This will result in a merge conflict

echo "--- Setup Complete! ---"
echo "You are in '$MAIN_REPO_DIR' directory."
echo "Your Git repository is now configured to show ALL statuses."
echo "Run 'git status' to see the detailed output, and check your Starship prompt."
