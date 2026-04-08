---
name: wechat-assistant
description: Automate WeChat tasks — auto-reply to messages, extract contact data, set reminders, monitor conversations, and manage the account via WebKitAgent browser automation.
---

# WeChat Assistant

Automate WeChat interactions via WeChat Web using WebKitAgent.

## Prerequisites
- WeChat Web must be logged in (user scans QR code with phone)
- Navigate to `https://wx.qq.com` and take a snapshot to check login status

## Capabilities

### 1. Auto-Reply
Monitor incoming messages and reply automatically:
- Navigate to wx.qq.com
- Snapshot to find new message indicators (look for unread badges)
- Click on conversations with new messages
- Snapshot to read message content
- Type reply into input field and click send

### 2. Get Contacts & Data
Extract contact information:
- Navigate to contacts list
- Snapshot to read contact names
- Click through contacts to get details
- Record data in session memory

### 3. Monitor Conversations
Track specific conversations:
- Watch for keywords or mentions
- Alert user for important messages
- Summarize missed conversations

### 4. Reminders
Set reminders based on messages:
- Parse dates/times from messages
- Create reminder notes in memory
- Alert user at specified time

### 5. Message Management
Organize and search messages:
- Search for specific content
- Find messages from specific contacts
- Summarize conversation threads

## Using web_agent

Navigate to WeChat Web:
```
web-agent navigate url=https://wx.qq.com
```

Check login status (snapshot returns page text + clickable refs):
```
web-agent snapshot
```

If QR code shown, ask user to scan with phone.

Click on a conversation (use ref from snapshot):
```
web-agent click ref=r3
```

Read messages (snapshot after clicking conversation):
```
web-agent snapshot
```

Type a reply:
```
web-agent type ref=r12 text=Hello!
```

Click send button:
```
web-agent click ref=r15
```

Run JavaScript to gather data:
```
web-agent evaluate script=document.querySelectorAll('.chat_item').length
```

## Known Issues
- WeChat Web requires phone to stay online
- QR code login expires periodically
- Some features restricted on web version
- Rate limit: don't send too many messages too fast
- File sharing has size limits on web

## Tips
- Always snapshot before and after each action to verify state
- Don't auto-reply to group chats without user consent
- Keep auto-reply responses natural and varied
- Log all automated actions for user review
- Respect privacy — don't extract data without user awareness
