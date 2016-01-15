class Analysis::LocalRunner
  include Analysis::Core

  def initialize(analysis_id, analysis_job_id, options = {})
    defaults = {
      skip_init: false,
      data_points: [],
      run_data_point_filename: 'run_openstudio.rb',
      problem: {}
    }.with_indifferent_access # make sure to set this because the params object from rails is indifferential
    @options = defaults.deep_merge(options)

    @analysis_id = analysis_id
    @analysis_job_id = analysis_job_id
  end

  # Perform is the main method that is run in the background.  At the moment if this method crashes
  # it will be logged as a failed delayed_job and will fail after max_attempts.
  def perform
    @analysis = Analysis.find(@analysis_id)

    # get the analysis and report that it is running
    @analysis_job = Analysis::Core.initialize_analysis_job(@analysis, @analysis_job_id, @options)

    # reload the object (which is required) because the subdocuments (jobs) may have changed
    @analysis.reload

    # get the master ip address
    master_ip = ComputeNode.where(node_type: 'server').first.ip_address
    #TODO Hook up the ComputeNode analysis_path field to an initializer
    #analysis_path = ComputeNode.where(node_type: 'server').first.analysis_path
    Rails.logger.info("computenode analysis_path: #{ComputeNode.where(node_type: 'server').first.root_path}")
    analysis_path = "C:/Projects/PAT20/analysis"
    server_path = "C:/Projects/PAT20/server"
    worker_nodes_path = "C:/Projects/PAT20/worker-nodes"
    debug_flag = true
    Rails.logger.info("Master ip: #{master_ip}")
    Rails.logger.info('Starting Local Runner')
    Rails.logger.info("options: #{@options}")

    Rails.logger.info "Variables: #{Variable.variables(@analysis.id)}"
    
    selected_variables = Variable.variables(@analysis.id)
    Rails.logger.info "Found #{selected_variables.count} variables"
    selected_variables.each do |var|
        Rails.logger.info "name: #{var.measure.name}; id: #{var.measure.id}"
    end
    samples = []
    
    # Make baseline case
    instance = {}
    selected_variables.each do |variable|
      instance["#{variable.id}".to_sym] = variable.static_value
    end
    samples << instance
    
    # Add the static value data point to the database
    isample = 0
    samples.uniq.each do |sample| # do this in parallel
      isample += 1
      dp_name = "Autogenerated #{isample}"
      dp = @analysis.data_points.new(name: dp_name)
      dp.set_variable_values = sample
      dp.save!

      Rails.logger.info("Generated data point #{dp.name} for analysis #{@analysis.name}")
    end
    
    # Quick preflight check that MongoDB, and Rails are working as expected. Checks to make sure
    # that the run flag is true.
    if @options[:data_points].empty?
      Rails.logger.info 'No data points were passed into the options, therefore checking which data points to run'
      @analysis.data_points.where(status: 'na', download_status: 'na').only(:status, :download_status, :uuid).each do |dp|
        Rails.logger.info "Adding in #{dp.uuid}"
        dp.status = 'queued'
        dp.save!
        @options[:data_points] << dp.uuid
      end
    end

    # Initialize some variables that are in the rescue/ensure blocks
    process = nil
    begin

      Rails.logger.info "Rails.root:#{Rails.root}"
      Rails.logger.info "Rails.env=#{Rails.env}"
      
      Rails.logger.info "RUBY_BIN_DIR:#{RUBY_BIN_DIR}"
      Rails.logger.info "setting analysis_path:#{analysis_path}"
      #check if analysis directory exists, if not make it
      FileUtils.mkdir_p "#{analysis_path}" unless Dir.exist? "#{analysis_path}"
      Rails.logger.info "making analysis_dir:#{analysis_path}/analysis_#{@analysis_id}"
      #make analysis_uuid directory
      FileUtils.mkdir_p "#{analysis_path}/analysis_#{@analysis_id}" unless Dir.exist? "#{analysis_path}/analysis_#{@analysis_id}"

      #copy over rails-models and mongoid.yml
      if Dir.exist? "#{worker_nodes_path}/rails-models/models"
        Rails.logger.info "deleting #{worker_nodes_path}/rails-models/models"
        FileUtils.remove_dir("#{worker_nodes_path}/rails-models/models")
      end  
      Rails.logger.info "copying #{server_path}/app/models/ to #{worker_nodes_path}/rails-models/models"
      FileUtils.cp_r("#{server_path}/app/models/", "#{worker_nodes_path}/rails-models/models")
      Rails.logger.info "copying #{server_path}/config/initializers/inflections.rb to #{worker_nodes_path}/rails-models/models"
      FileUtils.cp_r("#{server_path}/config/initializers/inflections.rb", "#{worker_nodes_path}/rails-models/models")
      Rails.logger.info "copying #{worker_nodes_path}/rails-models/mongoid-local-runner.yml to #{worker_nodes_path}/rails-models/mongoid.yml"
      FileUtils.cp_r("#{worker_nodes_path}/rails-models/mongoid-local-runner.yml","#{worker_nodes_path}/rails-models/mongoid.yml")
      
      if debug_flag 
        string_to_exec = "cd #{analysis_path}/analysis_#{@analysis_id}"
        `#{string_to_exec}`
        string_to_exec = "\"#{RUBY_BIN_DIR}/bundle\" show"
        output = `#{string_to_exec}`
        Rails.logger.info "bundle show: #{output}" 
        output = `ruby -v`
        Rails.logger.info "Ruby -v: #{output}" 
        output = `cd \"#{RUBY_BIN_DIR}\" && ruby -v`
        Rails.logger.info "#{RUBY_BIN_DIR}/Ruby -v: #{output}"
      end
      string_to_exec = "cd #{analysis_path}/analysis_#{@analysis_id} && \"#{RUBY_BIN_DIR}/bundle\" exec \"#{RUBY_BIN_DIR}/ruby\" #{worker_nodes_path}/local_init_final.rb -r #{analysis_path} -s initialize -a #{@analysis.id}"
      Rails.logger.info "Attempting to exec string: \n #{string_to_exec}"
      output = `#{string_to_exec}`
      Rails.logger.info "LocalWorkerInit: #{output}" 

      @options[:data_points].each do |dpuuid|
        string_to_exec =  "cd #{analysis_path}/analysis_#{@analysis_id} && \"#{RUBY_BIN_DIR}/bundle\" exec \"#{RUBY_BIN_DIR}/ruby\" #{worker_nodes_path}/local_simulate_data_point.rb -a #{@analysis.id} -u #{dpuuid} -x #{@options[:run_data_point_filename]} -r #{analysis_path} -w #{worker_nodes_path}"
        Rails.logger.info "Attempting to exec string: \n #{string_to_exec}"
        output = `#{string_to_exec}`
        Rails.logger.info "LocalSimulateDatapoint: #{output}" 
        Rails.logger.info "Ran datapoint #{dpuuid}"
        Rails.logger.info "Copy datapoint files and save datapoint: #{dpuuid}"
        @analysis.data_points.where(uuid: dpuuid).each do |dp|
          filepath1 = "#{analysis_path}/analysis_#{@analysis_id}/data_point_#{dp.id}/data_point_#{dp.id}.zip"
          filepath2 = "#{analysis_path}/analysis_#{@analysis_id}/data_point_#{dp.id}.zip"
          if ((!File.exist? filepath2) && (File.exist? filepath1))
            Rails.logger.info "copying #{filepath1} to #{filepath2}"
            FileUtils.cp_r(filepath1, filepath2)
            FileUtils.rm(filepath1)
          else
            Rails.logger.info "NOT copying #{filepath1} to #{filepath2} already exists"
          end  
          filepath1 = "#{analysis_path}/analysis_#{@analysis_id}/data_point_#{dp.id}/data_point_#{dp.id}_reports.zip"
          filepath2 = "#{analysis_path}/analysis_#{@analysis_id}/data_point_#{dp.id}_reports.zip"
          if ((!File.exist? filepath2) && (File.exist? filepath1))
            Rails.logger.info "copying #{filepath1} to #{filepath2}"
            FileUtils.cp_r(filepath1, filepath2)
            FileUtils.rm(filepath1)
          else
            Rails.logger.info "NOT copying #{filepath1} to #{filepath2}"
          end 
          dp.openstudio_datapoint_file_name = "#{analysis_path}/analysis_#{@analysis_id}/data_point_#{dp.id}.zip"
          dp.finalize_data_point
          dp.download_status = 'completed'
          dp.save!
        end
      end
      if debug_flag
        #create downloads dir for testing
        Rails.logger.info "creating #{analysis_path}/analysis_#{@analysis_id}/downloads"
        FileUtils.mkdir_p("#{analysis_path}/analysis_#{@analysis_id}/downloads") unless Dir.exist? "#{analysis_path}/analysis_#{@analysis_id}/downloads"
        FileUtils.chmod(0666,"#{analysis_path}/analysis_#{@analysis_id}/downloads")
        Rails.logger.info "copying test file"
        FileUtils.cp_r("#{analysis_path}/analysis_#{@analysis_id}/analysis.zip", "#{analysis_path}/analysis_#{@analysis_id}/downloads/analysis.zip")
        FileUtils.chmod(0666,"#{analysis_path}/analysis_#{@analysis_id}/downloads/analysis.zip")
      end
    rescue => e
      log_message = "#{__FILE__} failed with #{e.message}, #{e.backtrace.join("\n")}"
      Rails.logger.error log_message
      @analysis.status_message = log_message
      @analysis.save!
    ensure
      # ensure that the cluster is stopped
      #cluster.stop if cluster

      # Kill the downloading of data files process
      Rails.logger.info('Ensure block of analysis cleaning up any remaining processes')
      #process.stop if process
    end

    Rails.logger.info 'Running finalize worker scripts'
    # unless cluster.finalize_workers(worker_ips, @analysis.id)
    #   fail 'could not run finalize worker scripts'
    # end
    # Do one last check if there are any data points that were not downloaded
    begin
      # in large analyses it appears that this is timing out or just not running to completion.
      Rails.logger.info('Trying to download any remaining files from worker nodes')
      @analysis.finalize_data_points
    rescue => e
      log_message = "#{__FILE__} failed with #{e.message}, #{e.backtrace.join("\n")}"
      Rails.logger.error log_message
      @analysis.status_message += log_message
      @analysis.save!
    ensure
      # Only set this data if the analysis was NOT called from another analysis
      unless @options[:skip_init]
        @analysis_job.end_time = Time.now
        @analysis_job.status = 'completed'
        @analysis_job.save!
        @analysis.reload
      end
      @analysis.save!

      Rails.logger.info "Finished running analysis '#{self.class.name}'"
    end
  end

  # Since this is a delayed job, if it crashes it will typically try multiple times.
  # Fix this to 1 retry for now.
  def max_attempts
    1
  end
end
