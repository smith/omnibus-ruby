#
# Copyright:: Copyright (c) 2012 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

module Omnibus
  class HealthCheck

    WHITELIST_LIBS = [
                      /ld-linux/,
                      /libc\.so/,
                      /libcrypt\.so/,
                      /libdl/,
                      /libfreebl\d\.so/,
                      /libgcc_s\.so/,
                      /libm\.so/,
                      /libnsl\.so/,
                      /libpthread/,
                      /libresolv\.so/,
                      /librt\.so/,
                      /libstdc\+\+\.so/,
                      /libutil\.so/,
                      /linux-vdso.+/
                      ]

    SOLARIS_WHITELIST_LIBS = [
                              /libaio\.so/,
                              /libavl\.so/,
                              /libcrypt_[di]\.so/,
                              /libcrypto.so/,
                              /libcurses\.so/,
                              /libdoor\.so/,
                              /libgen\.so/,
                              /libmd5\.so/,
                              /libmd\.so/,
                              /libmp\.so/,
                              /libscf\.so/,
                              /libsec\.so/,
                              /libsocket\.so/,
                              /libssl.so/,
			      /libthread.so/,
                              /libuutil\.so/,
			      /libz.so/
                             ]
    
    WHITELIST_FILES = [
                       /jre\/bin\/javaws/,
                       /jre\/bin\/policytool/,
                       /jre\/lib/
                      ]

    WHITELIST_LIBS.push(*SOLARIS_WHITELIST_LIBS)

    def self.log(msg)
      puts "[health_check] #{msg}"
    end

    def self.run(install_dir)
      #
      # ShellOut has GC turned off during execution, so when we're
      # executing extremely long commands with lots of output, we
      # should be mindful that the string concatentation for building
      # #stdout will hurt memory usage drastically
      #
      ldd_cmd = "find #{install_dir}/ -type f | xargs ldd > ldd.out 2>/dev/null"
      log "Executing `#{ldd_cmd}`"
      shell = Mixlib::ShellOut.new(ldd_cmd, :timeout => 3600)
      shell.run_command

      ldd_output = File.read('ldd.out')

      current_library = nil
      bad_libs = {}

      ldd_output.each_line do |line|
        case line
        when /^(.+):$/
          current_library = $1
	  log "*** Analysing dependencies for #{current_library}" if ARGV[0] == "verbose"
        when /^\s+(.+) \=\>\s+(.+)( \(.+\))?$/
          name = $1
          linked = $2
	  log "  --> Dependency: #{name}" if ARGV[0] == "verbose"
	  log "  --> Provided by: #{linked}" if ARGV[0] == "verbose"
          safe = nil
          WHITELIST_LIBS.each do |reg| 
            safe ||= true if reg.match(name)
          end
          WHITELIST_FILES.each do |reg|
            safe ||= true if reg.match(current_library)
          end

          if !safe && linked !~ Regexp.new(install_dir)
	    log "    -> FAILED: #{current_library} has unsafe dependencies" if ARGV[0] == "verbose"
            bad_libs[current_library] ||= {}
            bad_libs[current_library][name] ||= {} 
            if bad_libs[current_library][name].has_key?(linked)
              bad_libs[current_library][name][linked] += 1 
              
            else
              bad_libs[current_library][name][linked] = 1 
            end
          else
            log "    -> PASSED: #{name} is either whitelisted or safely provided." if ARGV[0] == "verbose"
          end
        when /^\s+(.+) \(.+\)$/
          next
        when /^\s+statically linked$/
          next
        when /^\s+libjvm.so/
          next
        when /^\s+libjava.so/
          next
        when /^\s+libmawt.so/
          next
        when /^\s+not a dynamic executable$/ # ignore non-executable files
        else
          log "*** Line did not match for #{current_library}\n#{line}"
        end
      end

      File.delete('ldd.out')
      

      unresolved = []
      unreliable = []
      detail = []
      if bad_libs.keys.length > 0
        bad_libs.each do |name, lib_hash|
          lib_hash.each do |lib, linked_libs|
           linked_libs.each do |linked, count|
              if linked =~ /not found/
                unresolved << lib unless unresolved.include? lib
              else
                unreliable << linked unless unreliable.include? linked
              end
                detail << "#{name}|#{lib}|#{linked}|#{count}"
            end
          end
        end
        log "*** Health Check Failed, Summary follows:"
        bad_omnibus_libs, bad_omnibus_bins = bad_libs.keys.partition { |k| k.include? "embedded/lib" }
        log "*** The following Omnibus-built libraries have unsafe or unmet dependencies:"
        bad_omnibus_libs.each { |lib| log "    --> #{lib}" }
        log "*** The following Omnibus-built binaries have unsafe or unmet dependencies:"
        bad_omnibus_bins.each { |bin| log "    --> #{bin}" }
        if unresolved.length > 0
          log "*** The following requirements could not be resolved:"
          unresolved.each { |lib| log "    --> #{lib}"}
        end
        if unreliable.length > 0
          log "*** The following libraries cannot be guaranteed to be on target systems:"
          unreliable.each { |lib| log "    --> #{lib}"}
        end
        log "*** The precise failures were:"
        detail.each do |line|
          item, dependency, location, count = line.split('|')
          reason = location =~ /not found/ ? "Unresolved dependency" : "Unsafe dependency"
          log "    --> #{item}"
          log "    DEPENDS ON: #{dependency}"
          log "      COUNT: #{count}"
          log "      PROVIDED BY: #{location}"
          log "      FAILED BECAUSE: #{reason}"
        end
	raise "Health Check Failed"
      end
    end

  end
end
