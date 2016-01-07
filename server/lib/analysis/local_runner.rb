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

    # At this point we should really setup the JSON that can be sent to the worker nodes with everything it needs
    # This would allow us to easily replace the queuing system with rabbit or any other json based versions.

    # get the master ip address
    master_ip = ComputeNode.where(node_type: 'server').first.ip_address
    #TODO Hook up the ComputeNode root_path field to an initializer
    #root_path = ComputeNode.where(node_type: 'server').first.root_path
    root_path = "C:/Projects/PAT20/analysis"
    worker_nodes_path = "C:/Projects/PAT20/worker-nodes"
    Rails.logger.info("Master ip: #{master_ip}")
    Rails.logger.info('Starting Local Runner')

    # Quick preflight check that R, MongoDB, and Rails are working as expected. Checks to make sure
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

      # Before kicking off the Analysis, make sure to setup the downloading of the files child process
      #process = Analysis::Core::BackgroundTasks.start_child_processes

      `cd #{root_path} && bundle exec ruby #{worker_nodes_path}/local_init_final.rb -r #{root_path} -s initialize -a #{@analysis.id}`

      @options[:data_points].each do |dp|
        #TODO Fix which ruby to shipped openstudio ruby
        string_to_exec = "cd #{root_path} && bundle exec ruby #{root_path}/local_simulate_data_point.rb -a #{@analysis.id} -u #{dp} -x #{@options[:run_data_point_filename]}"
        Rails.logger.info "Attempting to exec string: \n #{string_to}"
        `#{string_to_exec}`
        Rails.logger.info "Ran datapoint #{dp}"
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
