# Encoding: utf-8
# ASP.NET Core Buildpack
# Copyright 2014-2016 the original author or authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require_relative '../bp_version.rb'
require_relative 'dotnet_framework.rb'
require_relative './installers/installer.rb'
require_relative './installers/libunwind_installer.rb'
require_relative './installers/dotnet_sdk_installer.rb'
require_relative './installers/nodejs_installer.rb'
require_relative './installers/bower_installer.rb'

require 'json'
require 'pathname'

module AspNetCoreBuildpack
  class Compiler
    CACHE_NUGET_PACKAGES_VAR = 'CACHE_NUGET_PACKAGES'.freeze
    NUGET_CACHE_DIR = '.nuget'.freeze

    def initialize(build_dir, cache_dir, copier, installers, out)
      @build_dir = build_dir
      @cache_dir = cache_dir
      @copier = copier
      @out = out
      @app_dir = AppDir.new(@build_dir)
      @shell = AspNetCoreBuildpack.shell
      @installers = installers
      @dotnet_sdk = installers.find { |installer| /(.*)::DotnetSdkInstaller/.match(installer.class.name) }
      @manifest_file = File.join(File.dirname(__FILE__), '..', '..', '..', 'manifest.yml')
    end

    def compile
      puts "ASP.NET Core buildpack version: #{BuildpackVersion.new.version}\n"
      puts "ASP.NET Core buildpack starting compile\n"
      step('Restoring files from buildpack cache', method(:restore_cache))
      step('Clearing NuGet packages cache', method(:clear_nuget_cache)) if should_clear_nuget_cache?
      step('Restoring NuGet packages cache', method(:restore_nuget_cache))

      run_installers

      step('Restoring dependencies with Dotnet CLI', @dotnet_sdk.method(:restore)) if should_restore?

      unless @dotnet_sdk.nil?
        @dotnet_framework = DotnetFramework.new(@build_dir, File.join(@build_dir, NUGET_CACHE_DIR), File.join(@build_dir, @dotnet_sdk.cache_dir), shell)
        step('Installing .NET Framework(s)', @dotnet_framework.method(:install))
      end

      step('Saving to buildpack cache', method(:save_cache))
      puts "ASP.NET Core buildpack is done creating the droplet\n"
      return true
    rescue StepFailedError => e
      out.fail(e.message)
      return false
    end

    private

    def clear_nuget_cache(_out)
      FileUtils.rm_rf(File.join(cache_dir, NUGET_CACHE_DIR))
    end

    def should_restore?
      @dotnet_sdk.should_restore(@app_dir) unless @dotnet_sdk.nil?
    end

    def nuget_cache_is_valid?
      return false if @dotnet_sdk.nil? || !File.exist?(File.join(cache_dir, NUGET_CACHE_DIR))
      !@dotnet_sdk.should_install(@app_dir)
    end

    def run_installers
      @installers.each do |installer|
        step(installer.install_description, installer.method(:install)) if installer.should_install(@app_dir)
      end
    end

    def restore_cache(out)
      @installers.map(&:cache_dir).compact.each do |installer_cache_dir|
        copier.cp(File.join(cache_dir, installer_cache_dir), build_dir, out) if File.exist? File.join(cache_dir, installer_cache_dir)
      end
    end

    def restore_nuget_cache(out)
      copier.cp(File.join(cache_dir, NUGET_CACHE_DIR), build_dir, out) if nuget_cache_is_valid?
    end

    def save_cache(out)
      @installers.select { |installer| !installer.cache_dir.nil? }.compact.each do |installer|
        save_installer_cache(out, installer.name, installer.cache_dir)
      end
      save_installer_cache(out, 'Nuget packages'.freeze, NUGET_CACHE_DIR) if should_save_nuget_cache?
    end

    def save_installer_cache(out, name, installer_cache_dir)
      copier.cp(File.join(build_dir, installer_cache_dir), cache_dir, out) if File.exist? File.join(build_dir, installer_cache_dir)
    rescue
      out.fail("Failed to save cached files for #{name}")
      FileUtils.rm_rf(File.join(cache_dir, installer_cache_dir)) if File.exist? File.join(cache_dir, installer_cache_dir)
    end

    def should_clear_nuget_cache?
      File.exist?(File.join(cache_dir, NUGET_CACHE_DIR)) && (ENV[CACHE_NUGET_PACKAGES_VAR] == 'false' || !nuget_cache_is_valid?)
    end

    def should_save_nuget_cache?
      File.exist?(File.join(build_dir, NUGET_CACHE_DIR)) && ENV[CACHE_NUGET_PACKAGES_VAR] != 'false'
    end

    def step(description, method)
      s = out.step(description)
      begin
        method.call(s)
      rescue => e
        s.fail(e.message)
        raise StepFailedError, "#{description} failed, #{e.message}"
      end

      s.succeed
    end

    attr_reader :app_dir
    attr_reader :build_dir
    attr_reader :cache_dir
    attr_reader :installers
    attr_reader :copier
    attr_reader :out
    attr_reader :shell
  end

  class StepFailedError < StandardError
  end
end
