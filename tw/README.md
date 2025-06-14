# PR Pilot

利用自動化腳本和 AI 工具簡化 GitHub PR 的建立流程，使用了 Gemini Code Assist 和 create_pr.sh 與 gemini_finder.sh 腳本，自動產生 PR 描述，並將其翻譯成中文(或保留英文)，從而提升工作效率並減少手動操作的繁瑣。

[English Documentation](../README.md) 

## 詳細說明

[詳細說明](https://muki.tw/pr-pilot/)

## 功能

- 自動檢查當前分支和相關 commit，處理未提交的更改 (會提醒使用者有未 commit 的檔案)
- 整合 Open AI API ，根據 commits 產生建議的 PR 標題
- 自動判斷 PR 類型 (feature、fix、docs... 等)
- 自動產生或指定標籤
- 自動抓取 Gemini Code Assist 產生的英文摘要
- 自動更新 PR Description

## 前置需求

- 安裝 [Gemini Code Assist](https://github.com/apps/gemini-code-assist)
- 登錄 GitHub CLI (`gh auth login`)
- OpenAI API Key（可選，用於 AI 標題建議）
- Google API Key（可選，用於 Gemini 翻譯）

## 安裝

1. clone 此儲存庫
   ```bash
   git clone https://github.com/mukiwu/pr-pilot.git
   ```

2. 使腳本可執行
   ```bash
   chmod +x create_pr.sh gemini_finder.sh
   ```

3. 設置 API Key（可選）
   ```bash
   echo 'export OPENAI_API_KEY="你的 OpenAI API Key"' >> ~/.zshrc
   echo 'export GEMINI_API_KEY="你的 Gemini API Key"' >> ~/.zshrc
   ```

   也可以使用 [pass](https://www.passwordstore.org/) 載入：
   ```bash
   export OPENAI_API_KEY=$(pass openai/key)
   export GEMINI_API_KEY=$(pass gemini/key)
   ```

## 使用方法

### 創建 PR

```bash
./create_pr.sh
```

### 使用 Gemini 審查摘要更新 PR

```bash
./gemini_finder.sh [PR編號]
```

選項：
- PR 編號：要更新的 PR 編號

## 貢獻

歡迎提交問題和改進建議！

## 授權

MIT 授權
