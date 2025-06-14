#!/bin/bash

# 尋找 Gemini 的 Summary of Changes 並更新 PR 描述
# 使用方法: ./gemini_finder.sh [PR編號]

# 檢查是否安裝了gh CLI
if ! command -v gh &> /dev/null; then
    echo "錯誤: GitHub CLI (gh) 未安裝"
    echo "請安裝 GitHub CLI: https://cli.github.com/"
    exit 1
fi

# 如果尚未設置 GEMINI_API_KEY，嘗試從 pass 取得
if [ -z "$GEMINI_API_KEY" ] && command -v pass &> /dev/null; then
    if pass show gemini/key &> /dev/null; then
        GEMINI_API_KEY=$(pass show gemini/key)
    fi
fi

# 檢查 GEMINI_API_KEY 是否存在
if [ -z "$GEMINI_API_KEY" ]; then
    echo "錯誤: 未設置 GEMINI_API_KEY"
    echo "請在 ~/.zshrc 或密碼管理器中設置 GEMINI_API_KEY"
    exit 1
fi

# 檢查是否已登錄GitHub
if ! gh auth status &> /dev/null; then
    echo "請先登錄GitHub:"
    gh auth login
fi

# 檢查是否提供了PR編號
if [ -z "$1" ]; then
    echo "請提供PR編號"
    exit 1
fi

PR_NUMBER=$1
echo "正在處理PR #$PR_NUMBER"

# 獲取PR的reviews
echo "正在獲取PR的reviews..."
REVIEWS=$(gh pr view $PR_NUMBER --json reviews,comments)
REVIEW_COUNT=$(echo "$REVIEWS" | jq '.reviews | length')
echo "找到 $REVIEW_COUNT 個 reviews"

# 尋找Gemini生成的內容
echo "正在尋找Gemini生成的 Summary of Changes..."
GEMINI_CONTENT=""

# 先從 reviews 中尋找
for ((i=0; i<$REVIEW_COUNT; i++)); do
    AUTHOR=$(echo "$REVIEWS" | jq -r ".reviews[$i].author.login")
    if [ "$AUTHOR" = "gemini-code-assist" ]; then
        echo "尋找 gemini-code-assist 的 review..."
        REVIEW_BODY=$(echo "$REVIEWS" | jq -r ".reviews[$i].body")
        if [[ $REVIEW_BODY == *"Summary of Changes"* ]]; then
            GEMINI_CONTENT="$REVIEW_BODY"
            echo "從 gemini-code-assist 的 review 中找到了內容！"
            break
        fi
    fi
done

# 如果在 reviews 中沒找到，就從 comments 中尋找
if [ -z "$GEMINI_CONTENT" ]; then
    echo "在 reviews 中未找到內容，正在檢查 comments..."
    COMMENT_COUNT=$(echo "$REVIEWS" | jq '.comments | length')
    echo "找到 $COMMENT_COUNT 個 comments"
    
    for ((i=0; i<$COMMENT_COUNT; i++)); do
        AUTHOR=$(echo "$REVIEWS" | jq -r ".comments[$i].author.login")
        if [ "$AUTHOR" = "gemini-code-assist" ]; then
            echo "找到 gemini-code-assist 的 comment..."
            COMMENT_BODY=$(echo "$REVIEWS" | jq -r ".comments[$i].body")
            if [[ $COMMENT_BODY == *"Summary of Changes"* ]]; then
                GEMINI_CONTENT="$COMMENT_BODY"
                echo "從 gemini-code-assist 的 comment 中找到了內容！"
                break
            fi
        fi
    done
fi

if [ -z "$GEMINI_CONTENT" ]; then
    echo "未找到 Gemini 生成的內容（無論是在 reviews 還是 comments 中）"
    exit 1
fi

echo "Gemini 內容狀態: 找到了"

# 創建臨時文件
TEMP_FILE=$(mktemp)
RESULT_FILE="${TEMP_FILE}.final"

# 保存原始內容到臨時文件，保持換行符
echo "$GEMINI_CONTENT" > "$TEMP_FILE"

# 提取主要內容
echo "提取主要內容..."
if grep -q "## Summary of Changes" "$TEMP_FILE"; then
    # 使用 awk 提取內容
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
                # 檢查是否有 details 標籤
                if ($0 ~ /^<details>/) {
                    details_found = 1
                    print ""
                    print
                    next
                }
                # 如果找到列表項目且沒有 details 標籤
                if (!details_found && ($0 ~ /^\* / || $0 ~ /^  \* /)) {
                    list_mode = 1
                    print
                    next
                }
                # 如果在列表模式中且遇到空行或新的章節，就結束
                if (list_mode && ($0 ~ /^$/ || $0 ~ /^##/)) {
                    exit
                }
                # 如果在 details 模式中且遇到結束標籤
                if (details_found && $0 ~ /^<\/details>/) {
                    print
                    exit
                }
                # 輸出其他內容
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
    # 如果找不到 Summary of Changes，使用前半部分內容
    sed -n '1,/^<details>/p' "$TEMP_FILE" | sed '$d' > "$RESULT_FILE"
fi

# 清理內容
sed -i '' '/^$/N;/^\n$/D' "$RESULT_FILE"  # 移除連續的空行

# 使用 Gemini API 進行翻譯
echo "正在使用 Gemini API 翻譯內容..."
CONTENT_TO_TRANSLATE=$(cat "$RESULT_FILE")
echo "原始內容長度: $(echo "$CONTENT_TO_TRANSLATE" | wc -c) 字元"

# 將內容轉義以避免 JSON 格式問題
ESCAPED_CONTENT=$(echo "$CONTENT_TO_TRANSLATE" | jq -Rs .)
PROMPT=$(cat << EOF | jq -Rs .
你是一個專業的翻譯助手。請將以下英文內容完整翻譯成正體中文。注意：
1. 必須將所有英文內容翻譯成正體中文
2. 保持所有的 Markdown 格式標記不變
3. 保持所有的程式碼區塊、連結和技術名詞格式不變
4. 使用台灣地區常用的專業術語翻譯方式

以下是需要翻譯的內容：

$CONTENT_TO_TRANSLATE
EOF
)

# 建立 API URL（確保 API 金鑰正確編碼）
API_URL="https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"
ENCODED_KEY=$(echo "$GEMINI_API_KEY" | jq -sRr @uri)

# 準備請求內容
REQUEST_BODY=$(jq -n \
    --arg prompt "$PROMPT" \
    '{
        "contents": [{
            "parts":[{
                "text": $prompt
            }]
        }]
    }')

# 發送 API 請求
RESPONSE=$(curl -s -X POST "${API_URL}?key=${ENCODED_KEY}" \
    -H "Content-Type: application/json" \
    -d "$REQUEST_BODY")

echo "完整 API 回應:" > /tmp/gemini_response.log
echo "$RESPONSE" >> /tmp/gemini_response.log
echo "請求內容：" >> /tmp/gemini_response.log
echo "$REQUEST_BODY" >> /tmp/gemini_response.log

# 檢查回應是否為空
if [ -z "$RESPONSE" ]; then
    echo "API 回應為空"
    echo "$CONTENT_TO_TRANSLATE" > "$RESULT_FILE"
else
    # 嘗試解析回應
    if echo "$RESPONSE" | jq -e '.candidates[0].content.parts[0].text' > /dev/null 2>&1; then
        TRANSLATED_CONTENT=$(echo "$RESPONSE" | jq -r '.candidates[0].content.parts[0].text')
        echo "翻譯成功"
        
        # 移除開頭和結尾的 code 標記
        CLEANED_CONTENT=$(echo "$TRANSLATED_CONTENT" | sed -E '1s/^```(markdown)?[[:space:]]*//' | sed -E '$s/```[[:space:]]*$//')
        
        echo "$CLEANED_CONTENT" > "$RESULT_FILE"
    else
        echo "無法解析 API 回應，使用原始內容"
        echo "API 回應內容："
        echo "$RESPONSE"
        echo "$CONTENT_TO_TRANSLATE" > "$RESULT_FILE"
    fi
fi

# 確認最終內容
echo "最終內容預覽:"
head -n 5 "$RESULT_FILE"
echo "..."

# 更新PR描述
echo "正在更新PR描述..."
if [ -s "$RESULT_FILE" ]; then
    gh pr edit $PR_NUMBER --body "$(cat "$RESULT_FILE")"
    echo "PR描述已更新"
else
    echo "錯誤：結果文件為空，保持原有PR描述不變"
    exit 1
fi

# 清理臨時文件
rm -f "$TEMP_FILE" "$RESULT_FILE"
