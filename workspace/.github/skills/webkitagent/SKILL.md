---
name: webkitagent
description: Browser automation via web-agent CLI in run_in_terminal. For known sites, use the site-adapter skill instead.
---

# web-agent CLI

Controls a built-in browser via `run_in_terminal`.

```
web-agent navigate <url>        # go to URL
web-agent snapshot              # read page text + refs (r0, r1, ...)
web-agent click <ref>           # click element
web-agent type <ref> <text>     # type into field
web-agent download <ref|url> [filename]
web-agent upload <ref> <path>
web-agent evaluate <js>         # run JavaScript
web-agent screenshot            # capture page image
```

Always `snapshot` after `navigate` or `click` — refs change each time.
