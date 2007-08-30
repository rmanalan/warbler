#--
# (c) Copyright 2007 Nick Sieger <nicksieger@gmail.com>
# See the file LICENSES.txt included with the distribution for
# software license details.
#++

require 'rake'
require 'rake/tasklib'

module Warbler
  # Warbler Rake task.  Allows defining multiple configurations inside the same 
  # Rakefile by using different task names.
  class Task < Rake::TaskLib
    COPY_PROC = proc {|t| cp t.prerequisites.last, t.name }

    # Task name
    attr_accessor :name

    # Warbler::Config
    attr_accessor :config

    # Whether to print a line when a file or directory task is declared; helps
    # to see what is getting included
    attr_accessor :verbose

    def initialize(name = :war, config = nil, tasks = :define_tasks)
      @name   = name
      @config = config
      if @config.nil? && File.exists?(Config::FILE)
        @config = eval(File.open(Config::FILE) {|f| f.read})
      end
      @config ||= Config.new
      unless @config.kind_of? Config
        warn "War::Config not provided by override in initializer or #{Config::FILE}; using defaults"
        @config = Config.new
      end
      yield self if block_given?
      send tasks
    end

    private
    def define_tasks
      define_main_task
      define_clean_task
      define_public_task
      define_gems_task
      define_webxml_task
      define_app_task
      define_jar_task
      define_debug_task
    end

    def define_main_task
      desc "Create #{@config.war_name}.war"
      task @name => ["#{@name}:app", "#{@name}:public", "#{@name}:webxml", "#{@name}:jar"]
    end

    def define_clean_task
      with_namespace_and_config do |name, config|
        desc "Clean up the .war file and the staging area"
        task "clean" do
          rm_rf config.staging_dir
          rm_f "#{config.war_name}.war"
        end
        task "clear" => "#{name}:clean"
      end
    end

    def define_public_task
      public_target_files = define_public_file_tasks
      with_namespace_and_config do
        desc "Copy all public HTML files to the root of the .war"
        task "public" => public_target_files
      end
    end

    def define_gems_task
      directory "#{@config.gem_target_path}/gems"
      targets = define_copy_gems_tasks
      with_namespace_and_config do
        desc "Unpack all gems into WEB-INF/gems"
        task "gems" => targets
      end
    end

    def define_webxml_task
      with_namespace_and_config do |name, config|
        desc "Generate a web.xml file for the webapp"
        task "webxml" do
          mkdir_p "#{config.staging_dir}/WEB-INF"
          if File.exist?("config/web.xml")
            cp "config/web.xml", "#{config.staging_dir}/WEB-INF"
          else
            erb = if File.exist?("config/web.xml.erb")
              "config/web.xml.erb"
            else
              "#{WARBLER_HOME}/web.xml.erb"
            end
            require 'erb'
            erb = ERB.new(File.open(erb) {|f| f.read })
            File.open("#{config.staging_dir}/WEB-INF/web.xml", "w") do |f| 
              f << erb.result(erb_binding(config.webxml))
            end
          end
        end
      end
    end

    def define_java_libs_task
      target_files = @config.java_libs.map do |lib|
        define_file_task(lib,
          "#{@config.staging_dir}/WEB-INF/lib/#{File.basename(lib)}")
      end
      with_namespace_and_config do |name, config|
        desc "Copy all java libraries into the .war"
        task "java_libs" => target_files
      end
      target_files
    end

    def define_app_task
      webinf_target_files = define_webinf_file_tasks
      with_namespace_and_config do |name, config|
        desc "Copy all application files into the .war"
        task "app" => ["#{name}:gems", *webinf_target_files]
      end
    end

    def define_jar_task
      with_namespace_and_config do |name, config|
        desc "Run the jar command to create the .war"
        task "jar" do
          sh "jar", "cf", "#{config.war_name}.war", "-C", config.staging_dir, "."
        end
      end
    end

    def define_debug_task
      with_namespace_and_config do |name, config|
        task "debug" do
          require 'pp'
          pp config
        end
      end
    end

    def define_public_file_tasks
      @config.public_html.map do |f|
        define_file_task(f, "#{@config.staging_dir}/#{f.sub(%r{public/},'')}")
      end
    end

    def define_webinf_file_tasks
      files = FileList[*@config.dirs.map{|d| "#{d}/**/*"}]
      files.include(*@config.includes.to_a)
      files.exclude(*@config.excludes.to_a)
      target_files = files.map do |f|
        define_file_task(f, "#{@config.staging_dir}/WEB-INF/#{f}")
      end
      target_files += define_java_libs_task
      target_files
    end

    def define_file_task(source, target)
      if File.directory?(source)
        directory target
        puts %{directory "#{target}"} if verbose
      else
        directory File.dirname(target)
        file(target => [File.dirname(target), source], &COPY_PROC)
        puts %{file "#{target}" => "#{source}"} if verbose
      end
      target
    end

    def with_namespace_and_config
      name, config = @name, @config
      namespace name do
        yield name, config
      end
    end

    def define_copy_gems_tasks
      targets = []
      @config.gems.each do |gem|
        define_single_gem_tasks(gem, targets)
      end
      targets
    end

    def define_single_gem_tasks(gem, targets, version = nil)
      matched = Gem.source_index.search(gem, version)
      fail "gem '#{gem}' not installed" if matched.empty?
      spec = matched.last
      
      gem_unpack_task_name = "gem:#{spec.name}-#{spec.version}"
      return if Rake::Task.task_defined?(gem_unpack_task_name)

      targets << define_file_task(spec.loaded_from, 
        "#{config.gem_target_path}/specifications/#{File.basename(spec.loaded_from)}")

      task targets.last do
        Rake::Task[gem_unpack_task_name].invoke
      end

      task gem_unpack_task_name => ["#{config.gem_target_path}/gems"] do |t|
        Dir.chdir(t.prerequisites.last) do
          ruby "-S", "gem", "unpack", "-v", spec.version.to_s, spec.name
        end
      end

      if @config.gem_dependencies
        spec.dependencies.each do |dep|
          define_single_gem_tasks(dep.name, targets, dep.version_requirements)
        end
      end
    end

    def erb_binding(webxml)
      binding
    end
  end
end