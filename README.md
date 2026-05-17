# iearumon

Discord bot that transcribes Discord voice notes with a local Whisper CLI.

## Requirements

- Ruby with Bundler
- `ffmpeg`
- A local `whisper` CLI in `PATH`, or a custom command via `WHISPER_COMMAND`
- A Discord bot token with message content intent enabled

## Setup

1. Install gems:

   ```sh
   bundle install
   ```

2. Create an environment file with the required settings:

   ```sh
   DISCORD_BOT_TOKEN=your_bot_token
   WHISPER_MODEL=base
   ```

   Optional settings:

   ```sh
   WHISPER_COMMAND=whisper
   WHISPER_LANGUAGE=en
   IEARUMON_MAX_WHISPER_MODEL=large
   IEARUMON_MIN_WHISPER_MODEL=tiny
   IEARUMON_DM_ENABLED=false
   IEARUMON_COMMAND_SERVER_ID=123456789012345678
   ```

3. Start the bot:

   ```sh
   bundle exec ruby iearumon.rb
   ```

## Behavior

- Automatically transcribes new `voice-message.ogg` voice-note attachments by default
- Longer transcriptions stream into a single in-progress reply that is edited conservatively until the final text is ready
- DMs are controlled globally with `IEARUMON_DM_ENABLED` and are disabled by default
- Manual transcription is triggered by reacting with `👂`
- Reacting with the configured upgrade retry emoji set (default: `?`, `❓`, `❔`) on one of the bot's transcription replies retries that voice note with the next larger Whisper model, up to `IEARUMON_MAX_WHISPER_MODEL`
- Reacting with `⁉️` on one of the bot's transcription replies retries that voice note with the next smaller Whisper model, down to `IEARUMON_MIN_WHISPER_MODEL`
- Per-server transcription totals and per-scope settings are stored in `iearumon_settings.json`
- Server-wide `/iearumon listen` and `/iearumon emoji` changes require the Discord `Manage Server` permission
- `/iearumon emoji` can change the manual trigger emoji, configure or toggle the upgrade retry emoji set, or target the downgrade retry emoji and enable or disable that retry path per scope
- Slash commands: `/iearumon status`, `/iearumon listen`, `/iearumon emoji`

## Optional safety tuning

These defaults are intentionally generous so normal voice notes are not rejected, but they still keep the bot host bounded under load:

```sh
IEARUMON_TRANSCRIPTION_WORKERS=2
IEARUMON_TRANSCRIPTION_QUEUE_LIMIT=24
IEARUMON_TRANSCRIPTION_TIMEOUT=1800
IEARUMON_MAX_AUDIO_BYTES=67108864
IEARUMON_DOWNLOAD_OPEN_TIMEOUT=15
IEARUMON_DOWNLOAD_READ_TIMEOUT=300
IEARUMON_PROGRESS_PREVIEW_WORDS=5
IEARUMON_PROGRESS_UPDATE_INTERVAL=5
```

## systemd

Use `iearumon.service` as a starting point, then:

1. Create a dedicated service account:

   ```sh
   sudo useradd --system --home /opt/iearumon --shell /usr/sbin/nologin iearumon
   ```

2. Copy the repo to a fixed path such as `/opt/iearumon`, then make it writable by that account because the bot stores `iearumon_settings.json` beside the script:

   ```sh
   sudo chown -R iearumon:iearumon /opt/iearumon
   ```

3. Put secrets in `/etc/iearumon/iearumon.env`
4. Install the unit to `/etc/systemd/system/iearumon.service`
5. Run:

   ```sh
   sudo systemctl daemon-reload
   sudo systemctl enable --now iearumon.service
   ```
