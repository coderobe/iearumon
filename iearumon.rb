#!/usr/bin/env bundle exec ruby
# frozen_string_literal: true

require "dotenv/load"
require "discordrb"
require "json"
require "open-uri"
require "open3"
require "shellwords"
require "set"
require "socket"
require "tempfile"
require "time"
require "timeout"
require "tmpdir"

module Iearumon
  class AuthorizationError < StandardError; end
  class ConfigurationError < StandardError; end
  class TranscriptionError < StandardError; end

  MESSAGE_CONTENT_INTENT = 1 << 15
  DEFAULT_WHISPER_COMMAND = "whisper"
  DEFAULT_WHISPER_MODEL = "base"
  DEFAULT_MAX_WHISPER_MODEL = "large"
#  DEFAULT_WHISPER_MODEL = "small"
#  DEFAULT_WHISPER_MODEL = "medium"
  DEFAULT_DOWNLOAD_OPEN_TIMEOUT = 15
  DEFAULT_DOWNLOAD_READ_TIMEOUT = 300
  DEFAULT_MAX_AUDIO_BYTES = 64 * 1024 * 1024
  DEFAULT_TRANSCRIPTION_TIMEOUT = 1800
  DEFAULT_TRANSCRIPTION_WORKERS = 2
  DEFAULT_TRANSCRIPTION_QUEUE_LIMIT = 24
  DEFAULT_DM_ENABLED = false
  EAR_EMOJI = "👂"
  SETTINGS_PATH = File.expand_path("iearumon_settings.json", __dir__)
  TRANSCRIPTION_DEDUP_TTL = 300
  SLASH_COMMAND_NAME = :iearumon
  STATS_EMBED_COLOR = 0x5865F2
  DM_EMBED_COLOR = 0xFEE75C
  VOICE_NOTE_FILENAME = "voice-message.ogg"
  DEFAULT_SERVER_STATS = {
    "total_transcriptions" => 0,
    "seconds_transcribed" => 0
  }.freeze
  DEFAULT_SERVER_SETTINGS = {
    "auto_listen" => true,
    "reaction_emoji" => EAR_EMOJI,
    "stats" => DEFAULT_SERVER_STATS
  }.freeze
  DEFAULT_DM_SETTINGS = {
    "auto_listen" => true,
    "reaction_emoji" => EAR_EMOJI
  }.freeze
  QUESTION_MARK_REACTIONS = Set["?", "❓", "❔"].freeze
  WHISPER_MODELS_BY_RANK = {
    0 => "tiny",
    1 => "base",
    2 => "small",
    3 => "medium",
    4 => "large"
  }.freeze
  WHISPER_MODEL_RANKS = {
    "tiny" => 0,
    "base" => 1,
    "small" => 2,
    "medium" => 3,
    "large" => 4,
    "large-v1" => 4,
    "large-v2" => 4,
    "large-v3" => 4,
    "turbo" => 4
  }.freeze
  TRANSCRIPTION_RECORDS_PATH = File.expand_path("iearumon_transcriptions.json", __dir__)

  @settings_mutex = Mutex.new
  @transcription_records_mutex = Mutex.new
  @transcription_mutex = Mutex.new
  @worker_mutex = Mutex.new
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
      log_info("bot is online", command_scope: application_command_registration_options[:server_id] || "global")
      bot.debug("iearumon is online and listening for voice notes")
    end

    register_slash_commands(bot)
    register_slash_handlers(bot)

    bot.message do |event|
      begin
        next unless voice_note_message?(event.message)
        next if dm_ignored?(event.message)
        next unless auto_listen_enabled?(event.message)

        enqueue_transcription(bot, transcription_request_for(event.message))
      rescue ConfigurationError => e
        bot.debug("message handling failed: #{e.class}: #{e.message}")
        reply_with_chunks(event.message, user_configuration_error_message(event))
      end
    end

    bot.reaction_add do |event|
      begin
        next if bot_user?(event.user)
        next if dm_ignored?(event.message)
        next if handle_retry_reaction(bot, event.message, event.emoji)
        next unless voice_note_message?(event.message)
        next unless reaction_matches?(event.emoji, reaction_emoji_for(event.message))

        enqueue_transcription(bot, transcription_request_for(event.message))
      rescue ConfigurationError => e
        bot.debug("reaction handling failed: #{e.class}: #{e.message}")
        reply_with_chunks(event.message, user_configuration_error_message(event))
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
      (global_dm_enabled? ? Discordrb::INTENTS.fetch(:direct_messages) : 0) |
      (global_dm_enabled? ? Discordrb::INTENTS.fetch(:direct_message_reactions) : 0) |
      MESSAGE_CONTENT_INTENT
  end

  def handle_voice_note(request)
    source_message = request.fetch(:source_message)
    reply_to_message = request.fetch(:reply_to_message)
    model = request.fetch(:model)
    attachment = voice_note_attachment(source_message)
    raise TranscriptionError, "No voice note attachment was found." unless attachment
    ensure_dm_transcription_allowed!(source_message)

    add_processing_reaction(reply_to_message)

    log_info(
      "starting voice note processing",
      message_log_context(source_message, filename: attachment.filename, reply_to_message_id: reply_to_message.id, model: model)
    )

    transcript = with_downloaded_attachment(source_message, attachment) do |path|
      duration_seconds = audio_duration_seconds(path, attachment)
      transcript = transcribe(source_message, path, model: model)
      record_successful_transcription(source_message, duration_seconds)
      transcript
    end

    log_info(
      "completed voice note processing",
      message_log_context(source_message, reply_to_message_id: reply_to_message.id, model: model, transcript_characters: transcript.length)
    )
    reply_messages = reply_with_chunks(reply_to_message, transcript.to_s)
    record_transcription_responses(reply_messages, source_message: source_message, model: model)
  end

  def enqueue_transcription(bot, request)
    reservation_key = reserve_transcription_request(request)
    return false unless reservation_key

    enqueue_reserved_transcription(bot, request, reservation_key)
  end

  def reserve_transcription_request(request)
    reservation_key = transcription_request_key(request)
    return nil unless reserve_transcription(reservation_key)

    reservation_key
  end

  def enqueue_reserved_transcription(bot, request, reservation_key)
    return false if reservation_key.nil?

    ensure_transcription_workers_running(bot)
    transcription_queue.push(request)
    log_info(
      "queued voice note transcription",
      message_log_context(
        request.fetch(:source_message),
        queue_depth: transcription_queue.length,
        reply_to_message_id: request.fetch(:reply_to_message).id,
        model: request.fetch(:model)
      )
    )
    true
  end

  def register_slash_commands(bot)
    bot.register_application_command(
      SLASH_COMMAND_NAME,
      "Configure iearumon voice note transcription",
      **application_command_registration_options
    ) do |command|
      command.subcommand("status", "Show the iearumon overview for this server or DM")

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
      event.respond(ephemeral: true) do |builder|
        builder.add_embed do |embed|
          populate_status_embed(embed, event)
        end
      end
    rescue ConfigurationError => e
      bot.debug("status command failed: #{e.class}: #{e.message}")
      event.respond(content: user_configuration_error_message(event), ephemeral: true)
    end

    command.subcommand(:listen) do |event|
      authorize_settings_change!(event)

      settings = update_settings_for(event) do |current|
        current.merge("auto_listen" => !!event.options["enabled"])
      end

      event.respond(
        content: "Automatic listening is now **#{settings.fetch("auto_listen") ? "enabled" : "disabled"}** for #{settings_scope_label(event)}.",
        ephemeral: true
      )
    rescue AuthorizationError => e
      event.respond(content: e.message, ephemeral: true)
    rescue ConfigurationError => e
      bot.debug("listen command failed: #{e.class}: #{e.message}")
      event.respond(content: user_configuration_error_message(event), ephemeral: true)
    end

    command.subcommand(:emoji) do |event|
      authorize_settings_change!(event)

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
    rescue AuthorizationError => e
      event.respond(content: e.message, ephemeral: true)
    rescue ConfigurationError => e
      bot.debug("emoji command failed: #{e.class}: #{e.message}")
      event.respond(content: user_configuration_error_message(event), ephemeral: true)
    end

  end

  def application_command_registration_options
    server_id = ENV["IEARUMON_COMMAND_SERVER_ID"]&.strip
    return { server_id: server_id } unless server_id.nil? || server_id.empty?

    return {} if global_dm_enabled?

    { contexts: [0] }
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

  def auto_listen_enabled?(message)
    settings_for(message).fetch("auto_listen")
  end

  def reaction_emoji_for(message)
    settings_for(message).fetch("reaction_emoji")
  end

  def transcription_request_for(source_message, reply_to_message: source_message, model: default_whisper_model)
    {
      source_message: source_message,
      reply_to_message: reply_to_message,
      model: normalized_whisper_model_value(model)
    }
  end

  def settings_for(message)
    @settings_mutex.synchronize do
      stored_settings = read_settings.fetch(settings_scope_key(message), {})
      normalize_settings(message, stored_settings)
    end
  end

  def update_settings_for(message)
    @settings_mutex.synchronize do
      settings = read_settings
      key = settings_scope_key(message)
      current = normalize_settings(message, settings.fetch(key, {}))
      updated = normalize_settings(message, yield(current))
      settings[key] = updated
      write_settings(settings)
      updated
    end
  end

  def normalize_settings(context, stored_settings)
    normalized = default_settings_for(context).merge(stored_settings)
    return normalized unless context.server

    normalized.merge("stats" => DEFAULT_SERVER_STATS.merge(stored_settings.fetch("stats", {})))
  end

  def default_settings_for(context)
    context.server ? DEFAULT_SERVER_SETTINGS : DEFAULT_DM_SETTINGS
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

  def read_transcription_records
    return {} unless File.exist?(TRANSCRIPTION_RECORDS_PATH)

    JSON.parse(File.read(TRANSCRIPTION_RECORDS_PATH))
  rescue JSON::ParserError => e
    raise ConfigurationError, "The transcription records file at #{TRANSCRIPTION_RECORDS_PATH} is invalid JSON: #{e.message}"
  end

  def write_transcription_records(records)
    File.write("#{TRANSCRIPTION_RECORDS_PATH}.tmp", "#{JSON.pretty_generate(records)}\n")
    File.rename("#{TRANSCRIPTION_RECORDS_PATH}.tmp", TRANSCRIPTION_RECORDS_PATH)
  end

  def transcription_record_for(message_id)
    @transcription_records_mutex.synchronize do
      read_transcription_records[message_id.to_s]
    end
  end

  def claim_retry_reaction_for(message_id)
    @transcription_records_mutex.synchronize do
      records = read_transcription_records
      record_key = message_id.to_s
      record = records[record_key]
      return [:missing, nil] unless record
      return [:already_handled, record] if record["retry_requested_at"]

      updated_record = record.merge("retry_requested_at" => Time.now.utc.iso8601)
      records[record_key] = updated_record
      write_transcription_records(records)
      [:claimed, updated_record]
    end
  end

  def record_transcription_responses(reply_messages, source_message:, model:)
    return if reply_messages.empty?

    @transcription_records_mutex.synchronize do
      records = read_transcription_records
      created_at = Time.now.utc.iso8601

      reply_messages.each do |reply_message|
        records[reply_message.id.to_s] = {
          "source_message_id" => source_message.id,
          "source_channel_id" => source_message.channel.id,
          "model" => normalized_whisper_model_value(model),
          "created_at" => created_at
        }
      end

      write_transcription_records(records)
    end
  end

  def settings_scope_key(message)
    return "server:#{message.server.id}" if message.server

    "dm:#{message.channel.id}"
  end

  def settings_scope_label(message)
    message.server ? "this server" : "this DM"
  end

  def ensure_dm_transcription_allowed!(context)
    return if context.server || global_dm_enabled?

    raise TranscriptionError, dm_disabled_message
  end

  def global_dm_enabled?
    @global_dm_enabled ||= boolean_env("IEARUMON_DM_ENABLED", DEFAULT_DM_ENABLED)
  end

  def dm_ignored?(context)
    return false if context.server
    return false if global_dm_enabled?

    log_info("ignoring DM interaction because DMs are disabled", scope: settings_scope_key(context), channel_id: context.channel.id)
    true
  end

  def dm_disabled_message
    "DM support is disabled for this bot."
  end

  def add_processing_reaction(message)
    message.react(reaction_emoji_for(message))
  rescue Discordrb::Errors::NoPermission, Discordrb::Errors::CodeError => e
    log_warn(
      "could not add processing reaction",
      message_log_context(message, reaction: reaction_emoji_for(message), error_class: e.class.name, error: e.message)
    )
  end

  def authorize_settings_change!(event)
    return unless event.server
    return if event.user.respond_to?(:can_manage_server?) && event.user.can_manage_server?

    raise AuthorizationError, "-# you need the Manage Server permission to change iearumon settings for this server."
  end

  def reaction_matches?(emoji, configured_emoji)
    reaction_string(emoji) == configured_emoji
  end

  def retry_reaction?(emoji)
    QUESTION_MARK_REACTIONS.include?(reaction_string(emoji))
  end

  def reaction_string(emoji)
    emoji.respond_to?(:to_reaction) ? emoji.to_reaction.to_s : emoji.to_s
  end

  def handle_retry_reaction(bot, reacted_message, emoji)
    return false unless retry_reaction?(emoji)

    retry_claim, retry_record = claim_retry_reaction_for(reacted_message.id)
    return false if retry_claim == :missing
    return true if retry_claim == :already_handled

    current_model = current_retry_model_for(retry_record)
    return true unless current_model

    next_model = next_retry_whisper_model(current_model)
    unless next_model
      reply_with_chunks(reacted_message, "-# that's all i've got, you're on your own now")
      return true
    end

    source_message = resolve_retry_source_message(bot, reacted_message, retry_record)
    unless source_message
      reply_with_chunks(reacted_message, "-# transcription requested but i can't find the original voice note anymore")
      return true
    end

    request = transcription_request_for(source_message, reply_to_message: reacted_message, model: next_model)
    reservation_key = reserve_transcription_request(request)
    return true unless reservation_key

    reply_with_chunks(reacted_message, "-# got ? react. hold on, trying harder.")
    enqueue_reserved_transcription(bot, request, reservation_key)
    true
  end

  def current_retry_model_for(retry_record)
    reacted_model = normalized_whisper_model_value(retry_record.fetch("model"))
    highest_model = highest_transcription_model_for_source(retry_record.fetch("source_message_id"))
    return reacted_model unless highest_model
    return nil if whisper_model_rank(highest_model) > whisper_model_rank(reacted_model)

    reacted_model
  end

  def resolve_retry_source_message(bot, reacted_message, retry_record)
    source_channel = bot.channel(retry_record.fetch("source_channel_id").to_i) || reacted_message.channel
    source_channel&.message(retry_record.fetch("source_message_id").to_i)
  rescue Discordrb::Errors::NoPermission, Discordrb::Errors::UnknownMessage
    nil
  end

  def bot_user?(user)
    user.respond_to?(:bot_account) && user.bot_account
  end

  def voice_note_message?(message)
    message.attachments.any? { |attachment| voice_note_attachment?(attachment) }
  end

  def voice_note_attachment(message)
    message.attachments.find { |attachment| voice_note_attachment?(attachment) }
  end

  def voice_note_attachment?(attachment)
    attachment.filename.to_s.downcase == VOICE_NOTE_FILENAME
  end

  def with_downloaded_attachment(message, attachment)
    attachment_size = attachment.size.to_i
    if attachment_size.positive? && attachment_size > max_audio_bytes
      raise TranscriptionError, "-# that voice note is too large to transcribe safely. the current limit is #{byte_limit_label(max_audio_bytes)}."
    end

    extension = File.extname(attachment.filename)
    extension = ".ogg" if extension.empty?

    Tempfile.create(["iearumon-voice-note", extension], binmode: true) do |file|
      log_info(
        "starting attachment download",
        message_log_context(message, filename: attachment.filename, expected_bytes: attachment_size.positive? ? attachment_size : nil)
      )

      URI.open(attachment.url, "rb", open_timeout: download_open_timeout, read_timeout: download_read_timeout) do |remote_file|
        bytes_downloaded = 0

        while (chunk = remote_file.read(64 * 1024))
          bytes_downloaded += chunk.bytesize
          if bytes_downloaded > max_audio_bytes
            raise TranscriptionError, "-# that voice note is too large to transcribe safely. the current limit is #{byte_limit_label(max_audio_bytes)}."
          end

          file.write(chunk)
        end

        log_info("finished attachment download", message_log_context(message, downloaded_bytes: bytes_downloaded))
      end
      file.flush

      yield file.path
    end
  rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
    log_warn("attachment download timed out", message_log_context(message, filename: attachment.filename))
    raise TranscriptionError, "-# discord took too long to send me that voice note. try again in a moment."
  rescue OpenURI::HTTPError, SocketError
    log_warn("attachment download failed", message_log_context(message, filename: attachment.filename))
    raise TranscriptionError, "-# discord wouldn't let me download that voice note."
  end

  def transcribe(message, path, model:)
    whisper_command = Shellwords.split(ENV.fetch("WHISPER_COMMAND", DEFAULT_WHISPER_COMMAND))
    raise ConfigurationError, "Set WHISPER_COMMAND to a local Whisper CLI command." if whisper_command.empty?

    executable = whisper_command.first
    raise ConfigurationError, "Couldn't find `#{executable}` in PATH." unless executable_available?(executable)
    raise ConfigurationError, "Couldn't find `ffmpeg` in PATH." unless executable_available?("ffmpeg")

    Dir.mktmpdir("iearumon-whisper") do |output_dir|
      log_info(
        "starting transcription",
        message_log_context(
          message,
          whisper_command: whisper_command.join(" "),
          model: model,
          language: ENV["WHISPER_LANGUAGE"]&.strip
        )
      )

      stdout, stderr, status = capture_command_with_timeout(
        transcription_timeout,
        *whisper_command,
        path,
        "--model", model,
        "--task", "transcribe",
        "--output_format", "txt",
        "--output_dir", output_dir,
        "--verbose", "False",
        "--fp16", "False",
        *language_args
      )

      transcript_path = File.join(output_dir, "#{File.basename(path, File.extname(path))}.txt")
      transcript = File.exist?(transcript_path) ? File.read(transcript_path).strip : ""
      if status.success? && !transcript.empty?
        log_info(
          "finished transcription",
          message_log_context(
            message,
            transcript_characters: transcript.length,
            stdout_bytes: stdout.to_s.bytesize,
            stderr_bytes: stderr.to_s.bytesize
          )
        )
        return transcript
      end

      log_warn(
        "transcription produced no output",
        message_log_context(
          message,
          exit_status: status.exitstatus,
          stdout_preview: truncated_log_output(stdout),
          stderr_preview: truncated_log_output(stderr)
        )
      )

      raise TranscriptionError, "-# failed transcription: no idea what you said."
    end
  end

  def audio_duration_seconds(path, attachment)
    attachment_duration = attachment.duration_seconds.to_f
    return attachment_duration.round if attachment_duration.positive?

    return 0 unless executable_available?("ffprobe")

    stdout, stderr, status = capture_command_with_timeout(
      30,
      "ffprobe",
      "-v", "error",
      "-show_entries", "format=duration",
      "-of", "default=noprint_wrappers=1:nokey=1",
      path
    )
    duration = stdout.to_f
    return duration.round if status.success? && duration.positive?

    log_warn("ffprobe could not determine audio duration", path: path, stderr_preview: truncated_log_output(stderr))
    0
  rescue TranscriptionError => e
    log_warn("audio duration lookup timed out", path: path, error: e.message)
    0
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

  def positive_integer_env(name, default)
    raw_value = ENV[name]&.strip
    return default if raw_value.nil? || raw_value.empty?

    value = Integer(raw_value, 10)
    raise ArgumentError if value <= 0

    value
  rescue ArgumentError
    raise ConfigurationError, "#{name} must be a positive integer."
  end

  def boolean_env(name, default)
    raw_value = ENV[name]&.strip
    return default if raw_value.nil? || raw_value.empty?

    case raw_value.downcase
    when "1", "true", "yes", "on"
      true
    when "0", "false", "no", "off"
      false
    else
      raise ConfigurationError, "#{name} must be true/false."
    end
  end

  def download_open_timeout
    @download_open_timeout ||= positive_integer_env("IEARUMON_DOWNLOAD_OPEN_TIMEOUT", DEFAULT_DOWNLOAD_OPEN_TIMEOUT)
  end

  def default_whisper_model
    @default_whisper_model ||= begin
      model = ENV.fetch("WHISPER_MODEL", DEFAULT_WHISPER_MODEL).to_s.strip
      model.empty? ? DEFAULT_WHISPER_MODEL : model
    end
  end

  def normalized_whisper_model_value(model)
    value = model.to_s.strip.downcase
    value.empty? ? DEFAULT_WHISPER_MODEL : value
  end

  def whisper_model_rank(model)
    WHISPER_MODEL_RANKS[normalized_whisper_model_value(model)]
  end

  def highest_transcription_model_for_source(source_message_id)
    source_id = source_message_id.to_s
    completed_models = @transcription_records_mutex.synchronize do
      read_transcription_records.each_value.filter_map do |record|
        next unless record["source_message_id"].to_s == source_id

        normalized_whisper_model_value(record["model"])
      end
    end

    in_progress_models = @transcription_mutex.synchronize do
      prune_recent_transcriptions!
      (@messages_in_progress.to_a + @recent_transcriptions.keys).filter_map do |reservation_key|
        reserved_source_id, reserved_model = reservation_key.to_s.split(":", 2)
        next unless reserved_source_id == source_id

        normalized_whisper_model_value(reserved_model)
      end
    end

    (completed_models + in_progress_models).max_by { |model| whisper_model_rank(model) || -1 }
  end

  def max_retry_whisper_model
    @max_retry_whisper_model ||= begin
      configured_model = ENV.fetch("IEARUMON_MAX_WHISPER_MODEL", DEFAULT_MAX_WHISPER_MODEL).to_s.strip
      configured_model = DEFAULT_MAX_WHISPER_MODEL if configured_model.empty?
      rank = whisper_model_rank(configured_model)
      unless rank
        raise ConfigurationError,
              "IEARUMON_MAX_WHISPER_MODEL must be one of tiny, base, small, medium, large, large-v1, large-v2, large-v3, or turbo."
      end

      WHISPER_MODELS_BY_RANK.fetch(rank)
    end
  end

  def next_retry_whisper_model(current_model)
    current_rank = whisper_model_rank(current_model)
    return nil unless current_rank

    next_rank = current_rank + 1
    return nil if next_rank > whisper_model_rank(max_retry_whisper_model)

    WHISPER_MODELS_BY_RANK[next_rank]
  end

  def download_read_timeout
    @download_read_timeout ||= positive_integer_env("IEARUMON_DOWNLOAD_READ_TIMEOUT", DEFAULT_DOWNLOAD_READ_TIMEOUT)
  end

  def max_audio_bytes
    @max_audio_bytes ||= positive_integer_env("IEARUMON_MAX_AUDIO_BYTES", DEFAULT_MAX_AUDIO_BYTES)
  end

  def transcription_timeout
    @transcription_timeout ||= positive_integer_env("IEARUMON_TRANSCRIPTION_TIMEOUT", DEFAULT_TRANSCRIPTION_TIMEOUT)
  end

  def transcription_worker_count
    @transcription_worker_count ||= positive_integer_env("IEARUMON_TRANSCRIPTION_WORKERS", DEFAULT_TRANSCRIPTION_WORKERS)
  end

  def transcription_queue_limit
    @transcription_queue_limit ||= positive_integer_env("IEARUMON_TRANSCRIPTION_QUEUE_LIMIT", DEFAULT_TRANSCRIPTION_QUEUE_LIMIT)
  end

  def transcription_queue
    @worker_mutex.synchronize do
      @transcription_queue ||= SizedQueue.new(transcription_queue_limit)
    end
  end

  def ensure_transcription_workers_running(bot)
    @worker_mutex.synchronize do
      return if @transcription_workers_started

      transcription_worker_count.times do
        Thread.new { transcription_worker_loop(bot) }
      end

      @transcription_workers_started = true
      log_info("started transcription workers", worker_count: transcription_worker_count, queue_limit: transcription_queue_limit)
    end
  end

  def transcription_worker_loop(bot)
    loop do
      request = transcription_queue.pop
      completed = false
      reservation_key = transcription_request_key(request)

      begin
        handle_voice_note(request)
        completed = true
      rescue ConfigurationError, TranscriptionError, OpenURI::HTTPError, SocketError => e
        log_warn(
          "voice note transcription failed",
          message_log_context(request.fetch(:source_message), error_class: e.class.name, error: e.message, model: request.fetch(:model))
        )
        bot.debug("voice note transcription failed: #{e.class}: #{e.message}")
        reply_with_chunks(request.fetch(:reply_to_message), user_transcription_error_message(e))
      rescue StandardError => e
        log_warn(
          "voice note transcription failed unexpectedly",
          message_log_context(
            request.fetch(:source_message),
            error_class: e.class.name,
            error: e.message,
            model: request.fetch(:model),
            backtrace_preview: truncated_log_output(Array(e.backtrace).first(5).join(" | "))
          )
        )
        bot.debug("voice note transcription failed unexpectedly: #{e.class}: #{e.message}")
        reply_with_chunks(request.fetch(:reply_to_message), "-# i couldn't transcribe that voice note because an internal error occurred.")
      ensure
        completed ? mark_transcription_complete(reservation_key) : clear_transcription_reservation(reservation_key)
      end
    end
  end

  def capture_command_with_timeout(timeout_seconds, *command)
    Open3.popen3(*command) do |stdin, stdout, stderr, wait_thread|
      stdin.close

      stdout_reader = Thread.new { stdout.read }
      stderr_reader = Thread.new { stderr.read }

      unless wait_thread.join(timeout_seconds)
        terminate_process(wait_thread)
        raise TranscriptionError, "-# transcription took longer than #{duration_label(timeout_seconds)}. try again later."
      end

      [stdout_reader.value, stderr_reader.value, wait_thread.value]
    ensure
      stdout_reader&.join
      stderr_reader&.join
    end
  end

  def terminate_process(wait_thread)
    pid = wait_thread.pid
    Process.kill("TERM", pid)
    return if wait_thread.join(5)

    Process.kill("KILL", pid)
    wait_thread.join
  rescue Errno::ESRCH
    wait_thread.join
  end

  def duration_label(seconds)
    minutes = seconds / 60
    return "#{seconds} seconds" if minutes.zero?
    return "1 minute" if minutes == 1

    "#{minutes} minutes"
  end

  def byte_limit_label(bytes)
    megabytes = bytes.to_f / (1024 * 1024)
    formatted = megabytes.round(1)
    formatted = formatted.to_i if formatted == formatted.to_i
    "#{formatted} MiB"
  end

  def record_successful_transcription(message, duration_seconds)
    return unless message.server

    updated_settings = update_settings_for(message) do |current|
      stats = current.fetch("stats")
      current.merge(
        "stats" => stats.merge(
          "total_transcriptions" => stats.fetch("total_transcriptions").to_i + 1,
          "seconds_transcribed" => stats.fetch("seconds_transcribed").to_i + duration_seconds.to_i
        )
      )
    end

    stats = updated_settings.fetch("stats")
    log_info(
      "updated server transcription stats",
      message_log_context(
        message,
        duration_seconds: duration_seconds.to_i,
        total_transcriptions: stats.fetch("total_transcriptions"),
        seconds_transcribed: stats.fetch("seconds_transcribed")
      )
    )
  end

  def populate_status_embed(embed, context)
    settings = settings_for(context)
    embed.title = context.server ? "iearumon overview" : "iearumon DM overview"
    embed.description = context.server ? "Voice note transcription for **#{context.server.name}**." : "Voice note transcription settings for this DM."
    embed.color = context.server ? STATS_EMBED_COLOR : DM_EMBED_COLOR
    embed.timestamp = Time.now

    embed.add_field(name: "Listening", value: enabled_label(settings.fetch("auto_listen")), inline: true)
    embed.add_field(name: "Trigger emoji", value: settings.fetch("reaction_emoji"), inline: true)

    if context.server
      stats = settings.fetch("stats")
      embed.add_field(name: "Transcriptions", value: "**#{format_integer(stats.fetch("total_transcriptions"))}** total", inline: true)
      embed.add_field(
        name: "Audio processed",
        value: "#{duration_summary(stats.fetch("seconds_transcribed"))}\n#{format_integer(stats.fetch("seconds_transcribed"))} sec",
        inline: true
      )
      embed.add_field(
        name: "How it works",
        value: "New voice notes are transcribed automatically when listening is enabled.\nYou can always react with #{settings.fetch("reaction_emoji")} to trigger a manual transcription.",
        inline: false
      )
    else
      embed.add_field(name: "DM access", value: enabled_label(global_dm_enabled?), inline: true)
      embed.add_field(
        name: "How it works",
        value: global_dm_enabled? ? "React to a voice note with #{settings.fetch("reaction_emoji")} or leave auto listening on for new voice notes." : "Set `IEARUMON_DM_ENABLED=true` in the bot environment to allow DM interactions.",
        inline: false
      )
    end

    embed.footer = Discordrb::Webhooks::EmbedFooter.new(text: context.server ? "Server overview" : "DM overview")
  end

  def enabled_label(enabled)
    enabled ? "Enabled" : "Disabled"
  end

  def duration_summary(total_seconds)
    seconds = total_seconds.to_i
    return "0s total" if seconds <= 0

    parts = []
    hours = seconds / 3600
    minutes = (seconds % 3600) / 60
    remaining_seconds = seconds % 60
    parts << "#{hours}h" if hours.positive?
    parts << "#{minutes}m" if minutes.positive?
    parts << "#{remaining_seconds}s" if remaining_seconds.positive? || parts.empty?
    parts.join(" ")
  end

  def format_integer(number)
    number.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
  end

  def truncated_log_output(output, max_length = 160)
    text = output.to_s.strip
    return nil if text.empty?

    text.length > max_length ? "#{text[0, max_length]}..." : text
  end

  def message_log_context(message, extra = {})
    {
      scope: settings_scope_key(message),
      server_id: message.server&.id,
      channel_id: message.channel.id,
      message_id: message.id,
      author_id: message.author&.id
    }.merge(extra).compact
  end

  def log_info(message, context = {})
    log_runtime("INFO", message, context)
  end

  def log_warn(message, context = {})
    log_runtime("WARN", message, context)
  end

  def log_runtime(level, message, context = {})
    fields = context.map { |key, value| "#{key}=#{format_log_value(value)}" }.join(" ")
    $stdout.puts("[#{Time.now.utc.iso8601}] #{level} #{message}#{fields.empty? ? "" : " #{fields}"}")
    $stdout.flush
  end

  def format_log_value(value)
    value.is_a?(String) ? value.inspect : value
  end

  def user_configuration_error_message(context)
    return "I couldn't read my configuration for this DM. Please check the bot logs." unless context.server

    "I couldn't complete that action for this server. Please ask a server manager to check the bot logs."
  end

  def user_transcription_error_message(error)
    return error.message if error.is_a?(TranscriptionError)

    "-# i couldn't transcribe that voice note."
  end

  def reply_with_chunks(message, content)
    Discordrb.split_message(content).map do |chunk|
      message.reply!(chunk, mention_user: false)
    end
  end

  def transcription_request_key(request)
    "#{request.fetch(:source_message).id}:#{normalized_whisper_model_value(request.fetch(:model))}"
  end
end

Iearumon.run if $PROGRAM_NAME == __FILE__
