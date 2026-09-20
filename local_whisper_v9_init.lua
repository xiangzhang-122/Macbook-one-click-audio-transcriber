----------------------------------------------------------------
-- System-wide Local Whisper Dictation V9
-- (GC-safe + repeat-safe + dual-pulse HUD + self-healing reconciler)
--
-- Reliability design:
--   1) Persistent Hammerspoon objects are retained by the global
--      LocalWhisperDictation runtime table so Lua GC cannot silently
--      collect the eventtap/timers/tasks after init.lua finishes.
--   2) The dictation state returns to IDLE *before* UI paste work.
--   3) Normal keyboard events remain the fast path.
--   4) A 100 ms state reconciler compares internal state with physical Ctrl
--      and task reality, recovering missed Ctrl-UP events and stale states.
--   5) Critical repeating timers use continueOnError=true.
--
-- Hold LEFT Control > 250 ms:
--     start microphone recording
--
-- Release LEFT Control:
--     stop recording -> persistent Whisper daemon -> paste text
--
-- Ctrl + another key:
--     remains a normal Ctrl shortcut
----------------------------------------------------------------

--------------------------
-- Configuration
--------------------------

local HOME = os.getenv("HOME")

local LEFT_CTRL = 59
local HOLD_TIME = 0.25

-- Self-healing state reconciliation.
-- Poll every 100 ms. Normal Ctrl events are still handled immediately.
local STATE_RECONCILE_INTERVAL = 0.10
local CTRL_RELEASE_CONFIRM_TICKS = 2      -- ~200 ms
local STALE_TASK_CONFIRM_TICKS = 5        -- ~500 ms

-- AVFoundation device:
-- [1] MacBook Pro Microphone
local AUDIO_DEVICE = ":1"

local FFMPEG = "/opt/homebrew/bin/ffmpeg"

local WHISPER_PYTHON =
    HOME .. "/.venvs/mlx-whisper/bin/python"

local WHISPER_DAEMON =
    HOME .. "/.hammerspoon/whisper_daemon.py"

local WHISPER_CLIENT =
    HOME .. "/.hammerspoon/whisper_client.py"

local AUDIO_FILE =
    "/tmp/hammerspoon_dictation.wav"

local DAEMON_HOST = "127.0.0.1"
local DAEMON_PORT = 8765

--------------------------
-- Persistent runtime / GC safety
--------------------------

-- Hammerspoon's init.lua is a scope that ends after the file is evaluated.
-- Long-lived objects must therefore have a global strong reference.
--
-- On a V9 -> V9 reload, stop old watchers/timers/HUD first so we do not
-- accumulate duplicate callbacks. Do NOT terminate the persistent Whisper
-- daemon here; the new config will reuse it if port 8765 is already alive.

local previousRuntime =
    rawget(_G, "LocalWhisperDictation")

if previousRuntime then
    local function safeStop(obj)
        if not obj then
            return
        end

        pcall(function()
            obj:stop()
        end)
    end

    safeStop(previousRuntime.watcher)
    safeStop(previousRuntime.stateReconciler)
    safeStop(previousRuntime.eventtapWatchdog)
    safeStop(previousRuntime.pulseTimer)
    safeStop(previousRuntime.holdTimer)
    safeStop(previousRuntime.readyTimer)
    safeStop(previousRuntime.clipboardRestoreTimer)
    safeStop(previousRuntime.pasteFocusTimer)
    safeStop(previousRuntime.pasteKeyTimer)

    -- If the old V9 was reloaded while actively recording, ask ffmpeg to
    -- finalize rather than leaving an orphaned microphone process.
    if previousRuntime.recordTask then
        pcall(function()
            if previousRuntime.recordTask:isRunning() then
                previousRuntime.recordTask:interrupt()
            end
        end)
    end

    if previousRuntime.hud then
        pcall(function()
            previousRuntime.hud:hide()
        end)
    end
end

LocalWhisperDictation = {}
local Runtime = LocalWhisperDictation

Runtime.version = "V9"

local function retain(name, obj)
    Runtime[name] = obj
    return obj
end

local function release(name, obj)
    if obj == nil
        or Runtime[name] == obj then

        Runtime[name] = nil
    end
end

--------------------------
-- State
--------------------------

local state = "idle"
-- idle | pending | recording | stopping | transcribing

local ctrlDown = false
local holdTimer = nil
local ctrlReleaseMissTicks = 0
local staleTaskTicks = 0

local recordTask = nil
local transcriptionTask = nil
local whisperDaemonTask = nil

local shouldTranscribe = false

local originApp = nil
local originWindow = nil

local clipboardBackup = nil
local clipboardRestoreTimer = nil

--------------------------
-- Lightweight HUD + pulse animation
--------------------------

-- One small reusable canvas plus ONE low-frequency timer while recording.
-- No waveform sampling, no audio-level processing, no per-frame allocations
-- beyond tiny canvas property updates.

local hud = nil
local pulseTimer = nil
local pulsePhase = 0.0
local pulseMode = "recording"

-- 12.5 FPS is enough for soft motion while keeping CPU use tiny.
local PULSE_INTERVAL = 0.08
local RECORDING_PULSE_PERIOD = 1.35
local TRANSCRIBING_PULSE_PERIOD = 0.95

local function hudFrame()
    local screen = nil

    if originWindow then
        screen = originWindow:screen()
    end

    if not screen then
        screen = hs.screen.mainScreen()
    end

    local f = screen:frame()
    local w = 246
    local h = 60

    return {
        x = f.x + (f.w - w) / 2,
        y = f.y + 18,
        w = w,
        h = h
    }
end

local function ensureHUD()
    if hud then
        return hud
    end

    hud = hs.canvas.new(hudFrame())
    retain("hud", hud)

    hud:level(hs.canvas.windowLevels.overlay)
    hud:clickActivating(false)

    -- 1: glass-like rounded background
    hud[1] = {
        type = "rectangle",
        action = "strokeAndFill",
        frame = { x = 0, y = 0, w = "100%", h = "100%" },
        roundedRectRadii = { xRadius = 16, yRadius = 16 },
        fillColor = { white = 0.065, alpha = 0.93 },
        strokeColor = { white = 1.0, alpha = 0.13 },
        strokeWidth = 1.0,
        withShadow = true,
        shadow = {
            blurRadius = 14,
            color = { white = 0.0, alpha = 0.34 },
            offset = { h = 4, w = 0 }
        }
    }

    -- 2/3: pulse rings. Hidden unless recording.
    hud[2] = {
        type = "circle",
        action = "stroke",
        center = { x = 25, y = 30 },
        radius = 7,
        strokeWidth = 2.0,
        strokeColor = {
            red = 1.0, green = 0.12, blue = 0.12, alpha = 0.0
        }
    }

    hud[3] = {
        type = "circle",
        action = "stroke",
        center = { x = 25, y = 30 },
        radius = 7,
        strokeWidth = 1.5,
        strokeColor = {
            red = 1.0, green = 0.18, blue = 0.18, alpha = 0.0
        }
    }

    -- 4: solid center status dot
    hud[4] = {
        type = "circle",
        action = "fill",
        center = { x = 25, y = 30 },
        radius = 5.5,
        fillColor = {
            red = 1.0, green = 0.20, blue = 0.20, alpha = 1.0
        }
    }

    -- 5: microphone glyph
    hud[5] = {
        type = "text",
        text = "🎙",
        textSize = 21,
        textColor = { white = 1.0, alpha = 1.0 },
        frame = { x = 41, y = 14, w = 32, h = 32 },
        textAlignment = "center"
    }

    -- 6: main status
    hud[6] = {
        type = "text",
        text = "Recording",
        textSize = 15,
        textColor = { white = 1.0, alpha = 0.98 },
        frame = { x = 79, y = 8, w = 150, h = 25 },
        textAlignment = "left"
    }

    -- 7: subtitle
    hud[7] = {
        type = "text",
        text = "HOLD CTRL • LOCAL WHISPER",
        textSize = 9.5,
        textColor = { white = 1.0, alpha = 0.52 },
        frame = { x = 80, y = 32, w = 150, h = 18 },
        textAlignment = "left"
    }

    hud:hide()
    return hud
end

local function setPulseRing(index, phase)
    local c = ensureHUD()

    -- Recording: wider, slower red ripple.
    -- Transcribing: slightly tighter, faster amber/gold ripple.
    local radius = 7.0
    local alpha = 0.0
    local red = 1.0
    local green = 0.12
    local blue = 0.12

    if pulseMode == "transcribing" then
        radius = 7.0 + 12.0 * phase
        alpha = 0.30 * (1.0 - phase) * (1.0 - phase)
        green = 0.52 + 0.18 * phase
        blue = 0.08 + 0.08 * phase
    else
        radius = 7.0 + 14.0 * phase
        alpha = 0.34 * (1.0 - phase) * (1.0 - phase)
        green = 0.10 + 0.08 * phase
        blue = 0.10 + 0.08 * phase
    end

    c[index].radius = radius
    c[index].strokeColor = {
        red = red,
        green = green,
        blue = blue,
        alpha = alpha
    }
end

local function stopPulseAnimation()
    if pulseTimer then
        pulseTimer:stop()
        release("pulseTimer", pulseTimer)
        pulseTimer = nil
    end

    if hud then
        hud[2].strokeColor = {
            red = 1.0, green = 0.12, blue = 0.12, alpha = 0.0
        }
        hud[3].strokeColor = {
            red = 1.0, green = 0.18, blue = 0.18, alpha = 0.0
        }
    end
end

local function startPulseAnimation(mode)
    stopPulseAnimation()

    pulseMode = mode or "recording"
    pulsePhase = 0.0

    -- Draw once immediately so the HUD does not wait for the first timer tick.
    setPulseRing(2, 0.0)
    setPulseRing(3, 0.5)

    pulseTimer = hs.timer.doEvery(
        PULSE_INTERVAL,
        function()
            local period =
                (pulseMode == "transcribing")
                and TRANSCRIBING_PULSE_PERIOD
                or RECORDING_PULSE_PERIOD

            pulsePhase =
                (pulsePhase + PULSE_INTERVAL / period) % 1.0

            -- Two waves half a period apart.
            local p1 = pulsePhase
            local p2 = (pulsePhase + 0.5) % 1.0

            setPulseRing(2, p1)
            setPulseRing(3, p2)
        end
    )

    retain("pulseTimer", pulseTimer)
end

local function showRecordingHUD()
    local c = ensureHUD()
    c:frame(hudFrame())

    c[4].fillColor = {
        red = 1.0, green = 0.18, blue = 0.18, alpha = 1.0
    }
    c[5].text = "🎙"
    c[6].text = "Recording"
    c[7].text = "HOLD CTRL • LOCAL WHISPER"

    c:show()
    startPulseAnimation("recording")
end

local function showTranscribingHUD()
    local c = ensureHUD()
    c:frame(hudFrame())

    c[4].fillColor = {
        red = 1.0, green = 0.64, blue = 0.14, alpha = 1.0
    }
    c[5].text = "✦"
    c[6].text = "Transcribing…"
    c[7].text = "MLX • LARGE-V3-TURBO"

    c:show()
    startPulseAnimation("transcribing")
end

local function hideHUD()
    stopPulseAnimation()

    if hud then
        hud:hide()
    end
end

--------------------------
-- Logging / state helpers
--------------------------

local function log(msg)
    print(string.format(
        "[LocalWhisper] %s | state=%s | ctrl=%s",
        msg,
        state,
        tostring(ctrlDown)
    ))
end

local function setState(newState, reason)
    local old = state
    state = newState
    staleTaskTicks = 0

    print(string.format(
        "[LocalWhisper] %s -> %s%s",
        old,
        newState,
        reason and (" | " .. reason) or ""
    ))
end

local function fileExists(path)
    return hs.fs.attributes(path) ~= nil
end

local function daemonIsUp()
    local cmd = string.format(
        "/usr/bin/nc -z %s %d >/dev/null 2>&1",
        DAEMON_HOST,
        DAEMON_PORT
    )

    local _, status = hs.execute(cmd, false)
    return status == true
end

--------------------------
-- Clipboard helpers
--------------------------

local function backupClipboard()
    clipboardBackup = hs.pasteboard.readAllData()
end

local function restoreClipboard()
    if clipboardBackup then
        hs.pasteboard.writeAllData(clipboardBackup)
    else
        hs.pasteboard.clearContents()
    end

    clipboardBackup = nil

    release("clipboardRestoreTimer", clipboardRestoreTimer)
    clipboardRestoreTimer = nil
end

--------------------------
-- Dictation-state reset / recovery
--------------------------

local function resetDictationState(reason)

    hideHUD()

    if holdTimer then
        holdTimer:stop()
        release("holdTimer", holdTimer)
        holdTimer = nil
    end

    release("recordTask", recordTask)
    release("transcriptionTask", transcriptionTask)

    recordTask = nil
    transcriptionTask = nil
    shouldTranscribe = false
    ctrlReleaseMissTicks = 0
    staleTaskTicks = 0

    setState("idle", reason or "reset")
end

local function recoverStaleState()

    -- If a callback completed but an earlier UI/timer error prevented state
    -- cleanup, make the next Ctrl press self-healing.

    if state == "stopping" then
        local running =
            recordTask
            and recordTask:isRunning()

        if not running then
            log("recovering stale STOPPING state")
            resetDictationState("stale stopping recovery")
        end
    end

    if state == "transcribing" then
        local running =
            transcriptionTask
            and transcriptionTask:isRunning()

        if not running then
            log("recovering stale TRANSCRIBING state")
            resetDictationState("stale transcription recovery")
        end
    end

    if state == "pending"
        and holdTimer == nil then

        log("recovering stale PENDING state")
        resetDictationState("stale pending recovery")
    end
end

--------------------------
-- Persistent daemon
--------------------------

local function startWhisperDaemon()

    if daemonIsUp() then
        log("Whisper daemon already running")
        return
    end

    if not fileExists(WHISPER_PYTHON) then
        hs.alert.show(
            "Whisper Python not found:\n" .. WHISPER_PYTHON,
            nil,
            5
        )
        return
    end

    if not fileExists(WHISPER_DAEMON) then
        hs.alert.show(
            "Whisper daemon not found:\n" .. WHISPER_DAEMON,
            nil,
            5
        )
        return
    end

    whisperDaemonTask = hs.task.new(
        WHISPER_PYTHON,

        function(exitCode, stdOut, stdErr)

            print("[LocalWhisper] daemon exited:", exitCode)

            if stdOut and stdOut ~= "" then
                print(stdOut)
            end

            if stdErr and stdErr ~= "" then
                print(stdErr)
            end

            release("whisperDaemonTask", whisperDaemonTask)
            whisperDaemonTask = nil
        end,

        {
            WHISPER_DAEMON
        }
    )

    if not whisperDaemonTask then
        hs.alert.show("Could not create Whisper daemon", nil, 4)
        return
    end

    retain("whisperDaemonTask", whisperDaemonTask)

    if not whisperDaemonTask:start() then
        hs.alert.show("Could not start Whisper daemon", nil, 4)
        release("whisperDaemonTask", whisperDaemonTask)
        whisperDaemonTask = nil
        return
    end

    hs.alert.show("Whisper warming up…", nil, 0.8)

    -- Warm-up time varies. Poll readiness instead of assuming 3 s is enough.
    local attempts = 0
    local readyTimer

    readyTimer = hs.timer.doEvery(0.5, function()

        attempts = attempts + 1

        if daemonIsUp() then
            readyTimer:stop()
            release("readyTimer", readyTimer)
            hs.alert.show("Whisper ready", nil, 0.6)
            log("daemon ready")
            return
        end

        if attempts >= 30 then
            readyTimer:stop()
            release("readyTimer", readyTimer)
            print(
                "[LocalWhisper] daemon did not become ready; " ..
                "check /tmp/local-whisper-daemon.log"
            )
        end
    end)

    retain("readyTimer", readyTimer)
end

--------------------------
-- Save destination
--------------------------

local function saveOrigin()

    originApp =
        hs.application.frontmostApplication()

    originWindow =
        hs.window.focusedWindow()

    return originApp ~= nil
end

--------------------------
-- Paste result
--------------------------

local function pasteIntoOrigin(text)

    if not text
        or text:match("^%s*$") then

        hs.alert.show(
            "Whisper returned empty text",
            nil,
            3
        )

        return
    end

    backupClipboard()

    hs.pasteboard.setContents(text)

    if originApp then
        originApp:activate()
    end

    Runtime.pasteFocusTimer =
        hs.timer.doAfter(0.06, function()

            Runtime.pasteFocusTimer = nil

            if originWindow then
                originWindow:focus()
            end

            Runtime.pasteKeyTimer =
                hs.timer.doAfter(0.06, function()

                    Runtime.pasteKeyTimer = nil

                    -- IMPORTANT:
            -- state is already IDLE before we reach this UI operation.
            -- Even if paste/focus raises an error, the next Ctrl press works.
            local ok, err = pcall(function()
                hs.eventtap.keyStroke(
                    {"cmd"},
                    "v",
                    0
                )
            end)

            if not ok then
                print(
                    "[LocalWhisper] paste error:",
                    tostring(err)
                )
            end

                    if clipboardRestoreTimer then
                        clipboardRestoreTimer:stop()
                        release(
                            "clipboardRestoreTimer",
                            clipboardRestoreTimer
                        )
                    end

                    clipboardRestoreTimer =
                        hs.timer.doAfter(
                            0.50,
                            restoreClipboard
                        )

                    retain(
                        "clipboardRestoreTimer",
                        clipboardRestoreTimer
                    )
                end)
        end)
end

--------------------------
-- Transcription
--------------------------

local function transcribeAudio()

    setState(
        "transcribing",
        "ffmpeg finalized WAV"
    )

    if not daemonIsUp() then

        hs.alert.show(
            "Whisper daemon is not ready",
            nil,
            3
        )

        startWhisperDaemon()
        resetDictationState("daemon unavailable")
        return
    end

    if not fileExists(WHISPER_CLIENT) then

        hs.alert.show(
            "Whisper client not found:\n"
                .. WHISPER_CLIENT,
            nil,
            5
        )

        resetDictationState("client missing")
        return
    end

    transcriptionTask = hs.task.new(
        WHISPER_PYTHON,

        function(exitCode, stdOut, stdErr)

            -- Mark task complete first.
            release("transcriptionTask", transcriptionTask)
            transcriptionTask = nil

            if stdErr
                and stdErr ~= "" then
                print(stdErr)
            end

            if exitCode ~= 0 then

                print(
                    "===== Whisper client failed ====="
                )

                print(stdErr or "")

                resetDictationState(
                    "client error"
                )

                hs.alert.show(
                    "Whisper failed — see Console",
                    nil,
                    4
                )

                return
            end

            local text =
                (stdOut or "")
                :match("^%s*(.-)%s*$")

            if not text
                or text == "" then

                resetDictationState(
                    "empty transcript"
                )

                hs.alert.show(
                    "Whisper returned empty text",
                    nil,
                    3
                )

                return
            end

            print(
                "[LocalWhisper] DICTATION:",
                text
            )

            ------------------------------------------------
            -- CRITICAL REPEAT-SAFETY FIX:
            --
            -- Return to IDLE *before* focus/paste timers.
            -- The old V2 returned to IDLE only inside a later
            -- UI timer. If that path stalled/errored, the state
            -- remained "transcribing" forever and the second
            -- Ctrl press appeared dead.
            ------------------------------------------------

            resetDictationState(
                "transcription complete"
            )

            pasteIntoOrigin(text)
        end,

        {
            WHISPER_CLIENT,
            AUDIO_FILE
        }
    )

    if transcriptionTask then
        retain("transcriptionTask", transcriptionTask)
    end

    if not transcriptionTask
        or not transcriptionTask:start() then

        release("transcriptionTask", transcriptionTask)

        resetDictationState(
            "could not start client"
        )

        hs.alert.show(
            "Could not start Whisper client",
            nil,
            4
        )
    end
end

--------------------------
-- Recording
--------------------------

local function startRecording()

    if state ~= "pending"
        or not ctrlDown then

        return
    end

    if not saveOrigin() then
        resetDictationState(
            "could not save origin"
        )
        return
    end

    if not daemonIsUp() then

        hs.alert.show(
            "Whisper is warming up",
            nil,
            2
        )

        startWhisperDaemon()

        resetDictationState(
            "daemon not ready"
        )

        return
    end

    if not fileExists(FFMPEG) then

        hs.alert.show(
            "ffmpeg not found:\n" .. FFMPEG,
            nil,
            5
        )

        resetDictationState(
            "ffmpeg missing"
        )

        return
    end

    os.remove(AUDIO_FILE)

    shouldTranscribe = true

    setState(
        "recording",
        "microphone started"
    )

    recordTask = hs.task.new(
        FFMPEG,

        function(exitCode, stdOut, stdErr)

            local doTranscribe =
                shouldTranscribe

            release("recordTask", recordTask)
            recordTask = nil

            if not doTranscribe then

                resetDictationState(
                    "recording cancelled"
                )

                return
            end

            if not fileExists(AUDIO_FILE) then

                print(
                    "===== ffmpeg recording error ====="
                )

                print(stdErr or "")

                resetDictationState(
                    "audio file missing"
                )

                hs.alert.show(
                    "Recording failed — see Console",
                    nil,
                    4
                )

                return
            end

            transcribeAudio()
        end,

        {
            "-hide_banner",
            "-loglevel", "error",
            "-y",

            "-f", "avfoundation",
            "-i", AUDIO_DEVICE,

            "-ac", "1",
            "-ar", "16000",
            "-c:a", "pcm_s16le",

            AUDIO_FILE
        }
    )

    if recordTask then
        retain("recordTask", recordTask)
    end

    if not recordTask
        or not recordTask:start() then

        release("recordTask", recordTask)

        resetDictationState(
            "could not start ffmpeg"
        )

        hs.alert.show(
            "Could not start microphone",
            nil,
            4
        )

        return
    end

    showRecordingHUD()
end

local function stopRecordingAndTranscribe(reason)

    if state ~= "recording"
        or not recordTask then

        return
    end

    ctrlReleaseMissTicks = 0

    showTranscribingHUD()

    setState(
        "stopping",
        reason or "Ctrl released"
    )

    shouldTranscribe = true

    -- SIGINT lets ffmpeg finalize WAV correctly.
    recordTask:interrupt()
end

--------------------------
-- Preserve normal Ctrl shortcuts
--------------------------

local function cancelForNormalCtrlShortcut()

    if state == "pending" then

        if holdTimer then
            holdTimer:stop()
            release("holdTimer", holdTimer)
            holdTimer = nil
        end

        setState(
            "idle",
            "normal Ctrl shortcut"
        )

        return
    end

    if state == "recording"
        and recordTask then

        hideHUD()
        shouldTranscribe = false

        setState(
            "stopping",
            "recording cancelled for shortcut"
        )

        recordTask:interrupt()
    end
end

--------------------------
-- Keyboard watcher
--------------------------

local watcher = hs.eventtap.new(
    {
        hs.eventtap.event.types.flagsChanged,
        hs.eventtap.event.types.keyDown
    },

    function(event)

        local eventType =
            event:getType()

        local keyCode =
            event:getKeyCode()

        --------------------------------------------
        -- Modifier changes
        --------------------------------------------

        if eventType
            == hs.eventtap.event.types.flagsChanged then

            local flags =
                event:getFlags()

            ----------------------------------------
            -- LEFT CONTROL
            ----------------------------------------

            if keyCode == LEFT_CTRL then

                if flags.ctrl then

                    -- Ctrl DOWN
                    ctrlDown = true
                    ctrlReleaseMissTicks = 0

                    recoverStaleState()

                    log("Ctrl DOWN")

                    if state == "idle" then

                        setState(
                            "pending",
                            "waiting for hold threshold"
                        )

                        holdTimer =
                            hs.timer.doAfter(
                                HOLD_TIME,
                                function()

                                    -- Once fired, it is no longer a pending timer.
                                    release("holdTimer", holdTimer)
                                    holdTimer = nil

                                    startRecording()
                                end
                            )

                        retain("holdTimer", holdTimer)
                    end

                else

                    -- Ctrl UP
                    ctrlDown = false
                    ctrlReleaseMissTicks = 0

                    log("Ctrl UP")

                    if holdTimer then
                        holdTimer:stop()
                        release("holdTimer", holdTimer)
                        holdTimer = nil
                    end

                    if state == "pending" then

                        setState(
                            "idle",
                            "short Ctrl tap"
                        )

                    elseif state == "recording" then

                        stopRecordingAndTranscribe()
                    end
                end

                -- Preserve the physical Control modifier.
                return false
            end

            ----------------------------------------
            -- Another modifier while Ctrl is held
            ----------------------------------------

            if ctrlDown
                and (
                    state == "pending"
                    or state == "recording"
                ) then

                cancelForNormalCtrlShortcut()
            end

            return false
        end

        --------------------------------------------
        -- Ordinary key while Ctrl is held
        --------------------------------------------

        if eventType
            == hs.eventtap.event.types.keyDown then

            if ctrlDown
                and (
                    state == "pending"
                    or state == "recording"
                ) then

                cancelForNormalCtrlShortcut()
            end

            return false
        end

        return false
    end
)

retain("watcher", watcher)

--------------------------
-- Self-healing state reconciler
--------------------------

-- This is deliberately a fallback, not the normal control path.
-- Keyboard flagsChanged events still start/stop dictation immediately.
--
-- The reconciler protects against four failure classes:
--
--   PENDING:
--       Ctrl is physically up, but the release event was missed.
--
--   RECORDING:
--       Ctrl is physically up, but stopRecordingAndTranscribe() never ran.
--
--   STOPPING:
--       ffmpeg is no longer running, but its completion callback failed
--       to advance the state.
--
--   TRANSCRIBING:
--       the client task is no longer running, but its completion callback
--       failed to return the state to IDLE.
--
-- This makes a single lost event/callback recoverable instead of poisoning
-- every later dictation attempt.

local function taskIsRunning(task)
    if not task then
        return false
    end

    local ok, running =
        pcall(function()
            return task:isRunning()
        end)

    return ok and running == true
end

local function physicalCtrlIsDown()
    local modifiers =
        hs.eventtap.checkKeyboardModifiers()

    return modifiers
        and modifiers.ctrl == true
end

local stateReconciler =
    hs.timer.new(
        STATE_RECONCILE_INTERVAL,
        function()

            local physicalCtrlDown =
                physicalCtrlIsDown()

            ------------------------------------------------
            -- IDLE: synchronize bookkeeping and do nothing.
            ------------------------------------------------
            if state == "idle" then
                ctrlReleaseMissTicks = 0
                staleTaskTicks = 0

                if not physicalCtrlDown then
                    ctrlDown = false
                end

                return
            end

            ------------------------------------------------
            -- PENDING / RECORDING:
            -- independently verify whether Ctrl is still held.
            ------------------------------------------------
            if state == "pending"
                or state == "recording" then

                if physicalCtrlDown then
                    ctrlDown = true
                    ctrlReleaseMissTicks = 0
                else
                    ctrlReleaseMissTicks =
                        ctrlReleaseMissTicks + 1
                end
            else
                ctrlReleaseMissTicks = 0

                if not physicalCtrlDown then
                    ctrlDown = false
                end
            end

            ------------------------------------------------
            -- PENDING recovery
            ------------------------------------------------
            if state == "pending" then

                -- A pending state without a timer cannot make progress.
                if holdTimer == nil then
                    log(
                        "RECONCILER recovered stale PENDING without timer"
                    )

                    ctrlDown = physicalCtrlDown

                    resetDictationState(
                        "reconciler: stale pending"
                    )

                    return
                end

                if ctrlReleaseMissTicks
                    >= CTRL_RELEASE_CONFIRM_TICKS then

                    ctrlReleaseMissTicks = 0
                    ctrlDown = false

                    if holdTimer then
                        holdTimer:stop()
                        release("holdTimer", holdTimer)
                        holdTimer = nil
                    end

                    log(
                        "RECONCILER recovered missed Ctrl UP while pending"
                    )

                    setState(
                        "idle",
                        "reconciler: physical Ctrl released"
                    )
                end

                return
            end

            ------------------------------------------------
            -- RECORDING recovery
            ------------------------------------------------
            if state == "recording" then

                -- If the task vanished/stopped without its callback moving
                -- the state forward, reset instead of leaving future Ctrl
                -- presses permanently blocked.
                if not taskIsRunning(recordTask) then
                    staleTaskTicks =
                        staleTaskTicks + 1

                    if staleTaskTicks
                        >= STALE_TASK_CONFIRM_TICKS then

                        log(
                            "RECONCILER recovered stale RECORDING task"
                        )

                        resetDictationState(
                            "reconciler: recording task not running"
                        )
                    end

                    return
                end

                staleTaskTicks = 0

                if ctrlReleaseMissTicks
                    >= CTRL_RELEASE_CONFIRM_TICKS then

                    ctrlReleaseMissTicks = 0
                    ctrlDown = false

                    log(
                        "RECONCILER recovered missed Ctrl UP while recording"
                    )

                    stopRecordingAndTranscribe(
                        "reconciler: physical Ctrl released"
                    )
                end

                return
            end

            ------------------------------------------------
            -- STOPPING recovery
            ------------------------------------------------
            if state == "stopping" then

                if taskIsRunning(recordTask) then
                    staleTaskTicks = 0
                    return
                end

                staleTaskTicks =
                    staleTaskTicks + 1

                if staleTaskTicks
                    < STALE_TASK_CONFIRM_TICKS then
                    return
                end

                staleTaskTicks = 0

                -- If this was a deliberate cancellation, simply recover.
                if not shouldTranscribe then
                    log(
                        "RECONCILER recovered completed cancelled recording"
                    )

                    resetDictationState(
                        "reconciler: cancelled recording stopped"
                    )

                    return
                end

                -- ffmpeg has stopped. If WAV exists, advance to transcription
                -- rather than silently discarding a valid recording.
                if fileExists(AUDIO_FILE) then
                    log(
                        "RECONCILER advancing stale STOPPING to transcription"
                    )

                    release("recordTask", recordTask)
                    recordTask = nil
                    transcribeAudio()
                else
                    log(
                        "RECONCILER recovered STOPPING without audio file"
                    )

                    resetDictationState(
                        "reconciler: stopped without audio"
                    )
                end

                return
            end

            ------------------------------------------------
            -- TRANSCRIBING recovery
            ------------------------------------------------
            if state == "transcribing" then

                if taskIsRunning(transcriptionTask) then
                    staleTaskTicks = 0
                    return
                end

                staleTaskTicks =
                    staleTaskTicks + 1

                if staleTaskTicks
                    >= STALE_TASK_CONFIRM_TICKS then

                    log(
                        "RECONCILER recovered stale TRANSCRIBING state"
                    )

                    resetDictationState(
                        "reconciler: transcription task not running"
                    )

                    hs.alert.show(
                        "Recovered stalled transcription",
                        nil,
                        2
                    )
                end

                return
            end

            ------------------------------------------------
            -- Unknown/corrupted state
            ------------------------------------------------
            log(
                "RECONCILER found unknown state: "
                    .. tostring(state)
            )

            resetDictationState(
                "reconciler: unknown state"
            )
        end,
        true
    ):start()

retain("stateReconciler", stateReconciler)

--------------------------
-- Eventtap watchdog
--------------------------

local watchdog =
    hs.timer.new(
        5.0,
        function()

            if not watcher:isEnabled() then
                print(
                    "[LocalWhisper] eventtap disabled; restarting"
                )

                watcher:start()
            end
        end,
        true
    ):start()

retain("eventtapWatchdog", watchdog)

--------------------------
-- Runtime diagnostics
--------------------------

Runtime.snapshot = function()
    return {
        version = Runtime.version,
        state = state,
        ctrlDown = ctrlDown,
        physicalCtrl =
            hs.eventtap.checkKeyboardModifiers().ctrl == true,
        watcherEnabled =
            watcher and watcher:isEnabled() or false,
        reconcilerRunning =
            stateReconciler
            and stateReconciler:running()
            or false,
        eventtapWatchdogRunning =
            watchdog
            and watchdog:running()
            or false,
        recordingTaskRunning =
            recordTask
            and recordTask:isRunning()
            or false,
        transcriptionTaskRunning =
            transcriptionTask
            and transcriptionTask:isRunning()
            or false
    }
end

--------------------------
-- Startup
--------------------------

watcher:start()

startWhisperDaemon()

hs.alert.show(
    "Local Whisper Dictation V9 Ready",
    nil,
    1
)
