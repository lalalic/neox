# goal
Automate WeChat management — auto-reply messages, monitor conversations, manage contacts, and schedule content.

# feature
- [ ] Auto-reply rules for common messages
- [ ] Contact group management
- [ ] Conversation monitoring and alerts
- [ ] Scheduled message sending
- [ ] Chat history analysis
- [ ] Reminder and follow-up automation

# strategy
Use wechat-assistant skill with WebKitAgent browser automation to manage WeChat Web, set rules in docs/, track activity in progress/.

# implementation phrases
- [ ] Set up WeChat Web access
- [ ] Configure auto-reply rules
- [ ] Set up monitoring
- [ ] Build contact management
- [ ] Automate scheduling

# onboarding
问用户:
1. 自动回复哪些群/联系人？
2. 关注什么关键词？
3. 哪些消息需要人工处理？

# human-must
| When | What |
|------|------|
| 首次 | 扫码登录微信 |
| 首次 | 定义自动回复规则 |
| 每天 | 查看自动回复日志 |
| 需要时 | 亲自处理复杂对话 |

# daily-assist
- 早："昨晚N条新消息。X条自动回复。Y条需要你回复。"
- 总结未读消息

# references
- **rules/**: auto-reply rules and templates
- **contacts/**: contact groups and notes
- **docs/**: WeChat tips, automation guides
- **progress/**: activity logs, interaction stats
