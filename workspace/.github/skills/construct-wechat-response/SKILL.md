---
name: construct-wechat-response
description: "Format responses for WeChat messages. Use when composing a reply that will be sent through WeChat — covers emoji codes, @mentions in rooms, and WeChat text formatting rules."
---

# Construct WeChat Response

Use this skill when composing a message that will be sent through WeChat.

## Emoji

WeChat uses shortcode-style emoji. Wrap the shortcode in square brackets:

### Common Emoji
| Code | Meaning |
|------|---------|
| [微笑] | Smile |
| [呲牙] | Grin |
| [偷笑] | Chuckle |
| [得意] | Smug |
| [流泪] | Crying |
| [害羞] | Shy |
| [发呆] | Dazed |
| [调皮] | Playful |
| [惊讶] | Surprised |
| [难过] | Sad |
| [酷] | Cool |
| [大哭] | Sobbing |
| [尴尬] | Awkward |
| [发怒] | Angry |
| [可爱] | Cute |
| [白眼] | Eye roll |
| [憨笑] | Sheepish |
| [坏笑] | Smirk |
| [亲亲] | Kiss |
| [可怜] | Pitiful |

### Gestures & Objects
| Code | Meaning |
|------|---------|
| [强] | Thumbs up |
| [弱] | Thumbs down |
| [握手] | Handshake |
| [胜利] | Victory |
| [抱拳] | Fist salute |
| [拳头] | Fist |
| [OK] | OK |
| [爱心] | Heart |
| [心碎] | Broken heart |
| [玫瑰] | Rose |
| [太阳] | Sun |
| [月亮] | Moon |
| [礼物] | Gift |
| [咖啡] | Coffee |
| [蛋糕] | Cake |
| [啤酒] | Beer |
| [红包] | Red envelope |
| [拥抱] | Hug |
| [嘿哈] | Hey ha |
| [捂脸] | Facepalm |
| [奸笑] | Sly |
| [机智] | Clever |
| [皱眉] | Frown |
| [耶] | Yeah |

### English Alternatives
[Smile] [Grin] [Strong] [Heart] [OK]

### Usage Rules
- Use naturally, like punctuation: "好的[微笑]" or "收到[OK]"
- Don't overuse — 1-2 emoji per message max
- Match the tone — use [微笑] for friendly, [强] for encouragement

## @Mentions (Rooms Only)

In group chats, use @Name to mention someone:
```
@张三 你看一下这个
```

Rules:
- Only use @mention in **room** messages, never in 1:1
- Don't @mention the sender back unless necessary
- Use when directing a question or task to a specific person

## Text Formatting

WeChat has limited formatting support. Keep it simple:
- **No markdown** — no bold, italic, headers, or code blocks
- Use line breaks for structure
- Use Chinese punctuation when replying in Chinese
- Keep responses concise — WeChat is a chat app, not a document viewer
- Under 3 sentences for casual replies
- Use numbered lists (1. 2. 3.) for structured content

## Language Matching

Always reply in the same language as the incoming message:
- Chinese message → Chinese reply
- English message → English reply
- Mixed → follow the dominant language
