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
  EAR_EMOJI = "👂"
  SETTINGS_PATH = File.expand_path("iearumon_settings.json", __dir__)
  TRANSCRIPTION_DEDUP_TTL = 300
  SLASH_COMMAND_NAME = :iearumon
  AUDIO_FILE_EXTENSIONS = Set[
    ".aac",
    ".flac",
    ".m4a",
    ".mp3",
    ".mp4",
    ".oga",
    ".ogg",
    ".opus",
    ".wav",
    ".webm"
  ].freeze
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

    register_slash_commands(bot)
    register_slash_handlers(bot)

    bot.message do |event|
      begin
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
      completed = false

      begin
        handle_voice_note(message)
        completed = true
      rescue ConfigurationError, TranscriptionError, OpenURI::HTTPError, SocketError => e
        bot.debug("voice note transcription failed: #{e.class}: #{e.message}")
        reply_with_chunks(message, "I couldn't transcribe that voice note: #{e.message}")
      ensure
        completed ? mark_transcription_complete(message.id) : clear_transcription_reservation(message.id)
      end
    end
  end

  def register_slash_commands(bot)
    bot.register_application_command(
      SLASH_COMMAND_NAME,
      "Configure iearumon voice note transcription",
      **application_command_registration_options
    ) do |command|
      command.subcommand("status", "Show the current iearumon settings")

      command.subcommand("listen", "Enable or disable automatic voice note listening") do |subcommand|
        subcommand.boolean("enabled", "Whether iearumon should automatically transcribe new voice notes", required: true)
      end

      command.subcommand("emoji", "Set the reaction emoji used for manual transcription") do |subcommand|
        subcommand.string("value", "Emoji to use for reactions, like 👂 or :custom_emoji:", required: true)
      end
    end
  end

  def register_slash_handlers(bot)
    command = bot.application_command(SLASH_COMMAND_NAME)

    command.subcommand(:status) do |event|
      event.respond(content: status_text(event), ephemeral: true)
    rescue ConfigurationError => e
      event.respond(content: e.message, ephemeral: true)
    end

    command.subcommand(:listen) do |event|
      settings = update_settings_for(event) do |current|
        current.merge("auto_listen" => !!event.options["enabled"])
      end

      event.respond(
        content: "Automatic listening is now **#{settings.fetch("auto_listen") ? "enabled" : "disabled"}** for #{settings_scope_label(event)}.",
        ephemeral: true
      )
    rescue ConfigurationError => e
      event.respond(content: e.message, ephemeral: true)
    end

    command.subcommand(:emoji) do |event|
      emoji = event.options["value"].to_s.strip
      if emoji.empty?
        event.respond(content: "Please provide an emoji to use for reactions.", ephemeral: true)
        next
      end

      settings = update_settings_for(event) do |current|
        current.merge("reaction_emoji" => emoji)
      end

      event.respond(
        content: "Reaction emoji set to #{settings.fetch("reaction_emoji")} for #{settings_scope_label(event)}.",
        ephemeral: true
      )
    rescue ConfigurationError => e
      event.respond(content: e.message, ephemeral: true)
    end
  end

  def application_command_registration_options
    server_id = ENV["IEARUMON_COMMAND_SERVER_ID"]&.strip
    return {} if server_id.nil? || server_id.empty?

    { server_id: server_id }
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

  def status_text(context)
    settings = settings_for(context)

    <<~TEXT.strip
      Settings for #{settings_scope_label(context)}:
      Auto listening: **#{settings.fetch("auto_listen") ? "on" : "off"}**
      Reaction emoji: #{settings.fetch("reaction_emoji")}

      Manual trigger: react to a voice note with #{settings.fetch("reaction_emoji")}.
    TEXT
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
      message.attachments.any? { |attachment| voice_note_attachment?(attachment) }
  end

  def voice_note_attachment(message)
    message.attachments.find { |attachment| voice_note_attachment?(attachment) }
  end

  def voice_note_attachment?(attachment)
    audio_attachment?(attachment) || voice_note_metadata?(attachment) || audio_filename?(attachment.filename)
  end

  def voice_note_metadata?(attachment)
    attachment.duration_seconds || attachment.waveform
  end

  def audio_attachment?(attachment)
    attachment.content_type&.start_with?("audio/")
  end

  def audio_filename?(filename)
    AUDIO_FILE_EXTENSIONS.include?(File.extname(filename.to_s).downcase)
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
      return transcript if status.success? && !transcript.empty?

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
