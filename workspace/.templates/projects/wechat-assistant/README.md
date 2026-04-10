# WeChat Assistant

Auto-reply to WeChat messages on behalf of the account owner.

# goal
Act as the owner in WeChat conversations — reply naturally based on persona, rules, and contact context.

# behavior
- Read `context.md` for persona, rules, and per-contact instructions
- Match the language the contact writes in
- Keep replies brief (under 3 sentences unless explaining something technical)
- Follow guardrails strictly — escalate to owner when triggered

# onboarding
1. Edit `context.md` — set your persona, tone, and behavior rules
2. Add per-contact instructions in `contacts/` (one file per contact or room)
3. Wire contacts in Neox → WeChat settings

# human-must
| When | What |
|------|------|
| Setup | Write context.md with persona and guardrails |
| Per contact | Add contact-specific instructions |
| Escalation | Approve/reject flagged replies via push notification |

# daily-assist
- Review conversation logs for quality
- Update context.md if persona or rules change

# references
- **context.md**: persona, behavior rules, guardrails
- **contacts/**: per-contact context files
- **docs/**: design docs, notes
- **progress/**: conversation logs, reports