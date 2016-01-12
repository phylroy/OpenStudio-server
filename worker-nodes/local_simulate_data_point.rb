# Command line based interface to execute the Workflow manager.

require 'bundler'
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
require 'openstudio-workflow'

puts "Parsing Input: #{ARGV}"

# parse arguments with optparse
options = {}
optparse = OptionParser.new do |opts|
  opts.on('-a', '--analysis_id UUID', String, 'UUID of the analysis.') do |analysis_id|
    options[:analysis_id] = analysis_id
  end

  options[:uuid] = 'NA'
  opts.on('-u', '--uuid UUID', String, 'UUID of the data point to run with no braces.') do |s|
    options[:uuid] = s
  end

  options[:run_workflow_method] = 'workflow'
  opts.on('-x', '--execute-file NAME', String, 'Type of the workflow the run will execute') do |s|
    options[:run_workflow_method] = s
  end

  opts.on('-r' '--root_path path', String, 'Root path for analysis run') do |root_path|
    options[:root_path] = root_path
  end
end
optparse.parse!

puts "Parsed Input: #{optparse}"

puts 'Checking Arguments'
unless options[:uuid]
  # required argument is missing
  puts optparse
  exit
end

if options[:root_path]
  analysis_root = options[:root_path]
else
  puts "Assuming analysis_root to be '\mnt\openstudio'"
  analysis_root = '\mnt\openstudio'
end

# Set the result of the project for R to know that this finished
result = nil

begin
  directory = nil
  fail 'Data Point is NA... skipping' if options[:uuid] == 'NA'
  #TODO Fix paths
  analysis_dir = "#{options[:root_path]}/analysis_#{options[:analysis_id]}"

  # use /run/shm on AWS (if possible)
  directory = analysis_dir

  # Logger for the simulate datapoint
  logger = Logger.new("#{directory}/#{options[:uuid]}.log")

  logger.info "Analysis Root Directory is #{analysis_dir}"
  logger.info "Simulation Run Directory is #{directory}"
  logger.info "Run datapoint type/file is #{options[:run_workflow_method]}"

  # TODO: program the various paths based on the run_type

  # Set the default workflow options
  #TODO Pass in path as argv
  workflow_options = {
    datapoint_id: options[:uuid],
    analysis_root_path: analysis_dir,
    adapter_options: {
      mongoid_path: "#{options[:root_path]}/rails-models"
    }
  }
  if options[:run_workflow_method] == 'custom_xml' ||
     options[:run_workflow_method] == 'run_openstudio_xml.rb'

    # Set up the custom workflow states and transitions
    transitions = OpenStudio::Workflow::Run.default_transition
    transitions[1][:to] = :xml
    transitions.insert(2, from: :xml, to: :openstudio)
    states = OpenStudio::Workflow::Run.default_states
    states.insert(2, state: :xml, options: { after_enter: :run_xml })

    workflow_options = {
      transitions: transitions,
      states: states,
      analysis_root_path: analysis_dir,
      datapoint_id: options[:uuid],
      xml_library_file: "#{analysis_dir}/lib/openstudio_xml/main.rb",
      adapter_options: {
          mongoid_path: "#{options[:root_path]}/rails-models"
      }
    }
  elsif options[:run_workflow_method] == 'pat_workflow' ||
        options[:run_workflow_method] == 'run_openstudio.rb'
    workflow_options = {
      is_pat: true,
      datapoint_id: options[:uuid],
      analysis_root_path: analysis_dir,
      adapter_options: {
          mongoid_path: "#{options[:root_path]}/rails-models"
      }
    }
  end

  logger.info 'Creating Workflow Manager instance'
  k = OpenStudio::Workflow.load 'Mongo', directory, workflow_options
  logger.info "Running workflow with #{options}"
  k.run
  logger.info "Final run state is #{k.final_state}"

  # TODO: get the last results out --- result = result.split("\n").last if result

  # check if the simulation failed after moving the files back to the right place
  if result == 'NA'
    logger.info 'Simulation result was invalid'
    fail 'Simulation result was invalid'
  end
rescue => e
  log_message = "#{__FILE__} failed with #{e.message}, #{e.backtrace.join("\n")}"
  puts log_message
  logger.info log_message if logger
ensure
  logger.info "Finished #{__FILE__}" if logger
  logger.close if logger
  # always print the objective function result or NA
  puts result
end
