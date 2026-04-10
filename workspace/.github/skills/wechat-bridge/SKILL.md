---
name: wechat-bridge
description: Send and receive WeChat messages via the native WeChat bridge (wechat-bro.js). Supports sending text, reading contacts, and listening for incoming messages through WKWebView injection.
---

# WeChat Bridge Skill

Interface with the native WeChat app on the owner's phone via the injected `wechat-bro.js` bridge.

## Capabilities

### Send Message
Send a text message to a WeChat contact (person or room).

```
Tool: wechat_send_message
Input: { contactId: string, text: string }
Output: { success: boolean, error?: string }
```

Messages sent through this skill are automatically:
- Watermarked with invisible AI Unicode marker (for `isFromAI()` detection)
- Optionally prefixed with 🤖 (Scenario 1 only — Scenario 2 sends without prefix)

### Get Contacts
Fetch the list of available WeChat contacts (rooms + people).

```
Tool: wechat_get_contacts
Input: {}
Output: { contacts: [{ id: string, name: string, isRoom: boolean }] }
```

### Listen for Messages
Register a callback for incoming messages. Messages arrive as:

```
{
  sender: string,       // display name
  senderId: string,     // unique ID
  contactId: string,    // room ID (@@xxx) or person ID (@xxx)
  contactName: string,  // room name or person name
  text: string,         // message text
  timestamp: number,    // unix ms
  isRoom: boolean
}
```

### Get Room Members
Fetch members of a specific room.

```
Tool: wechat_get_room_members
Input: { contactId: string }
Output: { members: [{ id: string, name: string }] }
```

## Implementation

All tools map to JavaScript calls on `wechat-bro.js` injected into WKWebView:
- `sendMessage(contactId, text)` → `wechat_send_message`
- `getContacts()` → `wechat_get_contacts`
- `onMessage(callback)` → listener registration
- `getRoomMembers(contactId)` → `wechat_get_room_members`

## Prerequisites

- WeChat must be logged in on the phone
- Neox WKWebView must have wechat-bro.js loaded
- Bridge connection must be active (check via healthcheck)

## Limitations (v1)

- Text messages only (no images, voice, files)
- Single WeChat account per phone
- Bridge stops when phone sleeps or Neox is killed
