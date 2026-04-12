---
name: end-to-end tests
description: agent do e2e test alone with following tools
tools: 
    - `agent-browser` control browser discord
    - appagent in neox control app
    - relay server logs
---

# Channel
- c1: exclusive channel 
    - enable wechat Channel
        - assert discord channel disabled
    - enable discord channel
        - assert wechat channel disabled

## Discord
## project assistant
- CD1: Happy path: first time configure
    - condition
        - discord server is not in relay server bot linked server list.
        - project exist
    - enable discord channel
    - As a user, I input discord server id, and enable discord channel
        - wechat channel should be disabled
    - As a user, I go to projects, select  a project, click select channel
        - popup discord channel selector
        - select a channel
        - activate the project
        - back to chat
    - use agent-browser navigate to configured discord channel
        - send message '2+2='
        - assert get message in neox app
        - agent response '4'
            - to discord channel, check in browser
        
        - send message 'read project readme'
        - assert get message in nexo app
        - agent response prject readme content
            - to discord channel, check in browser

- CD2: following CD1: happy path: project setting taking effect after restart
    - stop neox
    - start neox
    - activate AC1 project
    - use agent-browser navigate to configured discord channel
        - send message '2+2='
        - assert get message in neox app
        - agent response '4'
            - to discord channel, check in browser


- CD3: following CD1 || CD2: ask questions can be handled
    - use agent-browser navigate to configured discord channel
        - send message 'ask me a question'
        - agent should ask questions 
        - dispatch questions to channel
        - answer in discord channel
        - answer dispatch to agent
        - agent reponse to discord channel


## wechat

### project assistant

### wechat assistant

