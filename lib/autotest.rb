require 'find'
require 'rbconfig'

$v ||= false
$TESTING = false unless defined? $TESTING

##
# Autotest continuously scans the files in your project for changes
# and runs the appropriate tests.  Test failures are run until they
# have all passed. Then the full test suite is run to ensure that
# nothing else was inadvertantly broken.
#
# If you want Autotest to start over from the top, hit ^C once.  If
# you want Autotest to quit, hit ^C twice.
#
# Rails:
#
# The autotest command will automatically discover a Rails directory
# by looking for config/environment.rb. When Rails is discovered,
# autotest uses RailsAutotest to perform file mappings and other work.
# See RailsAutotest for details.
#
# Plugins:
#
# Plugins are available by creating a .autotest file either in your
# project root or in your home directory. You can then write event
# handlers in the form of:
#
#   Autotest.add_hook hook_name { |autotest| ... }
#
# The available hooks are: initialize, run, run_command, ran_command,
#   red, green, all_good, reset, interrupt, and quit.
#
# See example_dot_autotest.rb for more details.
#
# Naming:
#
# Autotest uses a simple naming scheme to figure out how to map
# implementation files to test files following the Test::Unit naming
# scheme.
#
# * Test files must be stored in test/
# * Test files names must start with test_
# * Test class names must start with Test
# * Implementation files must be stored in lib/
# * Implementation files must match up with a test file named
#   test_.*implementation.rb
#
# Strategy:
#
# 1. Find all files and associate them from impl <-> test.
# 2. Run all tests.
# 3. Scan for failures.
# 4. Detect changes in ANY (ruby?. file, rerun all failures + changed files.
# 5. Until 0 defects, goto 3.
# 6. When 0 defects, goto 2.

class Autotest

  T0 = Time.at 0

  HOOKS = Hash.new { |h,k| h[k] = [] }
  unless defined? WINDOZE then
    WINDOZE = /win32/ =~ RUBY_PLATFORM
    SEP = WINDOZE ? '&' : ';'
  end

  @@discoveries = []

  ##
  # Add a proc to the collection of discovery procs. See
  # +autodiscover+.

  def self.add_discovery &proc
    @@discoveries << proc
  end

  ##
  # Automatically find all potential autotest runner styles by
  # searching your loadpath, vendor/plugins, and rubygems for
  # "autotest/discover.rb". If found, that file is loaded and it
  # should register discovery procs with autotest using
  # +add_discovery+. That proc should return one or more strings
  # describing the user's current environment. Those styles are then
  # combined to dynamically invoke an autotest plugin to suite your
  # environment. That plugin should define a subclass of Autotest with
  # a corresponding name.
  #
  # === Process:
  #
  # 1. All autotest/discover.rb files loaded.
  # 2. Those procs determine your styles (eg ["rails", "rspec"]).
  # 3. Require file by sorting styles and joining (eg 'autotest/rails_rspec').
  # 4. Invoke run method on appropriate class (eg Autotest::RailsRspec.run).
  #
  # === Example autotest/discover.rb:
  #
  #   Autotest.add_discovery do
  #     "rails" if File.exist? 'config/environment.rb'
  #   end
  #

  def self.autodiscover
    style = []

    $:.push(*Dir["vendor/plugins/*/lib"])
    paths = $:.dup

    begin
      require 'rubygems'
      paths.push(*Gem.latest_load_paths)
    rescue LoadError => e
      # do nothing
    end

    paths.each do |d|
      f = File.join(d, 'autotest', 'discover.rb')
      load f if File.exist? f
    end

    @@discoveries.map { |proc| proc.call }.flatten.compact.sort.uniq
  end

  ##
  # Initialize and run the system.

  def self.run
    new.run
  end

  attr_accessor(:extra_class_map,
                :extra_files,
                :files_to_test,
                :find_order,
                :interrupted,
                :last_mtime,
                :libs,
                :order,
                :output,
                :results,
                :sleep,
                :tainted,
                :test_directories,
                :unit_diff,
                :wants_to_quit)

  ##
  # Initialize the instance and then load the user's .autotest file, if any.

  def initialize
    # these two are set directly because they're wrapped with
    # add/remove/clear accessor methods
    @exception_list = []
    @test_mappings = {}

    self.extra_class_map = {}
    self.extra_files = []
    self.find_order = []
    self.files_to_test = Hash.new { |h,k| h[k] = [] }
    self.libs = %w[. lib test].join(File::PATH_SEPARATOR)
    self.order = :random
    self.output = $stderr
    self.sleep = 1
    self.test_directories = ['.']
    self.unit_diff = "unit_diff -u"

    self.add_mapping(/^lib\/.*\.rb$/) do |filename, _|
      possible = File.basename(filename).gsub '_', '_?'
      files_matching %r%^test/.*#{possible}$%
    end

    self.add_mapping(/^test.*\/test_.*rb$/) do |filename, _|
      filename
    end

    [File.expand_path('~/.autotest'), './.autotest'].each do |f|
      load f if File.exist? f
    end
  end

  ##
  # Repeatedly run failed tests, then all tests, then wait for changes
  # and carry on until killed.

  def run
    hook :initialize
    hook :run                           # TODO: phase out
    reset
    add_sigint_handler

    loop do # ^c handler
      begin
        get_to_green
        if self.tainted then
          rerun_all_tests
        else
          hook :all_good
        end
        wait_for_changes
      rescue Interrupt
        if self.wants_to_quit then
          break
        else
          reset
        end
      end
    end
    hook :quit
  end

  ##
  # Keep running the tests after a change, until all pass.

  def get_to_green
    until all_good do
      run_tests
      wait_for_changes unless all_good
    end
  end

  ##
  # Look for files to test then run the tests and handle the results.

  def run_tests
    hook :run_command

    self.find_files_to_test
    cmd = self.make_test_cmd self.files_to_test

    puts cmd unless $q

    old_sync = $stdout.sync
    $stdout.sync = true
    self.results = []
    line = []
    begin
      open("| #{cmd}", "r") do |f|
        until f.eof? do
          c = f.getc
          putc c
          line << c
          if c == ?\n then
            self.results << if RUBY_VERSION >= "1.9" then
                              line.join
                            else
                              line.pack "c*"
                            end
            line.clear
          end
        end
      end
    ensure
      $stdout.sync = old_sync
    end
    hook :ran_command
    self.results = self.results.join

    handle_results(self.results)
  end

  ############################################################
  # Utility Methods, not essential to reading of logic

  ##
  # Installs a sigint handler.

  def add_sigint_handler
    trap 'INT' do
      if self.interrupted then
        self.wants_to_quit = true
      else
        unless hook :interrupt then
          puts "Interrupt a second time to quit"
          self.interrupted = true
          Kernel.sleep 1.5
        end
        raise Interrupt, nil # let the run loop catch it
      end
    end
  end

  ##
  # If there are no files left to test (because they've all passed),
  # then all is good.

  def all_good
    files_to_test.empty?
  end

  ##
  # Convert a path in a string, s, into a class name, changing
  # underscores to CamelCase, etc.

  def path_to_classname(s)
    sep = File::SEPARATOR
    f = s.sub(/^test#{sep}/, '').sub(/\.rb$/, '').split(sep)
    f = f.map { |path| path.split(/_|(\d+)/).map { |seg| seg.capitalize }.join }
    f = f.map { |path| path =~ /^Test/ ? path : "Test#{path}"  }
    f.join('::')
  end

  ##
  # Returns a hash mapping a file name to the known failures for that
  # file.

  def consolidate_failures(failed)
    filters = Hash.new { |h,k| h[k] = [] }

    class_map = Hash[*self.find_order.grep(/^test/).map { |f|
                       [path_to_classname(f), f]
                     }.flatten]
    class_map.merge!(self.extra_class_map)

    failed.each do |method, klass|
      if class_map.has_key? klass then
        filters[class_map[klass]] << method
      else
        output.puts "Unable to map class #{klass} to a file"
      end
    end

    return filters
  end

  ##
  # Find the files to process, ignoring temporary files, source
  # configuration management files, etc., and return a Hash mapping
  # filename to modification time.

  def find_files
    result = {}
    targets = self.test_directories + self.extra_files

    Find.find(*targets) do |f|
      Find.prune if f =~ self.exceptions

      next if test ?d, f
      next if f =~ /(swp|~|rej|orig)$/          # temporary/patch files
      next if f =~ /\/\.?#/                     # Emacs autosave/cvs merge files

      filename = f.sub(/^\.\//, '')

      result[filename] = File.stat(filename).mtime rescue next
      self.find_order << filename
    end

    return result
  end

  ##
  # Find the files which have been modified, update the recorded
  # timestamps, and use this to update the files to test. Returns true
  # if any file is newer than the previously recorded most recent
  # file.

  def find_files_to_test(files=find_files)
    updated = files.select { |filename, mtime| self.last_mtime < mtime }

    p updated if $v unless updated.empty? or self.last_mtime.to_i == 0

    updated.map { |f,m| test_files_for(f) }.flatten.uniq.each do |filename|
      self.files_to_test[filename] # creates key with default value
    end

    self.last_mtime = files.values.max
    not updated.empty?
  end

  ##
  # Check results for failures, set the "bar" to red or green, and if
  # there are failures record this.

  def handle_results(results)
    failed = results.scan(/^\s+\d+\) (?:Failure|Error):\n(.*?)\((.*?)\)/)
    completed = results =~ /\d+ tests, \d+ assertions, \d+ failures, \d+ errors/

    self.files_to_test = consolidate_failures failed if completed

    hook completed && self.files_to_test.empty? ? :green : :red unless $TESTING

    self.tainted = true unless self.files_to_test.empty?
  end

  ##
  # Generate the commands to test the supplied files

  def make_test_cmd files_to_test
    cmds = []
    full, partial = reorder(files_to_test).partition { |k,v| v.empty? }

    unless full.empty? then
      classes = full.map {|k,v| k}.flatten.uniq.join(' ')
      cmds << "#{ruby} -I#{libs} -rtest/unit -e \"%w[#{classes}].each { |f| require f }\" | #{unit_diff}"
    end

    partial.each do |klass, methods|
      regexp = Regexp.union(*methods).source
      cmds << "#{ruby} -I#{libs} #{klass} -n \"/^(#{regexp})$/\" | #{unit_diff}"
    end

    return cmds.join("#{SEP} ")
  end

  def reorder files_to_test
    case self.order
    when :alpha then
      files_to_test.sort_by { |k,v| k }
    when :reverse then
      files_to_test.sort_by { |k,v| k }.reverse
    when :random then
      files_to_test.sort_by { |k,v| rand }
    when :natural then
      (self.find_order & files_to_test.keys).map { |f| [f, files_to_test[f]] }
    else
      raise "unknown order type: #{self.order.inspect}"
    end
  end

  ##
  # Rerun the tests from cold (reset state)

  def rerun_all_tests
    reset
    run_tests

    hook :all_good if all_good
  end

  ##
  # Clear all state information about test failures and whether
  # interrupts will kill autotest.

  def reset
    self.interrupted = false
    self.wants_to_quit = false
    self.find_order.clear
    self.files_to_test.clear
    self.last_mtime = T0
    self.tainted = false

    hook :reset
  end

  ##
  # Determine and return the path of the ruby executable.

  def ruby
    ruby = File.join(Config::CONFIG['bindir'],
                     Config::CONFIG['ruby_install_name'])

    ruby.gsub! File::SEPARATOR, File::ALT_SEPARATOR if File::ALT_SEPARATOR

    return ruby
  end

  ##
  # Return the name of the file with the tests for filename by finding
  # a +test_mapping+ that matches the file and executing the mapping's
  # proc.

  def test_files_for(filename)
    result = @test_mappings.find { |file_re, ignored| filename =~ file_re }
    result = result.nil? ? [] : Array(result.last.call(filename, $~))

    output.puts "Dunno! #{filename}" if ($v or $TESTING) and result.empty?

    result.sort.uniq.select { |f| @find_order.include? f }
  end

  ##
  # Sleep then look for files to test, until there are some.

  def wait_for_changes
    hook :waiting
    begin
      Kernel.sleep self.sleep
    end until find_files_to_test
  end

  ############################################################
  # File Mappings:

  ##
  # Returns all known files in the codebase matching +regexp+.

  def files_matching regexp
    self.find_order.select { |k| k =~ regexp }
  end

  ##
  # Adds a file mapping. +regexp+ should match a file path in the
  # codebase. +proc+ is passed a matched filename and
  # Regexp.last_match. +proc+ should return an array of tests to run.
  #
  # For example, if test_helper.rb is modified, rerun all tests:
  #
  #   at.add_mapping(/test_helper.rb/) do |f, _|
  #     at.files_matching(/^test.*rb$/)
  #   end

  def add_mapping(regexp, &proc)
    @test_mappings[regexp] = proc
  end

  ##
  # Removed a file mapping matching +regexp+.

  def remove_mapping regexp
    test_mappings.delete regexp
  end

  ##
  # Clears all file mappings. This is DANGEROUS as it entirely
  # disables autotest. You must add at least one file mapping that
  # does a good job of rerunning appropriate tests.

  def clear_mappings
    @test_mappings.clear
  end

  ############################################################
  # Exceptions:

  ##
  # Adds +regexp+ to the list of exceptions for find_file. This must
  # be called _before_ the exceptions are compiled.

  def add_exception regexp
    raise "exceptions already compiled" if defined? @exceptions
    @exception_list << regexp
  end

  ##
  # Removes +regexp+ to the list of exceptions for find_file. This
  # must be called _before_ the exceptions are compiled.

  def remove_exception regexp
    raise "exceptions already compiled" if defined? @exceptions
    @exception_list.delete regexp
  end

  ##
  # Clears the list of exceptions for find_file. This must be called
  # _before_ the exceptions are compiled.

  def clear_exceptions
    raise "exceptions already compiled" if defined? @exceptions
    @exception_list.clear
  end

  ##
  # Return a compiled regexp of exceptions for find_files or nil if no
  # filtering should take place. This regexp is generated from
  # +exception_list+.

  def exceptions
    unless defined? @exceptions then
      if @exception_list.empty? then
        @exceptions = nil
      else
        @exceptions = Regexp.union(*@exception_list)
      end
    end

    @exceptions
  end

  ############################################################
  # Hooks:

  ##
  # Call the event hook named +name+, executing all registered hooks
  # until one returns true. Returns false if no hook handled the
  # event.

  def hook(name)
    deprecated = {
      :run => :initialize,      # TODO: remove 2008-03-14 (pi day!)
    }

    if deprecated[name] and not HOOKS[name].empty? then
      warn "hook #{name} has been deprecated, use #{deprecated[name]}"
    end

    HOOKS[name].inject(false) do |handled,plugin|
      plugin[self] || handled
    end
  end

  ##
  # Add the supplied block to the available hooks, with the given
  # name.

  def self.add_hook(name, &block)
    HOOKS[name] << block
  end
end
