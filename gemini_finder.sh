#!/bin/bash

# Find Gemini's Summary of Changes and update PR description
# Usage: ./gemini_finder.sh [PR_NUMBER]

# Check if gh CLI is installed
if ! command -v gh &> /dev/null; then
    echo "Error: GitHub CLI (gh) is not installed"
    echo "Please install GitHub CLI: https://cli.github.com/"
    exit 1
fi

# Try to load GEMINI_API_KEY from pass if not already set
if [ -z "$GEMINI_API_KEY" ] && command -v pass &> /dev/null; then
    if pass show gemini/key &> /dev/null; then
        GEMINI_API_KEY=$(pass show gemini/key)
    fi
fi

# Check if GEMINI_API_KEY exists
if [ -z "$GEMINI_API_KEY" ]; then
    echo "Error: GEMINI_API_KEY is not set"
    echo "Please set GEMINI_API_KEY in your ~/.zshrc or password manager"
    exit 1
fi

# Check if logged into GitHub
if ! gh auth status &> /dev/null; then
    echo "Please login to GitHub first:"
    gh auth login
fi

# Check if PR number is provided
if [ -z "$1" ]; then
    echo "Please provide a PR number"
    exit 1
fi

PR_NUMBER=$1
echo "Processing PR #$PR_NUMBER"

# Get PR reviews and comments
echo "Getting PR reviews and comments..."
REVIEWS=$(gh pr view $PR_NUMBER --json reviews,comments)
REVIEW_COUNT=$(echo "$REVIEWS" | jq '.reviews | length')
echo "Found $REVIEW_COUNT reviews"

# Find Gemini generated content
echo "Looking for Gemini's Summary of Changes..."
GEMINI_CONTENT=""

# First look in reviews
for ((i=0; i<$REVIEW_COUNT; i++)); do
    AUTHOR=$(echo "$REVIEWS" | jq -r ".reviews[$i].author.login")
    if [ "$AUTHOR" = "gemini-code-assist" ]; then
        echo "Found gemini-code-assist review..."
        REVIEW_BODY=$(echo "$REVIEWS" | jq -r ".reviews[$i].body")
        if [[ $REVIEW_BODY == *"Summary of Changes"* ]]; then
            GEMINI_CONTENT="$REVIEW_BODY"
            echo "Found content in gemini-code-assist review!"
            break
        fi
    fi
done

# If not found in reviews, check comments
if [ -z "$GEMINI_CONTENT" ]; then
    echo "Content not found in reviews, checking comments..."
    COMMENT_COUNT=$(echo "$REVIEWS" | jq '.comments | length')
    echo "Found $COMMENT_COUNT comments"
    
    for ((i=0; i<$COMMENT_COUNT; i++)); do
        AUTHOR=$(echo "$REVIEWS" | jq -r ".comments[$i].author.login")
        if [ "$AUTHOR" = "gemini-code-assist" ]; then
            echo "Found gemini-code-assist comment..."
            COMMENT_BODY=$(echo "$REVIEWS" | jq -r ".comments[$i].body")
            if [[ $COMMENT_BODY == *"Summary of Changes"* ]]; then
                GEMINI_CONTENT="$COMMENT_BODY"
                echo "Found content in gemini-code-assist comment!"
                break
            fi
        fi
    done
fi

if [ -z "$GEMINI_CONTENT" ]; then
    echo "No Gemini generated content found (in either reviews or comments)"
    exit 1
fi

echo "Gemini content status: Found"

# Create temporary files
TEMP_FILE=$(mktemp)
RESULT_FILE="${TEMP_FILE}.final"

# Save original content to temp file, preserving line breaks
echo "$GEMINI_CONTENT" > "$TEMP_FILE"

# Extract main content
echo "Extracting main content..."
if grep -q "## Summary of Changes" "$TEMP_FILE"; then
    # Use awk to extract content
    awk '
        BEGIN { printing = 0; changelog_found = 0; details_found = 0; list_mode = 0 }
        /^## Summary of Changes$/ { printing = 1 }
        printing == 1 { 
            if ($0 ~ /^### Changelog$/) {
                changelog_found = 1
                print "## Changelog"
                next
            }
            if (changelog_found) {
                # Check if details tag exists
                if ($0 ~ /^<details>/) {
                    details_found = 1
                    print ""
                    print
                    next
                }
                # If list item found and no details tag
                if (!details_found && ($0 ~ /^\* / || $0 ~ /^  \* /)) {
                    list_mode = 1
                    print
                    next
                }
                # If in list mode and empty line or new section found, exit
                if (list_mode && ($0 ~ /^$/ || $0 ~ /^##/)) {
                    exit
                }
                # If in details mode and closing tag found
                if (details_found && $0 ~ /^<\/details>/) {
                    print
                    exit
                }
                # Output other content
                if (details_found || list_mode) {
                    print
                }
            }
            if (!changelog_found) {
                print
            }
        }
    ' "$TEMP_FILE" > "$RESULT_FILE"
else
    # If Summary of Changes not found, use first half of content
    sed -n '1,/^<details>/p' "$TEMP_FILE" | sed '$d' > "$RESULT_FILE"
fi

# Clean up content
sed -i '' '/^$/N;/^\n$/D' "$RESULT_FILE"  # Remove consecutive empty lines

# Use Gemini API for translation
echo "Using Gemini API to translate content..."
CONTENT_TO_TRANSLATE=$(cat "$RESULT_FILE")
echo "Original content length: $(echo "$CONTENT_TO_TRANSLATE" | wc -c) characters"

# Escape content to avoid JSON format issues
ESCAPED_CONTENT=$(echo "$CONTENT_TO_TRANSLATE" | jq -Rs .)
PROMPT=$(cat << EOF | jq -Rs .
You are a professional translation assistant. Please translate the following English content into Traditional Chinese. Note:
1. All English content must be translated to Traditional Chinese
2. Keep all Markdown format markers unchanged
3. Keep all code blocks, links, and technical terms format unchanged
4. Use professional terminology common in Taiwan

Here's the content to translate:

$CONTENT_TO_TRANSLATE
EOF
)

# Build API URL (ensure API key is properly encoded)
API_URL="https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"
ENCODED_KEY=$(echo "$GEMINI_API_KEY" | jq -sRr @uri)

# Prepare request content
REQUEST_BODY=$(jq -n \
    --arg prompt "$PROMPT" \
    '{
        "contents": [{
            "parts":[{
                "text": $prompt
            }]
        }]
    }')

# Send API request
RESPONSE=$(curl -s -X POST "${API_URL}?key=${ENCODED_KEY}" \
    -H "Content-Type: application/json" \
    -d "$REQUEST_BODY")

echo "Full API response:" > /tmp/gemini_response.log
echo "$RESPONSE" >> /tmp/gemini_response.log
echo "Request content:" >> /tmp/gemini_response.log
echo "$REQUEST_BODY" >> /tmp/gemini_response.log

# Check if response is empty
if [ -z "$RESPONSE" ]; then
    echo "API response is empty"
    echo "$CONTENT_TO_TRANSLATE" > "$RESULT_FILE"
else
    # Try to parse response
    if echo "$RESPONSE" | jq -e '.candidates[0].content.parts[0].text' > /dev/null 2>&1; then
        TRANSLATED_CONTENT=$(echo "$RESPONSE" | jq -r '.candidates[0].content.parts[0].text')
        echo "Translation successful"
        
        # Remove leading and trailing code markers
        CLEANED_CONTENT=$(echo "$TRANSLATED_CONTENT" | sed -E '1s/^```(markdown)?[[:space:]]*//' | sed -E '$s/```[[:space:]]*$//')
        
        echo "$CLEANED_CONTENT" > "$RESULT_FILE"
    else
        echo "Unable to parse API response, using original content"
        echo "API response content:"
        echo "$RESPONSE"
        echo "$CONTENT_TO_TRANSLATE" > "$RESULT_FILE"
    fi
fi

# Preview final content
echo "Final content preview:"
head -n 5 "$RESULT_FILE"
echo "..."

# Update PR description
echo "Updating PR description..."
if [ -s "$RESULT_FILE" ]; then
    gh pr edit $PR_NUMBER --body "$(cat "$RESULT_FILE")"
    echo "PR description updated"
else
    echo "Error: Result file is empty, keeping original PR description"
    exit 1
fi

# Clean up temporary files
rm -f "$TEMP_FILE" "$RESULT_FILE"
