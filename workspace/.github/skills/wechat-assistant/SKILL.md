---
name: wechat-assistant
description: Automate WeChat tasks — auto-reply to messages, extract contact data, set reminders, monitor conversations, and manage the account via WebKitAgent browser automation.
---

# WeChat Assistant

Automate WeChat interactions via web.wechat.com or WeChat desktop using WebKitAgent.

## Prerequisites
- WeChat Web must be logged in (scan QR code)
- Use `web_agent` to navigate to `https://wx.qq.com`

## Capabilities

### 1. Auto-Reply
Monitor incoming messages and reply automatically:
- Navigate to wx.qq.com
- Watch for new message indicators
- Read message content
- Generate contextual reply
- Send via input field

### 2. Get Contacts & Data
Extract contact information:
- Navigate to contacts list
- Scroll through and collect names
- Extract group member lists
- Export to structured format

### 3. Monitor Conversations
Track specific conversations:
- Watch for keywords or mentions
- Alert user for important messages
- Summarize missed conversations

### 4. Reminders
Set reminders based on messages:
- Parse dates/times from messages
- Create reminder notes
- Alert user at specified time

### 5. Message Management
Organize and search messages:
- Search for specific content
- Find messages from specific contacts
- Summarize conversation threads

## Using web_agent

Navigate to WeChat Web:
```
web_agent navigate "https://wx.qq.com"
```

Check login status:
```
web_agent snapshot
```

If QR code shown, ask user to scan with phone.

Read messages:
```
web_agent eval "document.querySelectorAll('.chat_item')"
```

Send message:
```
web_agent fill ".edit_area" "Hello!"
web_agent click ".btn_send"
```

## Known Issues
- WeChat Web requires phone to stay online
- QR code login expires periodically
- Some features restricted on web version
- Rate limit: don't send too many messages too fast
- File sharing has size limits on web

## Tips
- Always verify login status before operations
- Don't auto-reply to group chats without user consent
- Keep auto-reply responses natural and varied
- Log all automated actions for user review
- Respect privacy — don't extract data without user awareness
