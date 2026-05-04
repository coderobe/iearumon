#!/usr/bin/env bundle exec ruby
# frozen_string_literal: true

require "discordrb"
require "open-uri"
require "open3"
require "shellwords"
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
      next unless voice_note_message?(event.message)

      Thread.new do
        handle_voice_note(event.message)
      rescue ConfigurationError, TranscriptionError, OpenURI::HTTPError, SocketError => e
        bot.debug("voice note transcription failed: #{e.class}: #{e.message}")
        reply_with_chunks(event.message, "I couldn't transcribe that voice note: #{e.message}")
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
      Discordrb::INTENTS.fetch(:direct_messages) |
      MESSAGE_CONTENT_INTENT
  end

  def handle_voice_note(message)
    attachment = voice_note_attachment(message)
    raise TranscriptionError, "No voice note attachment was found." unless attachment

    message.react(EAR_EMOJI)

    transcript = with_downloaded_attachment(attachment) do |path|
      transcribe(path)
    end

    reply_with_chunks(message, "Transcription:\n#{transcript}")
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
