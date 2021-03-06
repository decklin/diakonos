#!/usr/bin/env ruby

# == Diakonos
#
# A usable console text editor.
# :title: Diakonos
#
# Author:: Pistos (irc.freenode.net)
# http://purepistos.net/diakonos
# Copyright (c) 2004-2009 Pistos
#
# This software is released under the MIT licence.
# See the LICENCE file included with this program, or
# http://www.opensource.org/licenses/mit-license.php
#
require 'curses'
require 'open3'
require 'thread'
require 'English'
require 'set'
require 'yaml'
require 'digest/md5'

require 'diakonos/object'
require 'diakonos/enumerable'
require 'diakonos/regexp'
require 'diakonos/sized-array'
require 'diakonos/hash'
require 'diakonos/buffer-hash'
require 'diakonos/string'
require 'diakonos/fixnum'
require 'diakonos/bignum'

require 'diakonos/version'
require 'diakonos/installation'
require 'diakonos/config'
require 'diakonos/functions'
require 'diakonos/functions-deprecated'
require 'diakonos/help'
require 'diakonos/display'
require 'diakonos/display/format'
require 'diakonos/interaction'
require 'diakonos/hooks'
require 'diakonos/keying'
require 'diakonos/logging'
require 'diakonos/list'
require 'diakonos/buffer-management'
require 'diakonos/sessions'
require 'diakonos/grep'

require 'diakonos/text-mark'
require 'diakonos/bookmark'
require 'diakonos/ctag'
require 'diakonos/finding'
require 'diakonos/buffer'
require 'diakonos/buffer/bookmarking'
require 'diakonos/buffer/cursor'
require 'diakonos/buffer/delete'
require 'diakonos/buffer/display'
require 'diakonos/buffer/indentation'
require 'diakonos/buffer/file'
require 'diakonos/buffer/searching'
require 'diakonos/buffer/selection'
require 'diakonos/buffer/undo'
require 'diakonos/clipboard'
require 'diakonos/readline'

require 'diakonos/vendor/fuzzy_file_finder'


module Diakonos

  DONT_ADJUST_ROW       = false
  ADJUST_ROW            = true
  PROMPT_OVERWRITE      = true
  DONT_PROMPT_OVERWRITE = false
  QUIET                 = true
  NOISY                 = false

  DEFAULT_TAB_SIZE = 8

  FORCE_REVERT = true
  ASK_REVERT   = false

  ASK_REPLACEMENT = true

  CASE_SENSITIVE   = true
  CASE_INSENSITIVE = false

  LANG_TEXT = 'text'

  NUM_LAST_COMMANDS = 2

  class Diakonos

    attr_reader :diakonos_home, :script_dir, :clipboard,
      :list_filename, :hooks, :indenters, :unindenters, :closers,
      :last_commands, :there_was_non_movement, :do_display, :testing

    include ::Diakonos::Functions

    def initialize( argv = [] )
      @diakonos_home = File.expand_path( ( ENV[ 'HOME' ] || '' ) + '/.diakonos' )
      mkdir @diakonos_home
      @script_dir = "#{@diakonos_home}/scripts"
      mkdir @script_dir
      @session_dir = "#{@diakonos_home}/sessions"
      mkdir @session_dir
      new_session "#{@session_dir}/#{Process.pid}"

      @files = Array.new
      @read_only_files = Array.new
      @config_filename = nil
      parse_options argv

      init_help

      @debug          = File.new( "#{@diakonos_home}/debug.log", 'w' )
      @list_filename  = @diakonos_home + '/listing.txt'
      @diff_filename  = @diakonos_home + '/text.diff'
      @help_filename  = "#{@help_dir}/about-help.dhf"
      @error_filename = "#{@diakonos_home}/diakonos.err"

      @win_main         = nil
      @win_context      = nil
      @win_status       = nil
      @win_interaction  = nil
      @win_line_numbers = nil
      @buffers = BufferHash.new

      load_configuration

      @quitting    = false
      @untitled_id = 0

      @x = 0
      @y = 0

      @buffer_stack           = Array.new
      @current_buffer         = nil
      @buffer_history         = Array.new
      @buffer_history_pointer = nil
      @bookmarks              = Hash.new
      @macro_history          = nil
      @macro_input_history    = nil
      @macros                 = Hash.new
      @last_commands          = SizedArray.new( NUM_LAST_COMMANDS )
      @playing_macro          = false
      @display_mutex          = Mutex.new
      @display_queue_mutex    = Mutex.new
      @display_queue          = nil
      @do_display             = true
      @iline_mutex            = Mutex.new
      @tag_stack              = Array.new
      @last_search_regexps    = nil
      @iterated_choice        = nil
      @choice_iterations      = 0
      @there_was_non_movement = false
      @status_vars            = Hash.new

      # Readline histories
      @rlh_general  = Array.new
      @rlh_files    = Array.new
      @rlh_search   = Array.new
      @rlh_shell    = Array.new
      @rlh_help     = Array.new
      @rlh_sessions = Array.new

      @hooks = {
        :after_buffer_switch => [],
        :after_open          => [],
        :after_save          => [],
        :after_startup       => [],
      }
    end

    def mkdir( dir )
      if not FileTest.exists? dir
        Dir.mkdir dir
      end
    end

    def parse_options( argv )
      @post_load_script = ""
      while argv.length > 0
        arg = argv.shift
        case arg
        when '-c', '--config'
          @config_filename = argv.shift
          if @config_filename.nil?
            print_usage
            exit 1
          end
        when '-e', '--execute'
          post_load_script = argv.shift
          if post_load_script.nil?
            print_usage
            exit 1
          else
            @post_load_script << "\n#{post_load_script}"
          end
        when '-h', '--help'
          print_usage
          exit 1
        when '-m', '--open-matching'
          regexp = argv.shift
          files = `egrep -rl '#{regexp}' *`.split( /\n/ )
          if files.any?
            @files.concat files
            script = "\nfind 'down', CASE_SENSITIVE, '#{regexp}'"
            @post_load_script << script
          end
        when '-ro'
          filename = argv.shift
          if filename.nil?
            print_usage
            exit 1
          else
            @read_only_files.push filename
          end
        when '-s', '--load-session'
          @session_to_load = session_filepath_for( argv.shift )
        when '--test', '--testing'
          @testing = true
        when '--uninstall'
          uninstall
        when '--uninstall-without-confirmation'
          uninstall false
        when '--version'
          puts "Diakonos #{::Diakonos::VERSION} (#{::Diakonos::LAST_MODIFIED})"
          exit 0
        else
          # a name of a file to open
          @files.push arg
        end
      end
    end
    protected :parse_options

    def print_usage
      puts "Usage: #{$0} [options] [file] [file...]"
      puts "\t--help\tDisplay usage"
      puts "\t-c <config file>\tLoad this config file instead of ~/.diakonos/diakonos.conf"
      puts "\t-e, --execute <Ruby code>\tExecute Ruby code (such as Diakonos commands) after startup"
      puts "\t-m, --open-matching <regular expression>\tOpen all matching files under current directory"
      puts "\t-ro <file>\tLoad file as read-only"
      puts "\t-s, --load-session <session identifier>\tLoad a session"
      puts "\t--uninstall[-without-confirmation]\tUninstall Diakonos"
    end
    protected :print_usage

    def clear_non_movement_flag
      @there_was_non_movement = false
    end

    # -----------------------------------------------------------------------

    def start
      require 'diakonos/window'

      initialize_display

      if ENV[ 'COLORTERM' ] == 'gnome-terminal'
        help_key = 'Shift-F1'
      else
        help_key = 'F1'
      end
      set_iline "Diakonos #{VERSION} (#{LAST_MODIFIED})   #{help_key} for help  F12 to configure  Ctrl-Q to quit"

      if @session_to_load
        pid_session = @session
        @session = nil
        session_path = session_filepath_for( @session_to_load )
        load_session_data session_path
        if @session
          @files.concat @session[ 'files' ]
        else
          new_session session_path
        end
      else
        session_buffers = []

        session_files = Dir[ "#{@session_dir}/*" ].grep( %r{/\d+$} )
        pids = session_files.map { |sf| sf[ %r{/(\d+)$}, 1 ].to_i }
        pids.each do |pid|
          begin
            Process.kill 0, pid
            session_files.reject! { |sf| pid_session? sf }
          rescue Errno::ESRCH, Errno::EPERM
            # Process is no longer alive, so we consider the session stale
          end
        end

        session_files.each_with_index do |session_file,index|
          session_buffers << open_file( session_file )

          choice = get_choice(
            "#{session_files.size} unclosed session(s) found.  Open the above files?  (session #{index+1} of #{session_files.size})",
            [ CHOICE_YES, CHOICE_NO, CHOICE_DELETE ]
          )

          case choice
          when CHOICE_YES
            load_session_data session_file
            if @session
              @files.concat @session[ 'files' ]
              File.delete session_file
              break
            end
          when CHOICE_DELETE
            File.delete session_file
          end
        end

        if session_buffers.empty? and @files.empty? and @settings[ 'session.default_session' ]
          session_file = session_filepath_for( @settings[ 'session.default_session' ] )
          if File.exist? session_file
            load_session_data session_file
            if @session
              @files.concat @session[ 'files' ]
            end
          end
        end
      end

      Dir[ "#{@script_dir}/*" ].each do |script|
        begin
          require script
        rescue Exception => e
          show_exception(
            e,
            [
              "There is a syntax error in the script.",
              "An invalid hook name was used."
            ]
          )
        end
      end
      @hooks.each do |hook_name, hook|
        hook.sort { |a,b| a[ :priority ] <=> b[ :priority ] }
      end

      num_opened = 0
      if @files.length == 0 and @read_only_files.length == 0
        num_opened += 1  if open_file
      else
        @files.each do |file|
          num_opened += 1  if open_file file
        end
        @read_only_files.each do |file|
          num_opened += 1  if open_file( file, Buffer::READ_ONLY )
        end
      end

      if session_buffers
        session_buffers.each do |buffer|
          close_file buffer
        end
      end

      if num_opened > 0
        switch_to_buffer_number 1

        update_status_line
        update_context_line

        if @post_load_script
          eval @post_load_script
        end

        run_hook_procs :after_startup

        if not @settings[ 'suppress_welcome' ]
          open_file "#{@help_dir}/welcome.dhf"
        end

        begin
          # Main keyboard loop.
          while not @quitting
            process_keystroke
            @win_main.refresh
          end
        rescue SignalException => e
          debug_log "Terminated by signal (#{e.message})"
        end

        cleanup_display

        if pid_session?
          File.delete @session[ 'filename' ]
        end

        @debug.close
      end
    end

    def uninstall( confirm = true )
      inst = ::Diakonos::INSTALL_SETTINGS[ :installed ]

      if confirm
        puts inst[ :files ].sort.join( "\n" )
        puts
        puts inst[ :dirs ].sort.map { |d| "#{d}/" }.join( "\n" )
        puts
        puts "The above files will be removed.  The above directories will be removed if they are empty.  Proceed?  (y/n)"
        answer = $stdin.gets
        case answer
        when /^y/i
          puts "Deleting..."
        when /^n/i
          puts "Uninstallation aborted."
          exit 1
        end
      end

      require 'fileutils'
      inst[ :files ].each do |f|
        FileUtils.rm f
      end
      inst[ :dirs ].sort { |d1,d2| d2.length <=> d1.length }.each do |d|
        begin
          FileUtils.rmdir d
        rescue Errno::ENOTEMPTY
        end
        if File.exists? d
          $stderr.puts "(#{d} not removed)"
        end
      end

      exit 0
    end

    def get_language_from_name( name )
      retval = nil
      @filemasks.each do |language,filemask|
        if name =~ filemask
          retval = language
          break
        end
      end
      retval
    end

    def get_language_from_shabang( first_line )
      retval = nil
      @bangmasks.each do |language,bangmask|
        if first_line =~ bangmask
          retval = language
          break
        end
      end
      retval
    end

    def show_exception( e, probable_causes = [ "Unknown" ] )
      begin
        File.open( @error_filename, "w" ) do |f|
          f.puts "Diakonos Error:"
          f.puts
          f.puts "#{e.class}: #{e.message}"
          f.puts
          f.puts "Probable Causes:"
          f.puts
          probable_causes.each do |pc|
            f.puts "- #{pc}"
          end
          f.puts
          f.puts "----------------------------------------------------"
          f.puts "If you can reproduce this error, please report it at"
          f.puts "http://linis.purepistos.net/ticket/list/Diakonos !"
          f.puts "----------------------------------------------------"
          f.puts e.backtrace
        end
        open_file @error_filename
      rescue Exception => e2
        debug_log "EXCEPTION: #{e.message}"
        debug_log "\t#{e.backtrace}"
      end
    end

    def start_recording_macro( name = nil )
      return if @macro_history
      @macro_name = name
      @macro_history = Array.new
      @macro_input_history = Array.new
      set_iline "Started macro recording."
    end
    protected :start_recording_macro

    def stop_recording_macro
      @macro_history.pop  # Remove the stop_recording_macro command itself
      @macros[ @macro_name ] = [ @macro_history, @macro_input_history ]
      @macro_history = nil
      @macro_input_history = nil
      set_iline "Stopped macro recording."
    end
    protected :stop_recording_macro

    def load_tags
      @tags = Hash.new
      if @current_buffer and @current_buffer.name
        path = File.expand_path( File.dirname( @current_buffer.name ) )
        tagfile = path + "/tags"
      else
        tagfile = "./tags"
      end
      if FileTest.exists? tagfile
        IO.foreach( tagfile ) do |line_|
          line = line_.chomp
          # <tagname>\t<filepath>\t<line number or regexp>\t<kind of tag>
          tag, file, command, kind, rest = line.split( /\t/ )
          command.gsub!( /;"$/, "" )
          if command =~ /^\/.*\/$/
            command = command[ 1...-1 ]
          end
          @tags[ tag ] ||= Array.new
          @tags[ tag ].push CTag.new( file, command, kind, rest )
        end
      else
        set_iline "(tags file not found)"
      end
    end

    def write_to_clip_file( text )
      clip_filename = @diakonos_home + "/clip.txt"
      File.open( clip_filename, "w" ) do |f|
        f.print text
      end
      clip_filename
    end

    # Returns true iff some text was copied to klipper.
    def send_to_klipper( text )
      return false if text.nil?

      clip_filename = write_to_clip_file( text.join( "\n" ) )
      # A little shell sorcery to ensure the shell doesn't strip off trailing newlines.
      # Thank you to pgas from irc.freenode.net#bash for help with this.
      `clipping=$(cat #{clip_filename};printf "_"); dcop klipper klipper setClipboardContents "${clipping%_}"`
      true
    end

    def settings
      @settings.merge @session[ 'settings' ]
    end

    def escape_quotes( str )
      temp = ''
      str.each_byte do |b|
        if b == 39
          temp << 39
          temp << 92
          temp << 39
        end
        temp << b
      end
      temp
    end

    def direction_of( str, default = :down )
      case str
      when "up"
        :up
      when /other/
        :opposite
      when "down"
        :down
      when "forward"
        :forward
      when "backward"
        :backward
      else
        default
      end
    end

  end

end

if __FILE__ == $PROGRAM_NAME
  $diakonos = Diakonos::Diakonos.new( ARGV )
  $diakonos.start
end
