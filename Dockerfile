FROM node:22-slim

LABEL description="OpenClaw Multi-Agent for HuggingFace Space"
LABEL version="2026.2.26"

# 1. System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git openssh-client build-essential python3 python3-pip \
    g++ make ca-certificates curl iputils-ping nano \
 && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir huggingface_hub --break-system-packages

# 2. Network optimization
RUN update-ca-certificates && \
    git config --global url."https://github.com/".insteadOf ssh://git@github.com/

# 3. Install dependencies at build time
RUN npm install -g @larksuiteoapi/node-sdk --unsafe-perm && \
    npm install -g openclaw@2026.2.26 --unsafe-perm

# 4. Copy nano-banana-pro skill from local files
COPY skills/nano-banana-pro /home/node/.openclaw/skills/nano-banana-pro
RUN ls -laR /home/node/.openclaw/skills/nano-banana-pro/ && \
    chmod +x /home/node/.openclaw/skills/nano-banana-pro/scripts/generate_image.py && \
    chown -R node:node /home/node/.openclaw/skills

# Install Python dependencies for nano-banana-pro skill
RUN pip3 install --no-cache-dir google-genai pillow --break-system-packages

# Install uv for running Python scripts
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
    mv /root/.local/bin/uv /usr/local/bin/uv && \
    mv /root/.local/bin/uvx /usr/local/bin/uvx 2>/dev/null || true

# 5. Environment configuration
ENV HOME=/home/node

# Create directories
RUN mkdir -p /home/node/.openclaw && \
    chmod 700 /home/node/.openclaw && \
    chown -R node:node /home/node

WORKDIR /home/node

# 6. Sync engine for backup/restore from HF Dataset
RUN cat << 'PYEOF' > /usr/local/bin/sync.py
import os, sys, tarfile
from huggingface_hub import HfApi, hf_hub_download
from datetime import datetime, timedelta

api = HfApi()
repo_id = os.getenv("HF_DATASET")
token = os.getenv("HF_TOKEN")
base = "/home/node/.openclaw"

def restore():
    try:
        if not repo_id:
            return False
        files = api.list_repo_files(repo_id=repo_id, repo_type="dataset", token=token)
        for i in range(5):
            day = (datetime.now() - timedelta(days=i)).strftime("%Y-%m-%d")
            name = f"backup_{day}.tar.gz"
            if name in files:
                print(f"[SYNC] Found backup: {name}, downloading...")
                path = hf_hub_download(repo_id=repo_id, filename=name, repo_type="dataset", token=token)
                os.makedirs(base, exist_ok=True)
                with tarfile.open(path, "r:gz") as tar:
                    tar.extractall(path=base)
                print("[SYNC] Restore Success")
                return True
    except Exception as e:
        print(f"[SYNC] Restore Error: {e}")
    return False

def backup():
    try:
        if not repo_id:
            return
        day = datetime.now().strftime("%Y-%m-%d")
        name = f"backup_{day}.tar.gz"
        print(f"[SYNC] Starting backup to {name}...")
        with tarfile.open(f"/tmp/{name}", "w:gz") as tar:
            # Exclude skills - they should be installed, not backed up
            for target in ["sessions", "workspace", "memory", "plugins", "agents"]:
                full_path = f"{base}/{target}"
                if os.path.exists(full_path):
                    tar.add(full_path, arcname=target)
        api.upload_file(
            path_or_fileobj=f"/tmp/{name}",
            path_in_repo=name,
            repo_id=repo_id,
            repo_type="dataset",
            token=token
        )
        print("[SYNC] Backup Upload Success")
    except Exception as e:
        print(f"[SYNC] Backup Error: {e}")

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "backup":
        backup()
    else:
        restore()
PYEOF
RUN chmod +x /usr/local/bin/sync.py

# 7. Startup script
RUN cat << 'STARTEOF' > /usr/local/bin/start-openclaw
#!/bin/bash
set -e

# Image model with fallback (allow external override)
export IMAGE_MODEL="${IMAGE_MODEL:-imagen-4.0-generate-001}"

BASE="/home/node/.openclaw"

echo "=== OpenClaw Multi-Agent Gateway Starting ==="

# OpenClaw is installed at build time
OPENCLAW_VERSION=$(openclaw --version 2>/dev/null || echo "unknown")
echo "--- OpenClaw Version: ${OPENCLAW_VERSION} ---"

# Restore data from HF Dataset
echo "--- Restoring Data from HF Dataset ---"
python3 /usr/local/bin/sync.py restore || true
find "$BASE" -name "*.lock" -type f -delete 2>/dev/null || true

# Clean environment variables (matching HF Space env.txt)
CLEAN_DISCORD_TOKEN=$(echo "${DISCORD_TOKEN}" | tr -d '\r\n[:space:]"')
RAW_DISCORD_USER=$(echo "${DISCORD_USER_ID}" | tr -d '[:space:]')
CLEAN_FEISHU_APP_ID=$(echo "${FEISHU_APP_ID}" | tr -d '\r\n[:space:]"')
CLEAN_FEISHU_APP_SECRET=$(echo "${FEISHU_APP_SECRET}" | tr -d '\r\n[:space:]"')
# FEISHU_ENCRYPT_KEY is optional - set empty if not provided
CLEAN_FEISHU_ENCRYPT_KEY=$(echo "${FEISHU_ENCRYPT_KEY:-}" | tr -d '\r\n[:space:]"')

# Proxy settings (optional)
export HTTP_PROXY="${HTTP_PROXY:-}"
export HTTPS_PROXY="${HTTPS_PROXY:-}"

# Create directory structure for multi-agent (preserve existing skills)
mkdir -p "$BASE"/{workspace,credentials,canvas,plugins,devices}
mkdir -p "$BASE/agents/assistant"
mkdir -p "$BASE/agents/coder"
mkdir -p "$BASE/agents/designer"

# Ensure skills directory exists with correct permissions
mkdir -p "$BASE/skills"
mkdir -p "$BASE/workspace-designer/skills"
mkdir -p "$BASE/workspace-designer/memory"
mkdir -p "$BASE/workspace-designer/output"

# Copy skill to designer workspace (copy instead of symlink for security compatibility)
rm -rf "$BASE/workspace-designer/skills/nano-banana-pro"
cp -r "$BASE/skills/nano-banana-pro" "$BASE/workspace-designer/skills/nano-banana-pro"
echo "--- Skill copied to designer workspace ---"

# Link designer output to canvas for web access
mkdir -p "$BASE/canvas"
rm -f "$BASE/canvas/output"
ln -sf "$BASE/workspace-designer/output" "$BASE/canvas/output"
echo "--- Designer output linked to canvas ---"

# Verify skill is properly copied
if [ -d "$BASE/workspace-designer/skills/nano-banana-pro" ]; then
  echo "--- Skill copied to designer workspace: OK ---"
else
  echo "--- WARNING: Skill not copied to designer workspace ---"
fi

# Verify nano-banana-pro skill scripts exist
if [ ! -d "$BASE/skills/nano-banana-pro/scripts" ]; then
  echo "[WARNING] nano-banana-pro/scripts not found, image generation may not work"
fi

# Force cleanup old config to avoid conflicts
rm -f "$BASE/openclaw.json"
rm -f "$BASE/openclaw.json.bak"
rm -f "$BASE/credentials.json"

# Note: With auth.mode=none, no device pairing is required

# Create agent workspaces
for agent in assistant coder designer; do
    mkdir -p "$BASE/workspace-$agent"
    mkdir -p "$BASE/agents/$agent/sessions"
done

# ==========================================
# Agent Soul Definitions
# ==========================================

# Agent 1: Assistant (Team Leader)
cat > "$BASE/workspace-assistant/SOUL.md" << 'EOF'
# Identity
You are "Team Leader", the project manager of the AI team.

# Team Members
You have two specialists you can delegate tasks to:
1. **coder** - Expert engineer for writing code
2. **designer** - Expert artist for generating images using nano-banana-pro skill

# How to Delegate
Use the sessions_spawn tool to create tasks for specialists:

1. For coding tasks, use: sessions_spawn with targetAgent="coder"
2. For image generation, use: sessions_spawn with targetAgent="designer"

# Example
User: "Draw a cat"
Action: Use sessions_spawn to create a session for designer with the task.

User: "Write a recursive function"
Action: Use sessions_spawn to create a session for coder with the task.

# Rules
- For coding tasks, delegate to coder
- For image generation tasks, delegate to designer
- For general questions, answer yourself
- Always wait for specialist to complete and report back
EOF

# Assistant AGENTS.md - Operational rules
cat > "$BASE/workspace-assistant/AGENTS.md" << 'EOF'
# Assistant Agent Rules

## Delegation
- Use sessions_spawn to delegate tasks to subagents
- targetAgent="coder" for coding tasks
- targetAgent="designer" for image generation tasks

## Critical Safety Rules
- **NEVER** attempt to restart, stop, or manage the `openclaw gateway` service.
- If a subagent fails to spawn (e.g., pairing error), report the status to the user and ask for authorization if needed.
- Do NOT assume port conflicts require a service restart.

## Workflow
1. Understand user request
2. Delegate to specialist (coder/designer)
3. **WAIT** for the specialist to complete the task. Do NOT try to message the specialist directly to check progress. Wait for the automated report.
4. Report the final result (including images/code) back to the user.
EOF

# Assistant TOOLS.md - Tool documentation
cat > "$BASE/workspace-assistant/TOOLS.md" << 'EOF'
# Available Tools

## sessions_spawn
- Spawn subagent sessions for specialized tasks

## sessions_send
- Send messages to existing subagent sessions

## Other Tools
- read, write, edit, exec, message, etc.
EOF

# Agent 2: Coder (Engineer)
cat > "$BASE/workspace-coder/SOUL.md" << 'EOF'
# Identity
You are "Engineer", the technical expert of the team.

# Skills
You specialize in writing clean, efficient code.

# Rules
- You receive tasks from Team Leader via sessions_send
- Deliver working, well-commented code
- Report completion back to Team Leader
EOF

# Coder AGENTS.md - Operational rules
cat > "$BASE/workspace-coder/AGENTS.md" << 'EOF'
# Coder Agent Rules

## Your Task
Write code when requested by the Team Leader.

## Workflow
1. Receive task from Team Leader via sessions_send
2. Understand requirements
3. Write clean, efficient code
4. Test if possible
5. Report completion
EOF

# Coder TOOLS.md - Tool documentation
cat > "$BASE/workspace-coder/TOOLS.md" << 'EOF'
# Available Tools

## Code Tools
- write: Write code files
- edit: Edit existing code
- exec: Run commands

## Other Tools
- read, message, etc.
EOF

# Agent 3: Designer (Creator with image generation skill)
cat > "$BASE/workspace-designer/SOUL.md" << 'EOF'
# Identity
You are "Creator", the visual artist with nano-banana-pro skill for image generation.

# Available Skills
You have access to the **nano-banana-pro** skill for generating images using Google Gemini.

# How to Generate Images
When asked to generate an image:

1. Look for the nano-banana-pro skill in your available tools
2. Use the skill with a clear prompt describing the image
3. The skill will generate and return the image
4. **IMPORTANT**: If generation fails, the script will output an error image. Always use the provided output path.

# Example prompts
- "A cute cat sitting on a windowsill"
- "A futuristic city at sunset"
- "Abstract art with blue and gold colors"

# Rules
- Always try to use nano-banana-pro skill for image requests
- Provide detailed, creative prompts
- Report the result back to the user
EOF

# Setup external URL for Canvas (HARDCODED for stability)
EXTERNAL_URL="https://tianmingyun999-openclaw.hf.space"
echo "--- EXTERNAL_URL set to: $EXTERNAL_URL ---"

# Designer AGENTS.md - Operational rules (subagent can see this)
cat > "$BASE/workspace-designer/AGENTS.md" << EOF
# Designer Agent Rules

## Your Task
Generate images using the nano-banana-pro skill when requested.

## How to Generate Images (IMPORTANT!)
Use exec tool to run the generate_image.py script directly:

1. When user requests an image, use exec tool to run:
\`\`\`
uv run /home/node/.openclaw/skills/nano-banana-pro/scripts/generate_image.py --prompt "your image description" --filename "output/output.png" --resolution 1K
\`\`\`

2. The image will be generated at /home/node/.openclaw/workspace-designer/output/output.png

3. **To send the image to the user**, you MUST follow these 3 steps:
   
   a. **Copy to allowed media directory** (for upload):
      \`\`\`
      cp /home/node/.openclaw/workspace-designer/output/output.png /tmp/output.png
      \`\`\`
      
   b. **Copy to canvas directory** (for public URL):
      \`\`\`
      cp /home/node/.openclaw/workspace-designer/output/output.png /home/node/.openclaw/canvas/output/output.png
      \`\`\`

   c. **Send message with BOTH media and URL**:
      \`\`\`
      message channel=feishu target=<user_id> message="Here is your image. Link: ${EXTERNAL_URL}/__openclaw__/canvas/output/output.png" media=/tmp/output.png
      \`\`\`
   
   IMPORTANT: 
   - You MUST copy to /tmp/ first (for upload)
   - You MUST copy to /home/node/.openclaw/canvas/output/ (for URL link)
   - Use BOTH media parameter AND the URL in the message text
   - Do NOT use Markdown image links (![image](url))

## Example
User: "Draw a cat"
Action:
1. Run script (saving to output/output.png).
2. Wait for completion.
3. Copy to /tmp: cp /home/node/.openclaw/workspace-designer/output/output.png /tmp/output.png
4. Copy to canvas: cp /home/node/.openclaw/workspace-designer/output/output.png /home/node/.openclaw/canvas/output/output.png
5. Send: message channel=feishu target=<user_id> message="Image generated. Link: ${EXTERNAL_URL}/__openclaw__/canvas/output/output.png" media=/tmp/output.png
EOF

# Designer TOOLS.md - Tool documentation (subagent can see this)
cat > "$BASE/workspace-designer/TOOLS.md" << 'EOF'
# Available Tools

## Image Generation
Use exec tool to run the image generation script:
```
uv run /home/node/.openclaw/skills/nano-banana-pro/scripts/generate_image.py --prompt "描述" --filename "output/output.png" --resolution 1K
```

## Other Available Tools
- read: Read files
- write: Write files  
- edit: Edit files
- exec: Execute commands
- message: Send messages
EOF

# ==========================================
# Network Configuration
# ==========================================
export NODE_OPTIONS="--dns-result-order=ipv4first --no-warnings"
export no_proxy="localhost,127.0.0.1,::1,feishu.cn,open.feishu.cn,larksuite.com"

# Gateway authentication - required for lan binding
# Token must match between config and CLI
GATEWAY_TOKEN="openclaw-hf-space-token-2026"
export OPENCLAW_GATEWAY_TOKEN="$GATEWAY_TOKEN"

# Critical: Set environment for OpenClaw
export OPENCLAW_HOME="$BASE"
export OPENCLAW_CONFIG_PATH="$BASE/openclaw.json"

# Default model fallback
export MODEL="${MODEL:-gemini-2.0-flash}"

# Image generation model for nano-banana-pro skill
export IMAGE_MODEL="${IMAGE_MODEL:-imagen-4.0-generate-001}"

# Logging configuration - output to stdout for HF Space
export OPENCLAW_LOG_LEVEL="${OPENCLAW_LOG_LEVEL:-info}"
export OPENCLAW_CONSOLE_STYLE="pretty"

# ==========================================
# Generate OpenClaw Configuration
# ==========================================
echo "--- Generating Configuration ---"

cat > "$BASE/openclaw.json" << JSONEOF
{
  "logging": {
    "level": "debug",
    "consoleLevel": "debug",
    "consoleStyle": "pretty",
    "redactSensitive": "tools"
  },
  "session": {
    "dmScope": "per-channel-peer"
  },
  "models": {
    "providers": {
      "google": {
        "baseUrl": "https://generativelanguage.googleapis.com/v1beta",
        "apiKey": "${GEMINI_API_KEY}",
        "models": [
          { "id": "${MODEL}", "name": "Primary Model" }
        ]
      }
    }
  },
  "skills": {
    "allowBundled": ["gemini", "nano-banana-pro"],
    "load": {
      "extraDirs": ["$BASE/skills"]
    },
    "entries": {
      "nano-banana-pro": {
        "enabled": true,
        "apiKey": "${GEMINI_API_KEY}",
        "env": {
          "GEMINI_API_KEY": "${GEMINI_API_KEY}",
          "IMAGE_MODEL": "${IMAGE_MODEL:-imagen-4.0-generate-001}"
        }
      }
    }
  },
    "tools": {
    "agentToAgent": {
      "enabled": true,
      "allow": ["assistant", "coder", "designer"]
    },
    "allow": ["exec", "read", "write", "edit", "process", "bash", "sessions_spawn", "sessions_send", "sessions_list", "message"],
    "deny": ["gateway", "cron"],
    "elevated": {
      "enabled": true,
      "allowFrom": {
        "discord": ["*"],
        "feishu": ["*"]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "google/${MODEL}"
      },
      "elevatedDefault": "on"
    },
    "list": [
      {
        "id": "assistant",
        "name": "Team Leader",
        "default": true,
        "workspace": "$BASE/workspace-assistant",
        "agentDir": "$BASE/agents/assistant",
        "identity": {
          "name": "Team Leader",
          "theme": "project manager",
          "emoji": "🧠"
        },
        "groupChat": {
          "mentionPatterns": ["@assistant", "@Team Leader", "@总指挥"]
        },
        "subagents": {
          "allowAgents": ["coder", "designer"]
        }
      },
      {
        "id": "coder",
        "name": "Engineer",
        "workspace": "$BASE/workspace-coder",
        "agentDir": "$BASE/agents/coder",
        "identity": {
          "name": "Engineer",
          "theme": "expert coder",
          "emoji": "💻"
        },
        "groupChat": {
          "mentionPatterns": ["@coder", "@Engineer", "@工程师", "@Coder"]
        },
        "subagents": {
          "allowAgents": ["assistant"]
        }
      },
      {
        "id": "designer",
        "name": "Creator",
        "workspace": "$BASE/workspace-designer",
        "agentDir": "$BASE/agents/designer",
        "skills": ["nano-banana-pro"],
        "identity": {
          "name": "Creator",
          "theme": "visual artist",
          "emoji": "🎨"
        },
        "groupChat": {
          "mentionPatterns": ["@designer", "@Creator", "@创作官", "@Designer"]
        },
        "subagents": {
          "allowAgents": ["assistant"]
        }
      }
    ]
  },
  "channels": {
    "feishu": {
      "enabled": true,
      "dmPolicy": "open",
      "groupPolicy": "open",
      "allowFrom": ["*"],
      "accounts": {
        "main": {
          "appId": "${CLEAN_FEISHU_APP_ID}",
          "appSecret": "${CLEAN_FEISHU_APP_SECRET}",
          "botName": "OpenClaw AI",
          "encryptKey": "${CLEAN_FEISHU_ENCRYPT_KEY}"
        }
      }
    },
    "discord": {
      "enabled": true,
      "dmPolicy": "open",
      "groupPolicy": "open",
      "allowFrom": ["*"],
      "replyToMode": "off",
      "accounts": {
        "default": {
          "token": "${CLEAN_DISCORD_TOKEN}",
          "dm": { "enabled": true },
          "guilds": {
            "*": { "requireMention": false }
          },
          "actions": {
            "reactions": true,
            "messages": true
          }
        }
      }
    }
  },
  "bindings": [
    {
      "agentId": "assistant",
      "match": { "channel": "feishu", "accountId": "main" }
    },
    {
      "agentId": "assistant",
      "match": { "channel": "discord", "accountId": "default" }
    }
  ],
"gateway": {
    "mode": "local",
    "port": 7860,
    "bind": "custom",
    "customBindHost": "0.0.0.0",
    "trustedProxies": ["10.0.0.0/8"],
    "auth": {
      "mode": "token",
      "token": "openclaw-hf-space-token-2026",
      "rateLimit": {
        "maxAttempts": 10,
        "windowMs": 60000,
        "lockoutMs": 300000,
        "exemptLoopback": true
      }
    },
    "controlUi": {
      "enabled": true,
      "allowInsecureAuth": true,
      "dangerouslyDisableDeviceAuth": true,
      "dangerouslyAllowHostHeaderOriginFallback": true
    },
    "tools": {
      "deny": ["gateway"]
    }
  }
}
JSONEOF

# ==========================================
# Generate Credentials
# ==========================================
cat > "$BASE/credentials.json" << CREDEOF
{
  "channels": {
    "feishu": {
      "accounts": {
        "main": {
          "appId": "${CLEAN_FEISHU_APP_ID}",
          "appSecret": "${CLEAN_FEISHU_APP_SECRET}",
          "encryptKey": "${CLEAN_FEISHU_ENCRYPT_KEY}"
        }
      }
    },
    "discord": {
      "token": "${CLEAN_DISCORD_TOKEN}"
    }
  }
}
CREDEOF

# Set ownership
chown -R node:node /home/node/.openclaw

# Create .env file with gateway token for remote access
cat > "$BASE/.env" << ENVEOF
OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}
ENVEOF
chown node:node "$BASE/.env"

# Initial backup
python3 /usr/local/bin/sync.py backup || true

# Start periodic backup (every 3 hours)
(while true; do sleep 10800; python3 /usr/local/bin/sync.py backup || true; done) &

# ==========================================
# Start Gateway
# ==========================================
cd "$BASE"

echo "--- Starting OpenClaw Gateway on port 7860 ---"
echo "--- Gateway Bind: custom (0.0.0.0) ---"
echo "--- Gateway Auth: token ---"
echo "--- controlUi: allowInsecureAuth=true, dangerouslyDisableDeviceAuth=true ---"
echo "--- Agent-to-Agent: enabled ---"
echo "--- Tools denied: gateway ---"
echo "--- Elevated Mode: enabled for all users ---"
echo "--- Model: ${MODEL} ---"
echo "--- Skills directory: $BASE/skills ---"
echo "--- Designer workspace: $BASE/workspace-designer ---"
if [ -d "$BASE/skills/nano-banana-pro" ]; then
  echo "--- nano-banana-pro skill: installed ---"
  ls -la "$BASE/skills/nano-banana-pro/"
else
  echo "--- WARNING: nano-banana-pro skill NOT found ---"
fi
if [ -d "$BASE/workspace-designer/skills/nano-banana-pro" ]; then
  echo "--- Skill copied to designer workspace: OK ---"
else
  echo "--- WARNING: Skill not copied to designer workspace ---"
fi

# ==========================================
# Dynamic Configuration (Runtime)
# ==========================================

# Setup external URL for Canvas
# Note: SPACE_HOST is not used to avoid config errors. URL is hardcoded.
EXTERNAL_URL="https://tianmingyun999-openclaw.hf.space"
echo "--- EXTERNAL_URL set to: $EXTERNAL_URL ---"

echo "--- Generating Runtime Designer Configuration ---"
cat > "$BASE/workspace-designer/AGENTS.md" << AGENTEOF
# Designer Agent Rules

## Your Task
Generate images using the nano-banana-pro skill when requested.

## Model Information
- **Skill**: nano-banana-pro
- **Model**: ${IMAGE_MODEL:-imagen-4.0-generate-001}
- **Type**: Image Generation Model (Text-to-Image)

## Prompting Guide
- Use clear, descriptive prompts in English.
- Focus on visual elements, style, lighting, and composition.
- Avoid conversational filler; be direct.

## How to Generate Images (IMPORTANT!)
Use exec tool to run the generate_image.py script directly:

1. When user requests an image, use exec tool to run:
\`\`\`
uv run /home/node/.openclaw/skills/nano-banana-pro/scripts/generate_image.py --prompt "your image description" --filename "output/output.png" --resolution 1K
\`\`\`

2. The image will be generated at /home/node/.openclaw/workspace-designer/output/output.png

3. **To send the image to the user**, you MUST follow these 3 steps:
   
   a. **Copy to allowed media directory** (for upload):
      \`\`\`
      cp /home/node/.openclaw/workspace-designer/output/output.png /tmp/output.png
      \`\`\`
      
   b. **Copy to canvas directory** (for public URL):
      \`\`\`
      cp /home/node/.openclaw/workspace-designer/output/output.png /home/node/.openclaw/canvas/output/output.png
      \`\`\`

   c. **Send message with BOTH media and URL**:
      \`\`\`
      message channel=feishu target=<user_id> message="Here is your image. Link: ${EXTERNAL_URL}/__openclaw__/canvas/output/output.png" media=/tmp/output.png
      \`\`\`
   
   IMPORTANT: 
   - You MUST copy to /tmp/ first (for upload)
   - You MUST copy to /home/node/.openclaw/canvas/output/ (for URL link)
   - Use BOTH media parameter AND the URL in the message text
   - Do NOT use Markdown image links (![image](url))

## Example
User: "Draw a cat"
Action:
1. Run script (saving to output/output.png).
2. Wait for completion.
3. Copy to /tmp: cp /home/node/.openclaw/workspace-designer/output/output.png /tmp/output.png
4. Copy to canvas: cp /home/node/.openclaw/workspace-designer/output/output.png /home/node/.openclaw/canvas/output/output.png
5. Send: message channel=feishu target=<user_id> message="Image generated. Link: ${EXTERNAL_URL}/__openclaw__/canvas/output/output.png" media=/tmp/output.png
AGENTEOF

# Verbose mode for detailed logging
VERBOSE_FLAG=""
if [ "${OPENCLAW_VERBOSE:-false}" = "true" ]; then
  VERBOSE_FLAG="--verbose"
  echo "--- Verbose mode enabled ---"
fi

# Kill any existing gateway process on port 7860 to avoid port conflicts
echo "--- Checking for existing gateway processes ---"
pkill -f "openclaw gateway" 2>/dev/null || true
sleep 1

# OpenClaw: use custom bind to 0.0.0.0 for HF Space
# Version is auto-updated to latest at runtime
exec openclaw gateway run --port 7860 --allow-unconfigured --token "$GATEWAY_TOKEN" ${VERBOSE_FLAG}
STARTEOF

RUN chmod +x /usr/local/bin/start-openclaw

# Final ownership
RUN chown -R node:node /home/node

# Switch to non-root user
USER 1000
WORKDIR /home/node

# HuggingFace Space uses port 7860
EXPOSE 7860

# Start OpenClaw
CMD ["/usr/local/bin/start-openclaw"]
