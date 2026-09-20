# MacBook One-Click Audio Transcriber

A lightweight, fully local speech-to-text tool for Apple Silicon Macs.

**Hold `Left Ctrl` → speak → release `Ctrl` → the text is automatically inserted into the current text box.**

It works system-wide in apps such as ChatGPT, Overleaf, browsers, editors, and other text fields.

The project uses **MLX Whisper large-v3-turbo** and runs transcription locally on your Mac after the model is downloaded.

---

## Demo

Hold **Left Ctrl**, speak, then release it.

```text
Ctrl down
   ↓
Recording
   ↓
Ctrl up
   ↓
Transcribing
   ↓
Text appears automatically
```

---

# Installation

## 1. Clone the repository

```bash
cd ~/Downloads

git clone https://github.com/xiangzhang-122/Macbook-one-click-audio-transcriber.git

cd Macbook-one-click-audio-transcriber
```

---

## 2. Install dependencies

You need:

- Apple Silicon Mac (`M1` or later)
- Homebrew
- Hammerspoon
- FFmpeg
- Python 3.12

Install Hammerspoon, FFmpeg, and Python:

```bash
brew install --cask hammerspoon
brew install ffmpeg python@3.12
```

If Homebrew is not installed, install it first from:

https://brew.sh/

---

## 3. Create the MLX Whisper environment

```bash
mkdir -p ~/.venvs

python3.12 -m venv ~/.venvs/mlx-whisper

source ~/.venvs/mlx-whisper/bin/activate
```

Install the Python dependencies:

```bash
pip install --upgrade pip
pip install -r requirements.txt
```

Test the environment:

```bash
python -c "import mlx_whisper, numpy; print('MLX Whisper OK')"
```

You should see:

```text
MLX Whisper OK
```

---

## 4. Install the Hammerspoon files

Create the Hammerspoon config directory:

```bash
mkdir -p ~/.hammerspoon
```

Back up your existing Hammerspoon config if you have one:

```bash
cp ~/.hammerspoon/init.lua ~/.hammerspoon/init.lua.backup 2>/dev/null || true
```

Install the project files:

```bash
cp whisper_daemon.py ~/.hammerspoon/whisper_daemon.py

cp whisper_client.py ~/.hammerspoon/whisper_client.py

cp local_whisper_v9_init.lua ~/.hammerspoon/init.lua
```

Your Hammerspoon directory should now contain:

```text
~/.hammerspoon/
├── init.lua
├── whisper_daemon.py
└── whisper_client.py
```

---

## 5. Find your microphone index

Run:

```bash
ffmpeg -f avfoundation -list_devices true -i ""
```

You should see something like:

```text
[0] ...
[1] MacBook Pro Microphone
```

If your microphone is device `1`, the default configuration is already correct:

```lua
local AUDIO_DEVICE = ":1"
```

If your microphone has another index, edit:

```bash
nano ~/.hammerspoon/init.lua
```

and change:

```lua
local AUDIO_DEVICE = ":1"
```

to the correct value, for example:

```lua
local AUDIO_DEVICE = ":0"
```

---

## 6. Give Hammerspoon macOS permissions

Open:

```text
System Settings
→ Privacy & Security
```

Make sure Hammerspoon has permission for:

- Accessibility
- Input Monitoring
- Microphone

macOS may ask for these permissions the first time you run the tool.

---

## 7. Start Hammerspoon

Open Hammerspoon:

```bash
open -a Hammerspoon
```

Then choose:

```text
Hammerspoon
→ Reload Config
```

You should see:

```text
Local Whisper Dictation V9 Ready
```

The first launch may take longer because Whisper needs to download and warm up the model.

---

# Usage

Put the cursor in any text box.

Then:

1. Hold **Left Ctrl**
2. Wait for the `Recording` indicator
3. Speak
4. Release **Ctrl**
5. Wait for `Transcribing`
6. The text is inserted automatically

A short Ctrl tap does not start recording.

Normal `Ctrl + key` shortcuts remain available.

---

# Check that Whisper is running

Run:

```bash
printf '{"cmd":"ping"}\n' | nc 127.0.0.1 8765
```

A healthy daemon should return something similar to:

```json
{
  "ok": true,
  "status": "ready",
  "model": "mlx-community/whisper-large-v3-turbo"
}
```

---

# Project architecture

The runtime is intentionally simple:

```text
Left Ctrl
   ↓
Hammerspoon
   ↓
FFmpeg records microphone
   ↓
Whisper large-v3-turbo
   ↓
Recognized text
   ↓
Hammerspoon pastes it into the original app
```

The Whisper model stays loaded in memory so each new dictation does not need to reload the model.

Everything runs locally after the model has been downloaded.

---

# Main files

```text
README.md
local_whisper_v9_init.lua
requirements.txt
whisper_daemon.py
whisper_client.py
```

### `local_whisper_v9_init.lua`

Hammerspoon configuration for:

- Ctrl push-to-talk
- recording/transcribing UI
- launching audio recording
- sending audio for transcription
- inserting text back into the current app

### `whisper_daemon.py`

Keeps MLX Whisper loaded in memory and performs local transcription.

Default model:

```text
mlx-community/whisper-large-v3-turbo
```

### `whisper_client.py`

Sends each recorded audio file to the local Whisper daemon.

---

# Useful commands

Activate the Whisper environment:

```bash
source ~/.venvs/mlx-whisper/bin/activate
```

Stop the Whisper daemon:

```bash
pkill -f whisper_daemon.py
```

Check the daemon process:

```bash
pgrep -af whisper_daemon.py
```

View daemon logs:

```bash
tail -f /tmp/local-whisper-daemon.log
```

Reload Hammerspoon after changing the config:

```text
Hammerspoon → Reload Config
```

---

# Troubleshooting

## Recording does not start

Check Hammerspoon permissions:

```text
System Settings
→ Privacy & Security
→ Accessibility / Input Monitoring / Microphone
```

Also verify the microphone index in:

```text
~/.hammerspoon/init.lua
```

---

## Whisper is not ready

Run:

```bash
printf '{"cmd":"ping"}\n' | nc 127.0.0.1 8765
```

If it is not responding:

```bash
tail -100 /tmp/local-whisper-daemon.log
```

Then reload Hammerspoon.

---

## Text appears twice

Make sure another dictation tool is not also using `Ctrl` as its shortcut.

For example, ChatGPT Desktop and this project should not use the same push-to-talk shortcut at the same time.

---

# Privacy

The transcription runs locally on your Mac.

After the Whisper model is downloaded, no cloud speech-to-text API is required.

The local daemon listens only on:

```text
127.0.0.1:8765
```

---

# Model

Default model:

```text
mlx-community/whisper-large-v3-turbo
```

The current configuration is optimized for Chinese speech with English technical terms mixed in.

You can change the model or language settings in:

```text
whisper_daemon.py
```

---

# License

Add your preferred open-source license here, for example MIT.
