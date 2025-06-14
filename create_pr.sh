#!/bin/bash

# Script to automatically create PR on GitHub
# Usage: ./create_pr.sh [PR_TITLE] [PR_DESCRIPTION] [TARGET_BRANCH] [PR_LABEL]

# Default target branch
DEFAULT_TARGET_BRANCH="main"

# Default label configuration
DEFAULT_LABEL_CONFIG=(
    "bug:type: bug(fix)"
    "feature:type: feature"
    "docs:type: docs"
    "refactor:type: refactor"
    "chore:type: chore"
)

# Function to check and create labels
ensure_label_exists() {
    local label="$1"
    local color="${2:-"0366d6"}"  # Default GitHub blue
    local description="${3:-""}"
    
    # Check if label exists
    if ! gh api "repos/:owner/:repo/labels/$label" &>/dev/null; then
        echo "Label '$label' doesn't exist, creating..."
        gh api --silent repos/:owner/:repo/labels \
            -f name="$label" \
            -f color="$color" \
            -f description="$description" || {
            echo "Warning: Unable to create label '$label'"
            return 1
        }
    fi
}

# Try to read local configuration file
if [ -f ".pr-labels" ]; then
    # Read custom label configuration
    mapfile -t LABEL_CONFIG < ".pr-labels"
else
    LABEL_CONFIG=("${DEFAULT_LABEL_CONFIG[@]}")
fi

# Check if gh CLI is installed
if ! command -v gh &> /dev/null; then
    echo "Error: GitHub CLI (gh) is not installed"
    echo "Please install GitHub CLI: https://cli.github.com/"
    exit 1
fi

# Check if logged into GitHub
if ! gh auth status &> /dev/null; then
    echo "Please login to GitHub first:"
    gh auth login
fi

# Try to load OPENAI_API_KEY from pass if not already set
if [ -z "$OPENAI_API_KEY" ] && command -v pass &> /dev/null; then
    if pass show openai/key &> /dev/null; then
        OPENAI_API_KEY=$(pass show openai/key)
    fi
fi

# Check if OPENAI_API_KEY environment variable is set
if [ -z "$OPENAI_API_KEY" ]; then
    echo "Warning: OPENAI_API_KEY environment variable is not set, AI title suggestions will not be available"
    HAS_AI=false
else
    HAS_AI=true
fi

# Get current branch
CURRENT_BRANCH=$(git symbolic-ref --short HEAD)
echo "Current branch: $CURRENT_BRANCH"

# Check if arguments were provided
HAS_ARGS=false
if [ $# -gt 0 ]; then
    HAS_ARGS=true
fi

# If no arguments provided, offer manual input options
if [ "$HAS_ARGS" = false ]; then
    # Get all commit titles
    COMMITS=$(git log origin/$DEFAULT_TARGET_BRANCH..$CURRENT_BRANCH --pretty=format:"%s")
    
    # Analyze all commits to determine main change type
    if echo "$COMMITS" | grep -iq "fix\|bug\|hotfix"; then
        TYPE="fix"
    elif echo "$COMMITS" | grep -iq "feat\|feature"; then
        TYPE="feat"
    elif echo "$COMMITS" | grep -iq "refactor"; then
        TYPE="refactor"
    elif echo "$COMMITS" | grep -iq "docs\|doc"; then
        TYPE="docs"
    else
        TYPE="feat"
    fi
    
    # Display all commits for reference
    echo -e "\nAll commits in current branch:"
    git log origin/$DEFAULT_TARGET_BRANCH..$CURRENT_BRANCH --pretty=format:"%h %s"
    
    # Extract issue number (if any)
    ISSUE_NUM=$(echo "$CURRENT_BRANCH $COMMITS" | grep -oE '#[0-9]+' | head -1)
    
    # If OPENAI_API_KEY is set, use AI to generate title suggestions
    if [ "$HAS_AI" = true ]; then
        echo -e "\nGenerating title suggestions using AI..."
        
        # Prepare commit info, convert newlines to spaces
        COMMIT_INFO=$(echo -e "Branch name: $CURRENT_BRANCH\nCommits:\n$COMMITS" | tr '\n' ' ')
        
        # Call OpenAI API and save full response
        API_RESPONSE=$(curl -s https://api.openai.com/v1/chat/completions \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer $OPENAI_API_KEY" \
          -d "{
            \"model\": \"gpt-4\",
            \"messages\": [
              {
                \"role\": \"system\",
                \"content\": \"As a PR title generation assistant, your task is to generate concise titles. Rules: 1. Use English 2. Focus only on the main change direction 3. Don't list details or use semicolons 4. Follow conventional commit format (feat/fix/docs/refactor/chore) 5. Format should be 'type: brief description (#issue)' 6. Remove (#issue) if no issue exists 7. Return title directly\"
              },
              {
                \"role\": \"user\",
                \"content\": \"$COMMIT_INFO\"
              }
            ],
            \"temperature\": 0.7,
            \"max_tokens\": 100
          }")
        
        # Check if API returned an error
        if echo "$API_RESPONSE" | grep -q "error"; then
            echo "API call error:"
            echo "$API_RESPONSE"
            AI_SUGGESTION=""
        else
            # Check if jq is installed
            if ! command -v jq &> /dev/null; then
                echo "Warning: jq tool is not installed, cannot parse JSON response"
                echo "Please install jq using:"
                echo "brew install jq"
                AI_SUGGESTION=""
            else
                # Parse API response
                AI_SUGGESTION=$(echo "$API_RESPONSE" | jq -r '.choices[0].message.content')
                
                # Check parsing result
                if [ "$AI_SUGGESTION" = "null" ] || [ -z "$AI_SUGGESTION" ]; then
                    echo "Unable to get valid title suggestion from API:"
                    echo "$API_RESPONSE"
                    # Use default title
                    MAIN_COMMIT=$(git log -1 --pretty=%s)
                    if [ -n "$ISSUE_NUM" ]; then
                        AI_SUGGESTION="$TYPE: $MAIN_COMMIT ($ISSUE_NUM)"
                    else
                        AI_SUGGESTION="$TYPE: $MAIN_COMMIT"
                    fi
                    echo "Using default title: $AI_SUGGESTION"
                else
                    echo -e "\nAI suggested title: $AI_SUGGESTION"
                fi
            fi
        fi
    fi
    
    # Let user choose whether to manually input title
    echo -e "\nDo you want to manually input PR title? (y/n)"
    read -r MANUAL_TITLE
    
    if [[ "$MANUAL_TITLE" == "y" ]]; then
        if [ "$HAS_AI" = true ] && [ -n "$AI_SUGGESTION" ]; then
            echo -e "\nEnter PR title (suggested format: $TYPE: Your title $ISSUE_NUM)"
            echo "Or press Enter to use AI suggested title"
            read -r USER_INPUT
            
            # If user just pressed Enter, use AI suggestion
            if [ -z "$USER_INPUT" ]; then
                PR_TITLE="$AI_SUGGESTION"
            else
                PR_TITLE="$USER_INPUT"
            fi
        else
            echo -e "\nEnter PR title (suggested format: $TYPE: Your title $ISSUE_NUM):"
            read -r PR_TITLE
        fi
    else
        if [ -n "$AI_SUGGESTION" ]; then
            PR_TITLE="$AI_SUGGESTION"
        else
            # Use latest commit message as main description
            MAIN_COMMIT=$(git log -1 --pretty=%s)
            if [ -n "$ISSUE_NUM" ]; then
                PR_TITLE="$TYPE: $MAIN_COMMIT ($ISSUE_NUM)"
            else
                PR_TITLE="$TYPE: $MAIN_COMMIT"
            fi
        fi
    fi

    # Remove duplicate label prefixes
    if [ -n "$PR_TITLE" ]; then
        # Fix sed command syntax
        PR_TITLE=$(echo "$PR_TITLE" | sed -E 's/^(feat|fix|docs|refactor|chore): .*(feat|fix|docs|refactor|chore)\([^)]*\): /\1: /' || echo "$PR_TITLE")
        # Remove duplicate emojis
        PR_TITLE=$(echo "$PR_TITLE" | sed -E 's/^(feat|fix|docs|refactor|chore): [✨🐛📝♻️🔧] /\1: /' || echo "$PR_TITLE")
        
        # Ensure title is not empty
        if [ -z "$PR_TITLE" ]; then
            echo "Warning: Title is empty after processing, using original title"
            if [ -n "$AI_SUGGESTION" ]; then
                PR_TITLE="$AI_SUGGESTION"
            else
                PR_TITLE="$TYPE: $(git log -1 --pretty=%s)"
            fi
        fi
    else
        echo "Error: PR title cannot be empty"
        exit 1
    fi

    echo "Final PR title: $PR_TITLE"
    
    # Try to extract label type from branch name or commit
    PR_LABEL=""
    for label_mapping in "${LABEL_CONFIG[@]}"; do
        type="${label_mapping%%:*}"
        label="${label_mapping#*:}"
        if echo "$CURRENT_BRANCH $AUTO_PR_DESCRIPTION" | grep -iq "$type"; then
            PR_LABEL="$label"
            break
        fi
    done

    # If no matching label found, use default
    if [ -z "$PR_LABEL" ]; then
        PR_LABEL="${LABEL_CONFIG[1]#*:}"  # Use feature type as default
    fi
    
    # Set parameters
    PR_DESCRIPTION=""
else
    # If arguments provided, use them
    PR_TITLE="${1:-Auto PR: $CURRENT_BRANCH}"
    PR_DESCRIPTION="${2:-}"
    TARGET_BRANCH="${3:-$DEFAULT_TARGET_BRANCH}"
    PR_LABEL="${4:-type: feature}"
fi

# Determine change type based on label
case "$PR_LABEL" in
  "type: bug(fix)")
    CHANGE_TYPE="Bug fix (non-breaking change which fixes an issue)"
    ;;
  "type: feature")
    CHANGE_TYPE="New feature (non-breaking change which adds functionality)"
    ;;
  "type: refactor")
    CHANGE_TYPE="Breaking change (fix or feature that would cause existing functionality to not work as expected)"
    ;;
  "type: docs")
    CHANGE_TYPE="This change requires a documentation update"
    ;;
  *)
    CHANGE_TYPE="New feature (non-breaking change which adds functionality)"
    ;;
esac

# Generate empty PR description
PR_BODY=""

# Ensure local changes are committed
if [[ -n $(git status --porcelain) ]]; then
    echo "There are uncommitted changes. Do you want to commit them? (y/n)"
    read -r COMMIT_CHANGES
    
    if [[ "$COMMIT_CHANGES" == "y" ]]; then
        echo "Enter commit message:"
        read -r COMMIT_MSG
        git add .
        git commit -m "$COMMIT_MSG"
    else
        echo "Please commit or stash your changes before continuing"
        exit 1
    fi
fi

# Push current branch to remote
echo "Pushing branch $CURRENT_BRANCH to remote..."
git push -u origin "$CURRENT_BRANCH"

# Create PR
echo "Creating PR from $CURRENT_BRANCH to main..."

# If label provided, ensure it exists
if [ -n "$PR_LABEL" ]; then
    # Remove possible quotes
    PR_LABEL=$(echo "$PR_LABEL" | tr -d '"')
    # Ensure label exists
    ensure_label_exists "$PR_LABEL"
fi

# Prepare PR creation command
PR_CMD="gh pr create --title \"$PR_TITLE\" --body \"$PR_BODY\" --base \"main\" --head \"$CURRENT_BRANCH\""

# If label provided, add to command
if [ -n "$PR_LABEL" ]; then
    PR_CMD="$PR_CMD --label \"$PR_LABEL\""
    echo "Adding label: $PR_LABEL"
fi

# Execute PR creation command
PR_URL=$(eval $PR_CMD)

echo "PR created: $PR_URL"

# Extract PR number for future use
PR_NUMBER=$(echo $PR_URL | grep -oE '[0-9]+$')
if [ -n "$PR_NUMBER" ]; then
    echo "PR number: $PR_NUMBER"
fi
