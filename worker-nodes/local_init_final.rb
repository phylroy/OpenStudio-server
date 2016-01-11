# Initialize workers with required data.  This is called via bundler therefore, only gems that are installed on the
# server are able to be used. To add a new library/gem, make sure to add it to the Gemfile and re-configure the
# server/worker.

require 'bundler'
require 'openstudio'
#require 'openstudio-workflow'
begin
  Bundler.setup
rescue Bundler::BundlerError => e
  $stderr.puts e.message
  $stderr.puts 'Run `bundle install` to install missing gems'
  exit e.status_code
end

require 'optparse'
require 'fileutils'
require 'logger'
require 'zip'

  def unzip_archive(archive_filename, destination, overwrite = true)
      Zip::File.open(archive_filename) do |zf|
        zf.each do |f|
          f_path = File.join(destination, f.name)
          FileUtils.mkdir_p(File.dirname(f_path))

          if File.exist?(f_path) && overwrite
            FileUtils.rm_rf(f_path)
            zf.extract(f, f_path)
          elsif !File.exist? f_path
            zf.extract(f, f_path)
          end
        end
      end
  end

puts "Parsing Input: #{ARGV}"

# parse arguments with optparse
options = {}
optparse = OptionParser.new do |opts|
  opts.on('-a', '--analysis_id UUID', String, 'UUID of the analysis.') do |analysis_id|
    options[:analysis_id] = analysis_id
  end

  opts.on('-s', '--state initialize_or_finalize ', String, 'Initializing or finalizing') do |state|
    options[:state] = state
  end

  opts.on('-r' '--root_path path', String, 'Root path for analysis run') do |root_path|
    options[:root_path] = root_path
  end
end
optparse.parse!

unless options[:analysis_id]
  # required argument is missing
  puts optparse
  exit
end

unless options[:state]
  puts "State is required (either 'initialize' or 'finalize')"
  exit
end

if options[:root_path]
  analysis_root = options[:root_path]
else
  puts "Assuming analysis_root to be '\mnt\openstudio'"
  analysis_root = '\mnt\openstudio'
end

# Set the result of the project for R to know that this finished
result = false
begin
  # Logger for the simulate datapoint
  FileUtils.mkdir_p "#{analysis_root}/analysis_#{options[:analysis_id]}" unless Dir.exist? "#{analysis_root}/analysis_#{options[:analysis_id]}"
  logger = Logger.new("#{analysis_root}/analysis_#{options[:analysis_id]}/worker_#{options[:state]}.log")

  analysis_dir = "#{analysis_root}/analysis_#{options[:analysis_id]}"
  logger.info "analysis_root: #{analysis_root}"
  logger.info "analysis_dir: #{analysis_dir}"
  logger.info "Running #{__FILE__}"

  # Download the zip file from the server
  download_file = "#{analysis_dir}/analysis.zip"
  analysis_file = 'C:/Projects/PAT20/zip/local.zip'
  download_url = "http://127.0.0.1:3000/analyses/#{options[:analysis_id]}/download_analysis_zip"

  #TODO get faraday & rubyzip working here
  if ((!File.exist? download_file) && (File.exist? analysis_file))
    logger.info "Copying project zip from #{analysis_file} to #{download_file}"
    FileUtils.cp(analysis_file, download_file)
    #`curl -o #{download_file} #{download_url}`
  end
  
  #how to unzip with workflow
  unzip_archive("#{analysis_dir}/analysis.zip", "#{analysis_dir}")

  # Find any custom worker files -- should we just call these via system ruby? Then we could have any gem that is installed (not bundled)
  files = Dir["#{analysis_dir}/lib/worker_#{options[:state]}/*.rb"].map { |n| File.basename(n) }.sort
  logger.info "The following custom worker #{options[:state]} files were found #{files}"
  files.each do |f|
    f_fullpath = "#{analysis_dir}/lib/worker_#{options[:state]}/#{f}"
    f_argspath = "#{File.dirname(f_fullpath)}/#{File.basename(f_fullpath, '.*')}.args"
    logger.info "Running #{options[:state]} script #{f_fullpath}"

    # Each worker script has a very specific format and should be loaded and run as a class
    require f_fullpath

    # Remove the digits that specify the order and then create the class name
    klass_name = File.basename(f, '.*').gsub(/^\d*_/, '').split('_').map(&:capitalize).join

    # instantiate a class
    klass = Object.const_get(klass_name).new

    # check if there is an argument json that accompanies the class
    args = nil
    logger.info "Looking for argument file #{f_argspath}"
    if File.exist?(f_argspath)
      logger.info "argument file exists #{f_argspath}"
      args = eval(File.read(f_argspath))
      logger.info "arguments are #{args}"
    end

    r = klass.run(*args)
    logger.info "Script returned with #{r}"

    klass.finalize if klass.respond_to? :finalize
  end

  result = true
rescue => e
  log_message = "#{__FILE__} failed with #{e.message}, #{e.backtrace.join("\n")}"
  puts log_message
  logger.info log_message if logger
ensure
  logger.info "Finished #{__FILE__}" if logger
  logger.close if logger

  # always print out the state at the end
  puts result # as a string? (for R to parse correctly?)
end
