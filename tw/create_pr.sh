#!/bin/bash

# 自動發送PR到GitHub的腳本

# 設置的目標分支
DEFAULT_TARGET_BRANCH="main"

# 預設標籤配置
DEFAULT_LABEL_CONFIG=(
    "bug:type: bug(fix)"
    "feature:type: feature"
    "docs:type: docs"
    "refactor:type: refactor"
    "chore:type: chore"
)

# 檢查並創建標籤的函數
ensure_label_exists() {
    local label="$1"
    local color="${2:-"0366d6"}"  # 預設使用 GitHub 的藍色
    local description="${3:-""}"
    
    # 檢查標籤是否存在
    if ! gh api "repos/:owner/:repo/labels/$label" &>/dev/null; then
        echo "標籤 '$label' 不存在，正在創建..."
        gh api --silent repos/:owner/:repo/labels \
            -f name="$label" \
            -f color="$color" \
            -f description="$description" || {
            echo "警告: 無法創建標籤 '$label'"
            return 1
        }
    fi
}

# 嘗試讀取本地配置文件
if [ -f ".pr-labels" ]; then
    # 讀取自定義標籤配置
    mapfile -t LABEL_CONFIG < ".pr-labels"
else
    LABEL_CONFIG=("${DEFAULT_LABEL_CONFIG[@]}")
fi

# 檢查是否安裝了gh CLI
if ! command -v gh &> /dev/null; then
    echo "錯誤: GitHub CLI (gh) 未安裝"
    echo "請安裝 GitHub CLI: https://cli.github.com/"
    exit 1
fi

# 檢查是否已登錄GitHub
if ! gh auth status &> /dev/null; then
    echo "請先登錄GitHub:"
    gh auth login
fi

# 如果尚未設置 OPENAI_API_KEY，嘗試從 pass 取得
if [ -z "$OPENAI_API_KEY" ] && command -v pass &> /dev/null; then
    if pass show openai/key &> /dev/null; then
        OPENAI_API_KEY=$(pass show openai/key)
    fi
fi

# 檢查是否設置了 OPENAI_API_KEY 環境變數
if [ -z "$OPENAI_API_KEY" ]; then
    echo "警告: 未設置 OPENAI_API_KEY 環境變數，將無法使用 AI 生成標題建議"
    HAS_AI=false
else
    HAS_AI=true
fi

# 獲取當前分支
CURRENT_BRANCH=$(git symbolic-ref --short HEAD)
echo "當前分支: $CURRENT_BRANCH"

# 檢查是否提供了參數
HAS_ARGS=false
if [ $# -gt 0 ]; then
    HAS_ARGS=true
fi

# 如果沒有提供參數，則提供手動輸入選項
if [ "$HAS_ARGS" = false ]; then
    # 獲取所有commit的標題
    COMMITS=$(git log origin/$DEFAULT_TARGET_BRANCH..$CURRENT_BRANCH --pretty=format:"%s")
    
    # 分析所有commit來決定主要改動類型
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
    
    # 顯示所有commits供參考
    echo -e "\n當前分支的所有commits:"
    git log origin/$DEFAULT_TARGET_BRANCH..$CURRENT_BRANCH --pretty=format:"%h %s"
    
    # 提取issue編號（如果有的話）
    ISSUE_NUM=$(echo "$CURRENT_BRANCH $COMMITS" | grep -oE '#[0-9]+' | head -1)
    
    # 如果有設置 OPENAI_API_KEY，則使用 AI 生成標題建議
    if [ "$HAS_AI" = true ]; then
        echo -e "\n正在使用 AI 生成標題建議..."
        
        # 準備提交信息，將換行符轉換為空格
        COMMIT_INFO=$(echo -e "分支名稱: $CURRENT_BRANCH\n提交記錄:\n$COMMITS" | tr '\n' ' ')
        
        # 調用 OpenAI API 並保存完整回應
        API_RESPONSE=$(curl -s https://api.openai.com/v1/chat/completions \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer $OPENAI_API_KEY" \
          -d "{
            \"model\": \"gpt-4o\",
            \"messages\": [
              {
                \"role\": \"system\",
                \"content\": \"作為 PR 標題生成助手，你的任務是生成簡潔的標題。規則：1.使用正體中文 2.只關注最主要的改動方向 3.不要列舉細節或使用分號 4. 遵循約定式提交規範（feat/fix/docs/refactor/chore）5.格式為'類型: 簡短描述 (#issue號)' 6. 沒有 issue 的話，移除 (#issue號) 文字 7.直接返回標題\"
              },
              {
                \"role\": \"user\",
                \"content\": \"$COMMIT_INFO\"
              }
            ],
            \"temperature\": 0.7,
            \"max_tokens\": 100
          }")
        
        # 檢查 API 是否返回錯誤
        if echo "$API_RESPONSE" | grep -q "error"; then
            echo "API 調用出錯："
            echo "$API_RESPONSE"
            AI_SUGGESTION=""
        else
            # 檢查是否安裝了 jq
            if ! command -v jq &> /dev/null; then
                echo "警告: 未安裝 jq 工具，無法解析 JSON 回應"
                echo "請使用以下命令安裝 jq："
                echo "brew install jq"
                AI_SUGGESTION=""
            else
                # 解析 API 回應
                AI_SUGGESTION=$(echo "$API_RESPONSE" | jq -r '.choices[0].message.content')
                
                # 檢查解析結果
                if [ "$AI_SUGGESTION" = "null" ] || [ -z "$AI_SUGGESTION" ]; then
                    echo "無法從 API 獲得有效的標題建議："
                    echo "$API_RESPONSE"
                    # 使用預設標題
                    MAIN_COMMIT=$(git log -1 --pretty=%s)
                    if [ -n "$ISSUE_NUM" ]; then
                        AI_SUGGESTION="$TYPE: $MAIN_COMMIT ($ISSUE_NUM)"
                    else
                        AI_SUGGESTION="$TYPE: $MAIN_COMMIT"
                    fi
                    echo "使用預設標題: $AI_SUGGESTION"
                else
                    echo -e "\nAI 建議的標題: $AI_SUGGESTION"
                fi
            fi
        fi
    fi
    
    # 讓使用者選擇是否要手動輸入標題
    echo -e "\n是否要手動輸入PR標題? (y/n)"
    read -r MANUAL_TITLE
    
    if [[ "$MANUAL_TITLE" == "y" ]]; then
        if [ "$HAS_AI" = true ] && [ -n "$AI_SUGGESTION" ]; then
            echo -e "\n請輸入PR標題 (建議格式: $TYPE: 您的標題 $ISSUE_NUM)"
            echo "或按 Enter 使用 AI 建議的標題"
            read -r USER_INPUT
            
            # 如果用戶直接按 Enter，使用 AI 建議的標題
            if [ -z "$USER_INPUT" ]; then
                PR_TITLE="$AI_SUGGESTION"
            else
                PR_TITLE="$USER_INPUT"
            fi
        else
            echo -e "\n請輸入PR標題 (建議格式: $TYPE: 您的標題 $ISSUE_NUM):"
            read -r PR_TITLE
        fi
    else
        if [ -n "$AI_SUGGESTION" ]; then
            PR_TITLE="$AI_SUGGESTION"
        else
            # 使用最新的commit訊息作為主要描述
            MAIN_COMMIT=$(git log -1 --pretty=%s)
            if [ -n "$ISSUE_NUM" ]; then
                PR_TITLE="$TYPE: $MAIN_COMMIT ($ISSUE_NUM)"
            else
                PR_TITLE="$TYPE: $MAIN_COMMIT"
            fi
        fi
    fi

    # 移除重複的標籤前綴
    if [ -n "$PR_TITLE" ]; then
        # 修正 sed 命令的語法
        PR_TITLE=$(echo "$PR_TITLE" | sed -E 's/^(feat|fix|docs|refactor|chore): .*(feat|fix|docs|refactor|chore)\([^)]*\): /\1: /' || echo "$PR_TITLE")
        # 移除重複的表情符號
        PR_TITLE=$(echo "$PR_TITLE" | sed -E 's/^(feat|fix|docs|refactor|chore): [✨🐛📝♻️🔧] /\1: /' || echo "$PR_TITLE")
        
        # 確保標題不為空
        if [ -z "$PR_TITLE" ]; then
            echo "警告：標題處理後為空，使用原始標題"
            if [ -n "$AI_SUGGESTION" ]; then
                PR_TITLE="$AI_SUGGESTION"
            else
                PR_TITLE="$TYPE: $(git log -1 --pretty=%s)"
            fi
        fi
    else
        echo "錯誤：PR標題不能為空"
        exit 1
    fi

    echo "最終PR標題: $PR_TITLE"
    
    # 嘗試從分支名或commit中提取標籤類型
    PR_LABEL=""
    for label_mapping in "${LABEL_CONFIG[@]}"; do
        type="${label_mapping%%:*}"
        label="${label_mapping#*:}"
        if echo "$CURRENT_BRANCH $AUTO_PR_DESCRIPTION" | grep -iq "$type"; then
            PR_LABEL="$label"
            break
        fi
    done

    # 如果沒有找到匹配的標籤，使用預設值
    if [ -z "$PR_LABEL" ]; then
        PR_LABEL="${LABEL_CONFIG[1]#*:}"  # 使用 feature 類型作為預設
    fi
    
    # 設置參數
    PR_DESCRIPTION=""
else
    # 如果提供了參數，則使用提供的參數
    PR_TITLE="${1:-自動PR: $CURRENT_BRANCH}"
    PR_DESCRIPTION="${2:-}"
    TARGET_BRANCH="${3:-$DEFAULT_TARGET_BRANCH}"
    PR_LABEL="${4:-type: feature}"
fi

# 根據標籤確定變更類型
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

# 生成空的PR描述
PR_BODY=""

# 確保本地更改已提交
if [[ -n $(git status --porcelain) ]]; then
    echo "有未提交的更改。是否要提交這些更改? (y/n)"
    read -r COMMIT_CHANGES
    
    if [[ "$COMMIT_CHANGES" == "y" ]]; then
        echo "請輸入提交信息:"
        read -r COMMIT_MSG
        git add .
        git commit -m "$COMMIT_MSG"
    else
        echo "請先提交或儲藏您的更改再繼續"
        exit 1
    fi
fi

# 推送當前分支到遠程
echo "正在推送分支 $CURRENT_BRANCH 到遠程..."
git push -u origin "$CURRENT_BRANCH"

# 創建PR
echo "正在創建PR從 $CURRENT_BRANCH 到 main..."

# 如果提供了標籤，確保標籤存在
if [ -n "$PR_LABEL" ]; then
    # 移除可能的引號
    PR_LABEL=$(echo "$PR_LABEL" | tr -d '"')
    # 確保標籤存在
    ensure_label_exists "$PR_LABEL"
fi

# 準備PR創建命令
PR_CMD="gh pr create --title \"$PR_TITLE\" --body \"$PR_BODY\" --base \"main\" --head \"$CURRENT_BRANCH\""

# 如果提供了標籤，則添加到命令中
if [ -n "$PR_LABEL" ]; then
    PR_CMD="$PR_CMD --label \"$PR_LABEL\""
    echo "將添加標籤: $PR_LABEL"
fi

# 執行PR創建命令
PR_URL=$(eval $PR_CMD)

echo "PR創建完成: $PR_URL"

# 提取PR編號以便後續使用
PR_NUMBER=$(echo $PR_URL | grep -oE '[0-9]+$')
if [ -n "$PR_NUMBER" ]; then
    echo "PR編號: $PR_NUMBER"
fi
