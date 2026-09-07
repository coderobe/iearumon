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
  DEFAULT_MIN_WHISPER_MODEL = "tiny"
#  DEFAULT_WHISPER_MODEL = "small"
#  DEFAULT_WHISPER_MODEL = "medium"
  DEFAULT_DOWNLOAD_OPEN_TIMEOUT = 15
  DEFAULT_DOWNLOAD_READ_TIMEOUT = 300
  DEFAULT_MAX_AUDIO_BYTES = 64 * 1024 * 1024
  DEFAULT_TRANSCRIPTION_TIMEOUT = 1800
  DEFAULT_TRANSCRIPTION_WORKERS = 2
  DEFAULT_TRANSCRIPTION_QUEUE_LIMIT = 24
  DEFAULT_DM_ENABLED = false
  DEFAULT_PROGRESS_PREVIEW_WORDS = 5
  DEFAULT_PROGRESS_UPDATE_INTERVAL = 5
  EAR_EMOJI = "👂"
  INTERROBANG_EMOJI = "⁉️"
  DEFAULT_UPGRADE_REACTION_EMOJIS = ["?", "❓", "❔"].freeze
  SETTINGS_PATH = File.expand_path("iearumon_settings.json", __dir__)
  TRANSCRIPTION_DEDUP_TTL = 300
  SLASH_COMMAND_NAME = :iearumon
  STATS_EMBED_COLOR = 0x5865F2
  DM_EMBED_COLOR = 0xFEE75C
  VOICE_NOTE_FILENAME = "voice-message.ogg"
  STREAMING_TRANSCRIPTION_STATUS = " *[...]*\n-# this transcription is still being processed"
  WORKER_CRASH_BACKOFF_SECONDS = 1
  DEFAULT_SERVER_STATS = {
    "total_transcriptions" => 0,
    "seconds_transcribed" => 0
  }.freeze
  DEFAULT_SERVER_SETTINGS = {
    "auto_listen" => true,
    "reaction_emoji" => EAR_EMOJI,
    "upgrade_reaction_emojis" => DEFAULT_UPGRADE_REACTION_EMOJIS,
    "upgrade_reaction_enabled" => true,
    "downgrade_reaction_emoji" => INTERROBANG_EMOJI,
    "downgrade_reaction_enabled" => true,
    "stats" => DEFAULT_SERVER_STATS
  }.freeze
  DEFAULT_DM_SETTINGS = {
    "auto_listen" => true,
    "reaction_emoji" => EAR_EMOJI,
    "upgrade_reaction_emojis" => DEFAULT_UPGRADE_REACTION_EMOJIS,
    "upgrade_reaction_enabled" => true,
    "downgrade_reaction_emoji" => INTERROBANG_EMOJI,
    "downgrade_reaction_enabled" => true
  }.freeze
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

  class DisplayedTranscriptionError < TranscriptionError; end

  class StreamingTranscriptionReply
    def initialize(reply_to_message, preview_word_count:, min_edit_interval:)
      @reply_to_message = reply_to_message
      @preview_word_count = preview_word_count
      @min_edit_interval = min_edit_interval
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @partial_segments = []
      @placeholder_message = nil
      @last_rendered_content = nil
      @last_update_at = nil
      @pending_rendered_content = nil
      @flush_thread = nil
      @closed = false
    end

    def append_segment(segment_text)
      normalized_segment = normalize_segment_text(segment_text)
      return if normalized_segment.empty?

      @mutex.synchronize do
        return if @closed

        @partial_segments << normalized_segment
        partial_text = @partial_segments.join(" ").strip
        return unless enough_words_for_preview?(partial_text)

        rendered_content = render_progress_content(partial_text)
        return if rendered_content == @last_rendered_content || rendered_content == @pending_rendered_content

        @pending_rendered_content = rendered_content
        ensure_flush_thread_running
        @condition.signal
      end
    end

    def complete(final_transcript)
      transcript = final_transcript.to_s
      placeholder_message = close_progress_updates

      return Iearumon.reply_with_chunks(@reply_to_message, transcript) unless placeholder_message

      chunks = Discordrb.split_message(transcript)
      return [] if chunks.empty?

      begin
        placeholder_message.edit(chunks.shift)
      rescue Discordrb::Errors::NoPermission, Discordrb::Errors::CodeError
        return Iearumon.reply_with_chunks(@reply_to_message, transcript)
      end

      [placeholder_message, *chunks.map { |chunk| @reply_to_message.reply!(chunk, mention_user: false) }]
    end

    def display_failure(content)
      placeholder_message = close_progress_updates
      return false unless placeholder_message

      placeholder_message.edit(content)
      true
    rescue Discordrb::Errors::NoPermission, Discordrb::Errors::CodeError => e
      Iearumon.log_warn(
        "could not replace streaming transcription reply with failure",
        Iearumon.message_log_context(
          @reply_to_message,
          error_class: e.class.name,
          error: e.message
        )
      )
      false
    end

    private

    def enough_words_for_preview?(text)
      text.split(/\s+/).length >= @preview_word_count
    end

    def normalize_segment_text(text)
      text.to_s.gsub(/\s+/, " ").strip
    end

    def render_progress_content(text)
      max_preview_length = 2000 - Iearumon::STREAMING_TRANSCRIPTION_STATUS.length
      preview = text[0, max_preview_length].to_s.rstrip
      "#{preview}#{Iearumon::STREAMING_TRANSCRIPTION_STATUS}"
    end

    def ensure_flush_thread_running
      return if @flush_thread&.alive?

      @flush_thread = Thread.new do
        loop do
          content = nil
          placeholder_message = nil
          stop = false

          @mutex.synchronize do
            while !@closed && @pending_rendered_content.nil?
              @condition.wait(@mutex)
            end

            if @closed
              stop = true
            else
              if @placeholder_message && @last_update_at
                remaining = @min_edit_interval - (Time.now - @last_update_at)
                @condition.wait(@mutex, remaining) if remaining.positive?
              end

              if @closed
                stop = true
              elsif @pending_rendered_content
                content = @pending_rendered_content
                placeholder_message = @placeholder_message
              end
            end
          end

          break if stop
          next if content.nil?

          persisted_message = nil
          success = false
          begin
            if placeholder_message
              placeholder_message.edit(content)
            else
              persisted_message = @reply_to_message.reply!(content, mention_user: false)
            end
            success = true
          rescue Discordrb::Errors::NoPermission, Discordrb::Errors::CodeError => e
            Iearumon.log_warn(
              "could not update streaming transcription reply",
              Iearumon.message_log_context(
                @reply_to_message,
                error_class: e.class.name,
                error: e.message
              )
            )
          ensure
            @mutex.synchronize do
              @placeholder_message ||= persisted_message if persisted_message
              @pending_rendered_content = nil if @pending_rendered_content == content
              if success
                @last_rendered_content = content
                @last_update_at = Time.now
              end
              @condition.broadcast
            end
          end
        end
      end
    end

    def close_progress_updates
      flush_thread = nil

      @mutex.synchronize do
        @closed = true
        @pending_rendered_content = nil
        flush_thread = @flush_thread
        @condition.broadcast
      end

      flush_thread&.join
      @mutex.synchronize { @placeholder_message }
    end
  end

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

    # NOTE: discordrb dispatches these handlers on (or very close to) the
    # gateway thread that also owns the heartbeat. Anything blocking in here
    # (like a full SizedQueue#push, or an outbound HTTP call) can starve the
    # heartbeat and cause Discord to close the connection. So the actual
    # enqueueing/replying work is pushed onto its own Thread; only the cheap checks stay inline.
    bot.message do |event|
      begin
        next unless voice_note_message?(event.message)
        next if dm_ignored?(event.message)
        next unless auto_listen_enabled?(event.message)

        Thread.new do
          enqueue_transcription(bot, transcription_request_for(event.message))
        rescue ConfigurationError => e
          bot.debug("message handling failed: #{e.class}: #{e.message}")
          reply_with_chunks(event.message, user_configuration_error_message(event))
        end
      rescue ConfigurationError => e
        bot.debug("message handling failed: #{e.class}: #{e.message}")
        reply_with_chunks(event.message, user_configuration_error_message(event))
      end
    end

    bot.reaction_add do |event|
      begin
        next if bot_user?(event.user)
        next if dm_ignored?(event.message)

        retry_direction = retry_direction_for(event.message, event.emoji)
        if retry_direction
          Thread.new do
            handle_retry_reaction(bot, event.message, retry_direction)
          rescue ConfigurationError => e
            bot.debug("reaction handling failed: #{e.class}: #{e.message}")
            reply_with_chunks(event.message, user_configuration_error_message(event))
          end
          next
        end

        next unless voice_note_message?(event.message)
        next unless reaction_matches?(event.emoji, reaction_emoji_for(event.message))

        Thread.new do
          enqueue_transcription(bot, transcription_request_for(event.message))
        rescue ConfigurationError => e
          bot.debug("reaction handling failed: #{e.class}: #{e.message}")
          reply_with_chunks(event.message, user_configuration_error_message(event))
        end
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
    streaming_reply = StreamingTranscriptionReply.new(
      reply_to_message,
      preview_word_count: progress_preview_words,
      min_edit_interval: progress_update_interval
    )

    add_processing_reaction(reply_to_message)

    log_info(
      "starting voice note processing",
      message_log_context(source_message, filename: attachment.filename, reply_to_message_id: reply_to_message.id, model: model)
    )

    transcript = with_downloaded_attachment(source_message, attachment) do |path|
      duration_seconds = audio_duration_seconds(path, attachment)
      transcript = transcribe(source_message, path, model: model) do |partial_text|
        streaming_reply.append_segment(partial_text)
      end
      record_successful_transcription(source_message, duration_seconds)
      transcript
    end

    log_info(
      "completed voice note processing",
      message_log_context(source_message, reply_to_message_id: reply_to_message.id, model: model, transcript_characters: transcript.length)
    )
    reply_messages = streaming_reply.complete(transcript)
    record_transcription_responses(reply_messages, source_message: source_message, model: model)
  rescue ConfigurationError, TranscriptionError, OpenURI::HTTPError, SocketError => e
    raise DisplayedTranscriptionError, e.message if streaming_reply&.display_failure(user_transcription_error_message(e))

    raise
  rescue StandardError => e
    if streaming_reply&.display_failure("-# i couldn't transcribe that voice note because an internal error occurred.")
      raise DisplayedTranscriptionError, e.message
    end

    raise
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

  # Pushes onto the transcription queue without blocking indefinitely. If the
  # queue is full we drop the request, release its reservation (so the user
  # can retry later without being silently deduped), and tell them we're backed up
  def enqueue_reserved_transcription(bot, request, reservation_key)
    return false if reservation_key.nil?

    ensure_transcription_workers_running(bot)

    begin
      transcription_queue.push(request, true)
    rescue ThreadError
      clear_transcription_reservation(reservation_key)
      log_warn(
        "transcription queue is full, dropping request",
        message_log_context(
          request.fetch(:source_message),
          queue_depth: transcription_queue.length,
          reply_to_message_id: request.fetch(:reply_to_message).id,
          model: request.fetch(:model)
        )
      )
      safely_reply_with_chunks(request.fetch(:reply_to_message), queue_full_message)
      return false
    end

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

  def queue_full_message
    "-# i'm swamped with transcriptions right now. try again in a bit."
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

      command.subcommand("emoji", "Set manual or retry reaction settings") do |subcommand|
        subcommand.string(
          "target",
          "Which reaction setting to change",
          required: false,
          choices: {
            "manual" => "manual",
            "upgrade" => "upgrade",
            "downgrade" => "downgrade"
          }
        )
        subcommand.string("value", "Emoji or emojis to use for reactions. For upgrade, separate multiple emojis with spaces or commas.", required: false)
        subcommand.boolean("enabled", "Whether the selected retry reaction should be enabled", required: false)
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

      target = normalized_emoji_target(event.options["target"])
      emoji = event.options["value"].to_s.strip
      retry_enabled = event.options["enabled"]

      if target == "manual"
        if !retry_enabled.nil?
          event.respond(content: "The enabled option can only be used with the upgrade or downgrade target.", ephemeral: true)
          next
        end

        if emoji.empty?
          event.respond(content: "Please provide an emoji to use for reactions.", ephemeral: true)
          next
        end

        settings = update_settings_for(event) do |current|
          current.merge("reaction_emoji" => emoji)
        end

        event.respond(
          content: "Manual transcription emoji set to #{settings.fetch("reaction_emoji")} for #{settings_scope_label(event)}.",
          ephemeral: true
        )
        next
      end

      if target == "upgrade"
        if emoji.empty? && retry_enabled.nil?
          event.respond(content: "Provide one or more emojis, an enabled value, or both for the upgrade target.", ephemeral: true)
          next
        end

        upgrade_emojis = emoji.empty? ? nil : parse_reaction_emoji_list(emoji)

        settings = update_settings_for(event) do |current|
          updates = {}
          updates["upgrade_reaction_emojis"] = upgrade_emojis if upgrade_emojis
          updates["upgrade_reaction_enabled"] = !!retry_enabled unless retry_enabled.nil?
          current.merge(updates)
        end

        event.respond(
          content: "Upgrade retry is now **#{settings.fetch("upgrade_reaction_enabled") ? "enabled" : "disabled"}** with #{format_reaction_emoji_list(settings.fetch("upgrade_reaction_emojis"))} for #{settings_scope_label(event)}.",
          ephemeral: true
        )
        next
      end

      unless target == "downgrade"
        event.respond(content: "Please choose the manual, upgrade, or downgrade target.", ephemeral: true)
        next
      end

      if emoji.empty? && retry_enabled.nil?
        event.respond(content: "Provide a new emoji, an enabled value, or both for the downgrade target.", ephemeral: true)
        next
      end

      settings = update_settings_for(event) do |current|
        updates = {}
        updates["downgrade_reaction_emoji"] = emoji unless emoji.empty?
        updates["downgrade_reaction_enabled"] = !!retry_enabled unless retry_enabled.nil?
        current.merge(updates)
      end

      event.respond(
        content: "Downgrade retry is now **#{settings.fetch("downgrade_reaction_enabled") ? "enabled" : "disabled"}** with #{settings.fetch("downgrade_reaction_emoji")} for #{settings_scope_label(event)}.",
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

  def upgrade_reaction_enabled?(message)
    settings_for(message).fetch("upgrade_reaction_enabled")
  end

  def upgrade_reaction_emojis_for(message)
    settings_for(message).fetch("upgrade_reaction_emojis")
  end

  def downgrade_reaction_emoji_for(message)
    settings_for(message).fetch("downgrade_reaction_emoji")
  end

  def downgrade_reaction_enabled?(message)
    settings_for(message).fetch("downgrade_reaction_enabled")
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
    normalized["upgrade_reaction_emojis"] = normalize_reaction_emoji_list(
      stored_settings.fetch("upgrade_reaction_emojis", normalized.fetch("upgrade_reaction_emojis")),
      default: DEFAULT_UPGRADE_REACTION_EMOJIS
    )
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

  def claim_retry_reaction_for(message_id, direction)
    @transcription_records_mutex.synchronize do
      records = read_transcription_records
      record_key = message_id.to_s
      record = records[record_key]
      return [:missing, nil] unless record
      return [:already_handled, record] if retry_request_already_handled?(record, direction)

      updated_record = record.merge(retry_request_timestamp_key(direction) => Time.now.utc.iso8601)
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
    normalized_reaction_string(emoji) == normalized_reaction_string(configured_emoji)
  end

  def upgrade_retry_reaction?(message, emoji)
    upgrade_reaction_enabled?(message) &&
      upgrade_reaction_emojis_for(message).map { |reaction| normalized_reaction_string(reaction) }.include?(normalized_reaction_string(emoji))
  end

  def downgrade_retry_reaction?(message, emoji)
    downgrade_reaction_enabled?(message) && reaction_matches?(emoji, downgrade_reaction_emoji_for(message))
  end

  def reaction_string(emoji)
    emoji.respond_to?(:to_reaction) ? emoji.to_reaction.to_s : emoji.to_s
  end

  def normalized_reaction_string(emoji)
    value = reaction_string(emoji).strip
    return value if value.start_with?("<:") || value.start_with?("<a:")

    value.delete("\uFE0E\uFE0F")
  end

  def retry_direction_for(message, emoji)
    return :upgrade if upgrade_retry_reaction?(message, emoji)
    return :downgrade if downgrade_retry_reaction?(message, emoji)

    nil
  end

  def handle_retry_reaction(bot, reacted_message, direction)
    return false unless direction

    retry_claim, retry_record = claim_retry_reaction_for(reacted_message.id, direction)
    return false if retry_claim == :missing
    return true if retry_claim == :already_handled

    current_model = current_retry_model_for(retry_record, direction)
    return true unless current_model

    next_model = retry_target_whisper_model(current_model, direction)
    unless next_model
      safely_reply_with_chunks(reacted_message, retry_limit_message(direction))
      return true
    end

    source_message = resolve_retry_source_message(bot, reacted_message, retry_record)
    unless source_message
      safely_reply_with_chunks(reacted_message, "-# transcription requested but i can't find the original voice note anymore")
      return true
    end

    request = transcription_request_for(source_message, reply_to_message: reacted_message, model: next_model)
    reservation_key = reserve_transcription_request(request)
    return true unless reservation_key

    safely_reply_with_chunks(reacted_message, retry_requested_message(direction))
    enqueue_reserved_transcription(bot, request, reservation_key)
    true
  end

  def current_retry_model_for(retry_record, direction)
    reacted_model = normalized_whisper_model_value(retry_record.fetch("model"))
    return nil unless whisper_model_rank(reacted_model)
    return reacted_model unless direction == :upgrade

    highest_model = highest_transcription_model_for_source(retry_record.fetch("source_message_id"))
    return reacted_model unless highest_model
    return nil if whisper_model_rank(highest_model) > whisper_model_rank(reacted_model)

    reacted_model
  end

  def retry_target_whisper_model(current_model, direction)
    case direction
    when :upgrade
      next_retry_whisper_model(current_model)
    when :downgrade
      previous_retry_whisper_model(current_model)
    end
  end

  def retry_requested_message(direction)
    case direction
    when :upgrade
      "-# got ? react. hold on, trying harder..."
    when :downgrade
      "-# got #{INTERROBANG_EMOJI} react. hold on, giving fewer fucks..."
    end
  end

  def retry_limit_message(direction)
    case direction
    when :upgrade
      "-# that's all i've got, you're on your own now"
    when :downgrade
      "-# that's as low as it'll go"
    end
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
        "--verbose", "True",
        "--fp16", "False",
        *language_args,
        env: { "PYTHONUNBUFFERED" => "1" },
        stdout_line_callback: proc do |line|
          partial_text = whisper_progress_text(line)
          yield partial_text if partial_text && block_given?
        end
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
      configured_retry_whisper_model("IEARUMON_MAX_WHISPER_MODEL", DEFAULT_MAX_WHISPER_MODEL)
    end
  end

  def min_retry_whisper_model
    @min_retry_whisper_model ||= begin
      configured_retry_whisper_model("IEARUMON_MIN_WHISPER_MODEL", DEFAULT_MIN_WHISPER_MODEL)
    end
  end

  def configured_retry_whisper_model(env_name, default)
    configured_model = ENV.fetch(env_name, default).to_s.strip
    configured_model = default if configured_model.empty?
    rank = whisper_model_rank(configured_model)
    unless rank
      raise ConfigurationError,
            "#{env_name} must be one of tiny, base, small, medium, large, large-v1, large-v2, large-v3, or turbo."
    end

    WHISPER_MODELS_BY_RANK.fetch(rank)
  end

  def next_retry_whisper_model(current_model)
    current_rank = whisper_model_rank(current_model)
    return nil unless current_rank

    next_rank = current_rank + 1
    return nil if next_rank > whisper_model_rank(max_retry_whisper_model)

    WHISPER_MODELS_BY_RANK[next_rank]
  end

  def previous_retry_whisper_model(current_model)
    current_rank = whisper_model_rank(current_model)
    return nil unless current_rank

    previous_rank = current_rank - 1
    return nil if previous_rank < whisper_model_rank(min_retry_whisper_model)

    WHISPER_MODELS_BY_RANK[previous_rank]
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
        safely_reply_with_chunks(request.fetch(:reply_to_message), user_transcription_error_message(e)) unless e.is_a?(DisplayedTranscriptionError)
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
        safely_reply_with_chunks(request.fetch(:reply_to_message), "-# i couldn't transcribe that voice note because an internal error occurred.")
      ensure
        begin
          completed ? mark_transcription_complete(reservation_key) : clear_transcription_reservation(reservation_key)
        rescue StandardError => e
          log_warn("failed to update transcription reservation state", error_class: e.class.name, error: e.message)
        end
      end
    end
  rescue StandardError => e
    log_warn("transcription worker crashed, restarting", error_class: e.class.name, error: e.message)
    sleep WORKER_CRASH_BACKOFF_SECONDS
    retry
  end

  def capture_command_with_timeout(timeout_seconds, *command, env: {}, stdout_line_callback: nil)
    Open3.popen3(env, *command) do |stdin, stdout, stderr, wait_thread|
      stdin.close

      stdout_reader = Thread.new do
        stdout.each_line.with_object(+"") do |line, buffer|
          buffer << line
          stdout_line_callback&.call(line)
        end
      end
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
    embed.add_field(
      name: "Upgrade retry",
      value: "#{enabled_label(settings.fetch("upgrade_reaction_enabled"))}\n#{format_reaction_emoji_list(settings.fetch("upgrade_reaction_emojis"))}",
      inline: true
    )
    embed.add_field(
      name: "Downgrade retry",
      value: "#{enabled_label(settings.fetch("downgrade_reaction_enabled"))}\n#{settings.fetch("downgrade_reaction_emoji")}",
      inline: true
    )

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
        value: "New voice notes are transcribed automatically when listening is enabled.\nReact with #{settings.fetch("reaction_emoji")} to trigger a manual transcription#{retry_status_sentence(settings)}",
        inline: false
      )
    else
      embed.add_field(name: "DM access", value: enabled_label(global_dm_enabled?), inline: true)
      embed.add_field(
        name: "How it works",
        value: global_dm_enabled? ? "React to a voice note with #{settings.fetch("reaction_emoji")} or leave auto listening on for new voice notes#{retry_status_sentence(settings)}" : "Set `IEARUMON_DM_ENABLED=true` in the bot environment to allow DM interactions.",
        inline: false
      )
    end

    embed.footer = Discordrb::Webhooks::EmbedFooter.new(text: context.server ? "Server overview" : "DM overview")
  end

  def enabled_label(enabled)
    enabled ? "Enabled" : "Disabled"
  end

  def retry_status_sentence(settings)
    fragments = []
    if settings.fetch("upgrade_reaction_enabled")
      fragments << "with #{format_reaction_emoji_list(settings.fetch("upgrade_reaction_emojis"))} on a transcription reply to try a larger model"
    end
    if settings.fetch("downgrade_reaction_enabled")
      fragments << "with #{settings.fetch("downgrade_reaction_emoji")} on a transcription reply to try a smaller model"
    end

    return "." if fragments.empty?

    ", or react #{fragments.join(', or ')}."
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

  def normalized_emoji_target(target)
    value = target.to_s.strip.downcase
    value.empty? ? "manual" : value
  end

  def parse_reaction_emoji_list(raw_value)
    emojis = normalize_reaction_emoji_list(raw_value, default: [])
    raise ConfigurationError, "Provide at least one emoji." if emojis.empty?

    emojis
  end

  def normalize_reaction_emoji_list(value, default:)
    entries = case value
              when Array
                value
              else
                value.to_s.split(/[\s,]+/)
              end

    normalized = entries.filter_map do |entry|
      reaction = normalized_reaction_string(entry)
      reaction.empty? ? nil : reaction
    end.uniq

    normalized.empty? ? default.dup : normalized
  end

  def format_reaction_emoji_list(emojis)
    normalize_reaction_emoji_list(emojis, default: DEFAULT_UPGRADE_REACTION_EMOJIS).join(", ")
  end

  def retry_request_timestamp_key(direction)
    case direction
    when :upgrade
      "upgrade_requested_at"
    when :downgrade
      "downgrade_requested_at"
    else
      raise ArgumentError, "Unsupported retry direction: #{direction.inspect}"
    end
  end

  def retry_request_already_handled?(record, direction)
    return true if record[retry_request_timestamp_key(direction)]

    direction == :upgrade && record["retry_requested_at"]
  end

  def user_configuration_error_message(context)
    return "I couldn't read my configuration for this DM. Please check the bot logs." unless context.server

    "I couldn't complete that action for this server. Please ask a server manager to check the bot logs."
  end

  def user_transcription_error_message(error)
    return error.message if error.is_a?(TranscriptionError)

    "-# i couldn't transcribe that voice note."
  end

  def whisper_progress_text(line)
    match = line.to_s.match(/^\[(?:\d{2}:)?\d{2}:\d{2}\.\d{3} --> (?:\d{2}:)?\d{2}:\d{2}\.\d{3}\]\s*(.+?)\s*$/)
    return nil unless match

    text = match[1].to_s.gsub(/\s+/, " ").strip
    text.empty? ? nil : text
  end

  def reply_with_chunks(message, content)
    Discordrb.split_message(content).map do |chunk|
      message.reply!(chunk, mention_user: false)
    end
  end

  # Like reply_with_chunks, but never raises. Used from spots (worker loop
  # rescue branches, retry-reaction handling) where an outbound Discord API
  # failure must not be allowed to propagate and take down the calling thread
  def safely_reply_with_chunks(message, content)
    reply_with_chunks(message, content)
  rescue StandardError => e
    log_warn("could not send reply", message_log_context(message, error_class: e.class.name, error: e.message))
    []
  end

  def progress_preview_words
    @progress_preview_words ||= positive_integer_env("IEARUMON_PROGRESS_PREVIEW_WORDS", DEFAULT_PROGRESS_PREVIEW_WORDS)
  end

  def progress_update_interval
    @progress_update_interval ||= positive_integer_env("IEARUMON_PROGRESS_UPDATE_INTERVAL", DEFAULT_PROGRESS_UPDATE_INTERVAL)
  end

  def transcription_request_key(request)
    "#{request.fetch(:source_message).id}:#{normalized_whisper_model_value(request.fetch(:model))}"
  end
end

Iearumon.run if $PROGRAM_NAME == __FILE__
