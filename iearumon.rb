#!/usr/bin/env bundle exec ruby
# frozen_string_literal: true

require "discordrb"
require "json"
require "open-uri"
require "open3"
require "shellwords"
require "set"
require "socket"
require "tempfile"
require "tmpdir"

module Iearumon
  class ConfigurationError < StandardError; end
  class TranscriptionError < StandardError; end

  MESSAGE_CONTENT_INTENT = 1 << 15
  DEFAULT_WHISPER_COMMAND = "whisper"
  DEFAULT_WHISPER_MODEL = "base"
  DEFAULT_COMMAND_PREFIX = "!iearumon"
  EAR_EMOJI = "👂"
  SETTINGS_PATH = File.expand_path("iearumon_settings.json", __dir__)
  TRANSCRIPTION_DEDUP_TTL = 300
  DEFAULT_SETTINGS = {
    "auto_listen" => true,
    "reaction_emoji" => EAR_EMOJI
  }.freeze

  @settings_mutex = Mutex.new
  @transcription_mutex = Mutex.new
  @messages_in_progress = Set.new
  @recent_transcriptions = {}

  module_function

  def run
    Thread.report_on_exception = true

    bot = Discordrb::Bot.new(
      token: discord_token,
      ignore_bots: true,
      intents: discord_intents
    )

    bot.ready do |_event|
      bot.debug("iearumon is online and listening for voice notes")
    end

    bot.message do |event|
      begin
        if command_message?(event.message)
          handle_command(event.message)
          next
        end

        next unless auto_listen_enabled?(event.message)
        next unless voice_note_message?(event.message)

        enqueue_transcription(bot, event.message)
      rescue ConfigurationError => e
        bot.debug("message handling failed: #{e.class}: #{e.message}")
        reply_with_chunks(event.message, e.message)
      end
    end

    bot.reaction_add do |event|
      begin
        next if bot_user?(event.user)
        next unless voice_note_message?(event.message)
        next unless reaction_matches?(event.emoji, reaction_emoji_for(event.message))

        enqueue_transcription(bot, event.message)
      rescue ConfigurationError => e
        bot.debug("reaction handling failed: #{e.class}: #{e.message}")
        reply_with_chunks(event.message, e.message)
      end
    end

    bot.run
  end

  def discord_token
    ENV.fetch("DISCORD_BOT_TOKEN")
  rescue KeyError
    raise ConfigurationError, "Set DISCORD_BOT_TOKEN before starting iearumon."
  end

  def discord_intents
    Discordrb::INTENTS.fetch(:server_messages) |
      Discordrb::INTENTS.fetch(:server_message_reactions) |
      Discordrb::INTENTS.fetch(:direct_messages) |
      Discordrb::INTENTS.fetch(:direct_message_reactions) |
      MESSAGE_CONTENT_INTENT
  end

  def handle_voice_note(message)
    attachment = voice_note_attachment(message)
    raise TranscriptionError, "No voice note attachment was found." unless attachment

    message.react(reaction_emoji_for(message))

    transcript = with_downloaded_attachment(attachment) do |path|
      transcribe(path)
    end

    reply_with_chunks(message, "Transcription:\n#{transcript}")
  end

  def enqueue_transcription(bot, message)
    return unless reserve_transcription(message.id)

    Thread.new do
      handle_voice_note(message)
      mark_transcription_complete(message.id)
    rescue ConfigurationError, TranscriptionError, OpenURI::HTTPError, SocketError => e
      clear_transcription_reservation(message.id)
      bot.debug("voice note transcription failed: #{e.class}: #{e.message}")
      reply_with_chunks(message, "I couldn't transcribe that voice note: #{e.message}")
    end
  end

  def reserve_transcription(message_id)
    @transcription_mutex.synchronize do
      prune_recent_transcriptions!
      return false if @messages_in_progress.include?(message_id)
      return false if @recent_transcriptions.key?(message_id)

      @messages_in_progress << message_id
      true
    end
  end

  def mark_transcription_complete(message_id)
    @transcription_mutex.synchronize do
      @messages_in_progress.delete(message_id)
      @recent_transcriptions[message_id] = Time.now.to_i
    end
  end

  def clear_transcription_reservation(message_id)
    @transcription_mutex.synchronize do
      @messages_in_progress.delete(message_id)
      @recent_transcriptions.delete(message_id)
    end
  end

  def prune_recent_transcriptions!
    cutoff = Time.now.to_i - TRANSCRIPTION_DEDUP_TTL
    @recent_transcriptions.delete_if { |_message_id, timestamp| timestamp < cutoff }
  end

  def command_message?(message)
    message.content.to_s.strip.start_with?(command_prefix)
  end

  def handle_command(message)
    command = message.content.to_s.strip.delete_prefix(command_prefix).strip
    args = command.split(/\s+/, 3)

    case args[0]&.downcase
    when nil, "", "help"
      reply_with_chunks(message, help_text(message))
    when "status"
      reply_with_chunks(message, status_text(message))
    when "listen"
      handle_listen_command(message, args[1])
    when "emoji"
      handle_emoji_command(message, args[1..].compact.join(" ").strip)
    else
      reply_with_chunks(message, "Unknown command.\n\n#{help_text(message)}")
    end
  end

  def handle_listen_command(message, value)
    enabled =
      case value&.downcase
      when "on", "enable", "enabled", "true"
        true
      when "off", "disable", "disabled", "false"
        false
      end

    unless [true, false].include?(enabled)
      reply_with_chunks(message, "Usage: `#{command_prefix} listen on` or `#{command_prefix} listen off`")
      return
    end

    settings = update_settings_for(message) do |current|
      current.merge("auto_listen" => enabled)
    end

    reply_with_chunks(
      message,
      "Automatic listening is now **#{settings.fetch("auto_listen") ? "enabled" : "disabled"}** for #{settings_scope_label(message)}."
    )
  end

  def handle_emoji_command(message, emoji)
    if emoji.nil? || emoji.empty?
      reply_with_chunks(message, "Usage: `#{command_prefix} emoji #{reaction_emoji_for(message)}`")
      return
    end

    settings = update_settings_for(message) do |current|
      current.merge("reaction_emoji" => emoji)
    end

    reply_with_chunks(
      message,
      "Reaction emoji set to #{settings.fetch("reaction_emoji")} for #{settings_scope_label(message)}."
    )
  end

  def help_text(message)
    <<~TEXT.strip
      Commands:
      `#{command_prefix} status` — show the current settings for #{settings_scope_label(message)}.
      `#{command_prefix} listen on` — automatically transcribe new voice notes.
      `#{command_prefix} listen off` — stop automatically transcribing new voice notes.
      `#{command_prefix} emoji #{reaction_emoji_for(message)}` — set the reaction emoji used by the bot.

      Manual trigger: react to a voice note with #{reaction_emoji_for(message)} and I'll transcribe it.
    TEXT
  end

  def status_text(message)
    settings = settings_for(message)

    <<~TEXT.strip
      Settings for #{settings_scope_label(message)}:
      Auto listening: **#{settings.fetch("auto_listen") ? "on" : "off"}**
      Reaction emoji: #{settings.fetch("reaction_emoji")}

      Manual trigger: react to a voice note with #{settings.fetch("reaction_emoji")}.
    TEXT
  end

  def command_prefix
    ENV.fetch("IEARUMON_COMMAND_PREFIX", DEFAULT_COMMAND_PREFIX)
  end

  def auto_listen_enabled?(message)
    settings_for(message).fetch("auto_listen")
  end

  def reaction_emoji_for(message)
    settings_for(message).fetch("reaction_emoji")
  end

  def settings_for(message)
    @settings_mutex.synchronize do
      stored_settings = read_settings.fetch(settings_scope_key(message), {})
      DEFAULT_SETTINGS.merge(stored_settings)
    end
  end

  def update_settings_for(message)
    @settings_mutex.synchronize do
      settings = read_settings
      key = settings_scope_key(message)
      current = DEFAULT_SETTINGS.merge(settings.fetch(key, {}))
      updated = yield current
      settings[key] = updated
      write_settings(settings)
      updated
    end
  end

  def read_settings
    return {} unless File.exist?(SETTINGS_PATH)

    JSON.parse(File.read(SETTINGS_PATH))
  rescue JSON::ParserError => e
    raise ConfigurationError, "The settings file at #{SETTINGS_PATH} is invalid JSON: #{e.message}"
  end

  def write_settings(settings)
    File.write("#{SETTINGS_PATH}.tmp", "#{JSON.pretty_generate(settings)}\n")
    File.rename("#{SETTINGS_PATH}.tmp", SETTINGS_PATH)
  end

  def settings_scope_key(message)
    return "server:#{message.server.id}" if message.server

    "dm:#{message.channel.id}"
  end

  def settings_scope_label(message)
    message.server ? "this server" : "this DM"
  end

  def reaction_matches?(emoji, configured_emoji)
    reaction_string(emoji) == configured_emoji
  end

  def reaction_string(emoji)
    emoji.respond_to?(:to_reaction) ? emoji.to_reaction.to_s : emoji.to_s
  end

  def bot_user?(user)
    user.respond_to?(:bot_account) && user.bot_account
  end

  def voice_note_message?(message)
    voice_flag = Discordrb::Message::FLAGS.fetch(:voice_message)

    ((message.flags || 0) & voice_flag).positive? ||
      message.attachments.any? { |attachment| voice_note_metadata?(attachment) }
  end

  def voice_note_attachment(message)
    message.attachments.find { |attachment| audio_attachment?(attachment) }
  end

  def voice_note_metadata?(attachment)
    attachment.duration_seconds || attachment.waveform
  end

  def audio_attachment?(attachment)
    attachment.content_type&.start_with?("audio/")
  end

  def with_downloaded_attachment(attachment)
    extension = File.extname(attachment.filename)
    extension = ".ogg" if extension.empty?

    Tempfile.create(["iearumon-voice-note", extension], binmode: true) do |file|
      URI.open(attachment.url, "rb") do |remote_file|
        IO.copy_stream(remote_file, file)
      end
      file.flush

      yield file.path
    end
  rescue OpenURI::HTTPError, SocketError => e
    raise TranscriptionError, "Discord wouldn't let me download that voice note: #{e.message}"
  end

  def transcribe(path)
    whisper_command = Shellwords.split(ENV.fetch("WHISPER_COMMAND", DEFAULT_WHISPER_COMMAND))
    raise ConfigurationError, "Set WHISPER_COMMAND to a local Whisper CLI command." if whisper_command.empty?

    executable = whisper_command.first
    raise ConfigurationError, "Couldn't find `#{executable}` in PATH." unless executable_available?(executable)
    raise ConfigurationError, "Couldn't find `ffmpeg` in PATH." unless executable_available?("ffmpeg")

    Dir.mktmpdir("iearumon-whisper") do |output_dir|
      stdout, stderr, status = Open3.capture3(
        *whisper_command,
        path,
        "--model", ENV.fetch("WHISPER_MODEL", DEFAULT_WHISPER_MODEL),
        "--task", "transcribe",
        "--output_format", "txt",
        "--output_dir", output_dir,
        "--verbose", "False",
        "--fp16", "False",
        *language_args
      )

      transcript_path = File.join(output_dir, "#{File.basename(path, File.extname(path))}.txt")
      transcript = File.exist?(transcript_path) ? File.read(transcript_path).strip : ""

      return transcript unless !status.success? || transcript.empty?

      error_output = [stderr, stdout].reject(&:empty?).join("\n").strip
      raise TranscriptionError, error_output.empty? ? "Whisper did not return any transcription text." : error_output
    end
  end

  def language_args
    language = ENV["WHISPER_LANGUAGE"]&.strip
    return [] if language.nil? || language.empty?

    ["--language", language]
  end

  def executable_available?(command)
    return File.executable?(command) if command.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
      File.executable?(File.join(directory, command))
    end
  end

  def reply_with_chunks(message, content)
    Discordrb.split_message(content).each do |chunk|
      message.reply!(chunk, mention_user: false)
    end
  end
end

Iearumon.run if $PROGRAM_NAME == __FILE__
