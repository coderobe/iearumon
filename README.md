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
   IEARUMON_COMMAND_SERVER_ID=123456789012345678
   ```

3. Start the bot:

   ```sh
   bundle exec ruby iearumon.rb
   ```

## Behavior

- Automatically transcribes new voice notes by default
- Manual transcription is triggered by reacting with `👂`
- Per-server and DM settings are stored in `iearumon_settings.json`
- Slash command: `/iearumon`

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
