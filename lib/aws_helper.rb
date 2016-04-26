class AwsHelper
  require 'aws_helper/constants.rb'
  require 'aws_helper/client.rb'
  require 'base64'
  require 'net/http'
  require 'logger'

  def initialize(options={})
    @@client = AwsHelper::Client.new(options)
    @@logger = Logger.new(STDOUT)
    # FIXME: NoMethodError: undefined method `level=' for "method":String
    # @@logger = defined?(Rails.logger) || Logger.new(STDOUT)
    # @@logger.level = ENV['LOG_LEVEL'] ?  Logger.const_get(ENV['LOG_LEVEL'].upcase) : Logger::WARN
  end

  def self.get_self_instance_id
    begin
      http = Net::HTTP.new(METADATA_URI.host, METADATA_URI.port)
      http.open_timeout = 1
      http.read_timeout = 1
      http.get("#{METADATA_URI.path}/instance-id").body
    rescue Net::OpenTimeout, Errno::ENETUNREACH
      "NOT_AN_EC2_INSTANCE"
    end
  end

  def reboot_instances
    target_instances, target_names = get_running_worker_instances
    wait_instance_count = (target_names.count*REBOOT_WAIT_COUNT_PCT).ceil

    @@logger.info {"Found [#{target_names.count}] [#{RAILS_ENV}] instance(s) of [#{PROJECT_TAG}] to reboot."}

    if target_names.count == 0
      @@logger.warn {"No target instances found."}
      return 1, 0
    elsif target_names.count == 1
      add_instances(1)
      @@logger.debug {"Added one new instance. Sleeping for #{INSTANCE_STARTUP_TIME}s before rebooting existing instance."}
      verbose_sleep(INSTANCE_STARTUP_TIME)
    else
      @@logger.info {"Waiting for [#{wait_instance_count}] instance(s) to reboot before rebooting the remainder without delay."}
    end

    i = 0
    target_instances.each do |instance|
      unless target_names.include?(instance.id)
        @@logger.info {"Skipped young #{instance.id} (#{instance.tags['Name']},#{instance.private_ip_address})."}
        next
      end

      if wait_instance_count > i
        @@logger.info {"Stopping #{instance.id} (#{instance.tags['Name']},#{instance.private_ip_address})."}
        if instance_stop_and_wait(instance, REBOOT_TIMEOUT)
          @@logger.error {"Timed-out waiting for #{instance.id} to stop."}
          return 2, i
        end

        @@logger.info  {"Starting #{instance.id}."}
        if instance_start_and_wait(instance, REBOOT_TIMEOUT)
          @@logger.error {"Timed-out waiting for #{instance.id} to start."}
          return 3, i
        else
          @@logger.debug {"State of #{instance.id} changed to running."}
        end
      else
        @@logger.info {"Rebooting #{instance.id} (#{instance.tags['Name']},#{instance.private_ip_address})."}
        instance.reboot
      end
      i += 1
    end

    return 0, i-1
  end

  def get_leader_instance_id
    instances, _ = get_running_worker_instances
    instances.map(&:id).sort[0]
  end

  def add_instances(num)
    asg = get_active_auto_scaling_group

    if asg.nil?
      @@logger.error "Could not find an autoscale group name starting with [#{CONFIG_NAME_BASE}]."
      return 0
    end

    if asg.desired_capacity == WORKER_INSTANCE_LIMIT
      @@logger.error "Limit of #{WORKER_INSTANCE_LIMIT} instances reached; not scaling-up."
      return WORKER_INSTANCE_LIMIT
    end

    new_capacity = asg.desired_capacity + num
    if new_capacity > WORKER_INSTANCE_LIMIT
      @@logger.warn "Desired capacity of #{new_capacity} limited to #{WORKER_INSTANCE_LIMIT}."
      new_capacity = WORKER_INSTANCE_LIMIT
    end

    @@logger.info "Setting desired capacity of #{asg.auto_scaling_group_name} to #{new_capacity} instances."

    @@client.autoscale.set_desired_capacity(
      auto_scaling_group_name: asg.auto_scaling_group_name,
      desired_capacity: new_capacity
    )

    return new_capacity
  end

  def create_autoscale_group(ami_id)
    launch_configuration_name = create_launch_configuration(ami_id)
    autoscale_group_name = get_available_scaling_group_name

    @@client.autoscale.create_auto_scaling_group ({
      auto_scaling_group_name: autoscale_group_name,
      launch_configuration_name: launch_configuration_name,
      min_size: 1,
      desired_capacity: 1,
      max_size: WORKER_INSTANCE_LIMIT,
      health_check_grace_period: 300,
      # It's not worth automating these options until we need larger scale.
      # When we require need another region, I would start with a simple map of
      # values for each region; e.g.:
      # availability_zones = AWS_CONFIG[ENV['DEPLOY_AWS_REGION']].availability_zones
      # vpc_zone_identifier = AWS_CONFIG[ENV['DEPLOY_AWS_REGION']].vpc_zone_identifier
      availability_zones: ['us-east-1d'],
      vpc_zone_identifier: 'subnet-7486405f',
      tags: [{ key: 'Name', value: "tagtrue-#{RAILS_ENV}-autoscale", propagate_at_launch: true },
             { key: 'environment', value: RAILS_ENV, propagate_at_launch: true },
             { key: 'project', value: 'tagtrue', propagate_at_launch: true }]
    })

    configure_autoscale_policies(autoscale_group_name)

    return autoscale_group_name
  end

  def set_instance_userdata(id, data)
    instance = @@client.ec2.instances[id]
    if instance.exists?
      instance_stop_and_wait(instance)
      instance.user_data = data
    else
      @@logger.warn "Instance #{id} not found; user data not set."
      return false
    end
  end

  def create_tagtrue_image(instance_id, version)
    i = @@client.ec2.instances[instance_id]
    ami = i.create_image(get_available_ami_name(version),
                         description: 'Ubuntu 15.10')
    ami.add_tag('version', value: version)
    ami.add_tag('created_at', value: DateTime.now.iso8601)

    return ami
  end

  def cleanup_autoscale_groups(keep_asg_name)
    delete_candidates, desired_capacity = get_autoscale_delete_candidates(keep_asg_name)
    @@logger.debug("cleanup_autoscale_groups Selected #{delete_candidates.count} auto scaling groups with total capacity #{desired_capacity}")

    keep_sg =  @@client.autoscale.describe_auto_scaling_groups({
      auto_scaling_group_names: [keep_asg_name], max_records: 1
      }).auto_scaling_groups[0]

    # Keep group must have the capacity we're about to remove
    if desired_capacity - keep_sg.desired_capacity > 0
      if desired_capacity > keep_sg.max_size
        @@logger.warn("cleanup_autoscale_groups Desired capacity for #{keep_asg_name} is #{desired_capacity} but maximum size is #{keep_sg.max_size}")
        desired_capacity = keep_sg.max_size
      end

      @@client.autoscale.update_auto_scaling_group({
        auto_scaling_group_name: keep_asg_name,
        desired_capacity: desired_capacity
        })
      @@logger.info("cleanup_autoscale_groups Desired capacity for #{keep_asg_name} set to #{desired_capacity}")
    end

    # Wait for new instances to start-up in keep group
    do_cleanup_autoscale_capacity_wait(keep_asg_name)

    # Avoid the existing instances to detach and keep running
    delete_candidates.each do |sg|
      @@client.autoscale.update_auto_scaling_group({
        auto_scaling_group_name: sg.auto_scaling_group_name,
        min_size: 0,
        max_size: 0,
        desired_capacity: 0
        }
      )

      if (Time.now - sg.created_time).to_i/86400 <= AWS_OBJECT_CLEANUP_AGE
        @@logger.debug {"cleanup_autoscale_groups Skipped #{sg.auto_scaling_group_name} (too young)."}
        next
      else
        @@client.autoscale.delete_auto_scaling_group({
          auto_scaling_group_name: sg.auto_scaling_group_name,
          force_delete: true
          }
        )
        @@logger.info {"cleanup_autoscale_groups Deleted #{sg.auto_scaling_group_name}."}
      end
    end
  end

  def get_running_worker_instances
    all_running_instances = @@client.ec2.instances.filter('instance-state-name', 'running')
    running_worker_instances = all_running_instances.with_tag('project', PROJECT_TAG).with_tag('environment', RAILS_ENV)
    instance_names = running_worker_instances.map(&:id)

    return running_worker_instances, instance_names
  end

  def cleanup_launch_configurations
    delete_list = []
    busy_lc = get_busy_launch_configurations
    next_token = :start
    while next_token
      options = next_token.eql?(:start) ? {} : { next_token: next_token}
      resp = @@client.autoscale.describe_launch_configurations(options)
      configurations = resp.launch_configurations

      configurations.each do |lc|
        if busy_lc.include?(lc.launch_configuration_name)
          @@logger.debug {"cleanup_launch_configurations Skipped #{lc.launch_configuration_name} (in use)."}
          next
        end

        if (Time.now - lc.created_time).to_i/86400 > AWS_OBJECT_CLEANUP_AGE
          delete_list << lc.launch_configuration_name
          @@logger.debug {"cleanup_launch_configurations Marked #{lc.launch_configuration_name} for deletion."}
        else
          @@logger.debug {"cleanup_launch_configurations Skipped #{lc.launch_configuration_name} (too young)."}
        end
      end

      next_token = resp[:next_token]
    end

    delete_list.each do |lc_name|
      @@client.autoscale.delete_launch_configuration({ launch_configuration_name: lc_name })
      @@logger.info {"cleanup_launch_configurations Deleted #{lc_name}."}
    end
  end

  def cleanup_instances
    delete_candidates = @@client.ec2.instances.filter('instance-state-name', 'stopped').with_tag('project', PROJECT_TAG)
    delete_candidates.select{|i| (Time.now - i.launch_time).to_i/86400 > AWS_OBJECT_CLEANUP_AGE}.each do |i|
      i.terminate
      @@logger.info {"cleanup_instances Deleted instance #{i.instance_id} with launch time #{i.launch_time}"}
    end
  end

  def cleanup_amis
    busy_ami = get_busy_amis
    delete_candidates = @@client.real_ec2.describe_images({ owners: ['self', '453793470413']}).images_set
    delete_candidates.select{|ami| (Time.now - Time.parse(ami.creation_date)).to_i/86400 > AWS_OBJECT_CLEANUP_AGE}.each do |ami|
      if busy_ami.include?(ami.image_id)
        @@logger.debug {"cleanup_amis Skipped #{ami.image_id} (in use)."}
        next
      end

      if ami.name.start_with?(AMI_NAME_BASE)
        ami.deregister
        @@logger.info {"cleanup_amis Deleted #{ami.name} #{ami.image_id} #{ami.creation_date}."}
      else
        @@logger.debug {"cleanup_amis Skipped #{ami.name} #{ami.image_id} #{ami.creation_date} (name didn't match)."}
      end
    end
  end

  private
  def get_active_auto_scaling_group
    matched_asg = []
    next_token = :start
    while next_token
      options = next_token.eql?(:start) ? {} : { next_token: next_token}
      resp =  @@client.autoscale.describe_auto_scaling_groups(options)
      active_asg = resp.auto_scaling_groups.select{|asg| asg.desired_capacity > 0 }
      active_asg.each do |asg|
        if asg.tags.select {|h| h.key == 'environment' && h.value == RAILS_ENV}.count > 0
          matched_asg << asg
        end
      end
      next_token = resp[:next_token]
    end

    return matched_asg.sort_by{ |asg| asg.created_time }.reverse[0]
  end

  def get_busy_amis
    busy_ami = []

    next_token = :start
    while next_token
      options = next_token.eql?(:start) ? {} : { next_token: next_token}
      resp =  @@client.autoscale.describe_launch_configurations(options)
      busy_ami << resp.launch_configurations.map(&:image_id)
      next_token = resp[:next_token]
    end

    return busy_ami.flatten
  end

  def get_busy_launch_configurations
    busy_lc = []

    next_token = :start
    while next_token
      options = next_token.eql?(:start) ? {} : { next_token: next_token}
      asg =  @@client.autoscale.describe_auto_scaling_groups(options)
      busy_lc << asg.auto_scaling_groups.map(&:launch_configuration_name)
      next_token = asg[:next_token]
    end

    return busy_lc.flatten
  end

  def do_cleanup_autoscale_capacity_wait(keep_asg_name)
    keep_sg =  @@client.autoscale.describe_auto_scaling_groups({
      auto_scaling_group_names: [keep_asg_name], max_records: 1
      }).auto_scaling_groups[0]
    t = 0

    while keep_sg.instances.count < keep_sg.desired_capacity && t < AwsHelper::INSTANCE_STARTUP_TIME
      @@logger.info {"cleanup_autoscale_groups waited #{t}/#{AwsHelper::INSTANCE_STARTUP_TIME}s for #{keep_asg_name} instance count of #{keep_sg.instances.count} to reach #{keep_sg.desired_capacity}."}
      sleep 5
      t += 5
      keep_sg =  @@client.autoscale.describe_auto_scaling_groups({
        auto_scaling_group_names: [keep_asg_name], max_records: 1
        }).auto_scaling_groups[0]
    end

    while t < AwsHelper::INSTANCE_STARTUP_TIME
      @@logger.info {"cleanup_autoscale_groups waited #{t}/#{AwsHelper::INSTANCE_STARTUP_TIME}s for instances to be InService."}
      sleep 5
      t += 5
      keep_sg =  @@client.autoscale.describe_auto_scaling_groups({
        auto_scaling_group_names: [keep_asg_name], max_records: 1
        }).auto_scaling_groups[0]

      keep_sg.instances.each do |i|
        @@logger.debug {"cleanup_autoscale_groups Instance #{i.instance_id} State: #{i.lifecycle_state} Health: #{i.health_status}."}
        next if !'InService'.eql?(i.lifecycle_state)
      end

      break
    end
  end

  def get_autoscale_delete_candidates(keep_asg_name)
    r = @@client.autoscale.describe_auto_scaling_groups
    delete_candidates = []
    deleted_capacity = 0

    r.auto_scaling_groups.each do |sg|
      if sg.auto_scaling_group_name.eql?(keep_asg_name)
        @@logger.debug "Skipping auto scaling group #{sg.auto_scaling_group_name} with capacity #{sg.desired_capacity} (I was asked to keep it)"
        next
      end

      if sg.auto_scaling_group_name.start_with?(CONFIG_NAME_BASE)
        @@logger.debug "Marking auto scaling group #{sg.auto_scaling_group_name} with capacity #{sg.desired_capacity} for deletion (starts with #{CONFIG_NAME_BASE})"
        delete_candidates << sg
        deleted_capacity += sg.desired_capacity
      else
        @@logger.debug "Skipping auto scaling group #{sg.auto_scaling_group_name} with capacity #{sg.desired_capacity} (doesn't start with #{CONFIG_NAME_BASE})"
      end
    end

    delete_candidates.delete_if do |sg|
      match = sg.tags.select {|h| h.key == 'environment' && h.value == RAILS_ENV }
      if 0 == match.count
        @@logger.debug "Unmarking auto scaling group #{sg.auto_scaling_group_name} with capacity #{sg.desired_capacity} for deletion (missing tag 'environment=#{RAILS_ENV}')"
        deleted_capacity -= sg.desired_capacity
        true
      else
        false
      end
    end

    return delete_candidates, deleted_capacity
  end

  def get_available_ami_name(version)
    i = 1
    ami_name = "#{AMI_NAME_BASE}#{version}_#{i}"
    ic = @@client.ec2.images.filter('name', ami_name)
    until 0 == ic.count
      i += 1
      ami_name = "#{AMI_NAME_BASE}#{version}_#{i}"
      ic = @@client.ec2.images.filter('name', ami_name)
    end

    return ami_name
  end

  # v2 of aws-sdk has built-in wait states but v1 doesn't :(
  def instance_stop_and_wait(instance, timeout=REBOOT_TIMEOUT)
    instance.stop

    j = 0
    until instance.status == :stopped || j > timeout
      sleep(1)
      j += 1
    end

    return j > timeout
  end

  def instance_start_and_wait(instance, timeout=REBOOT_TIMEOUT)
    instance.start

    j = 0
    until instance.status == :running || j > timeout
      sleep(1)
      j += 1
    end

    return j > timeout
  end

  def create_launch_configuration(ami_id)
    launch_configuration_name = get_available_launch_configuration_name

    @@client.autoscale.create_launch_configuration({
      launch_configuration_name: launch_configuration_name,
      key_name: 'id_lens10',
      security_groups: ['sg-57142f2e'],
      image_id: ami_id,
      instance_type: 't2.large',
      instance_monitoring: {
        enabled: false,
      },
      ebs_optimized: false,
      associate_public_ip_address: false,
      placement_tenancy: "default",
      user_data: Base64.encode64(RAILS_ENV)
    })

    return launch_configuration_name
  end

  def get_available_launch_configuration_name
    i = 1
    launch_configuration_name = "#{CONFIG_NAME_BASE}#{Date.today.iso8601}_#{i}"
    lc = @@client.autoscale.describe_launch_configurations({launch_configuration_names: [launch_configuration_name]})
    until 0 == lc.launch_configurations.count
      i += 1
      launch_configuration_name = "#{CONFIG_NAME_BASE}#{Date.today.iso8601}_#{i}"
      lc = @@client.autoscale.describe_launch_configurations({launch_configuration_names: [launch_configuration_name]})
    end

    return launch_configuration_name
  end

  def get_available_scaling_group_name
    i = 1
    scaling_group_name = "#{CONFIG_NAME_BASE}#{Date.today.iso8601}_#{i}"
    sg = @@client.autoscale.describe_auto_scaling_groups({auto_scaling_group_names: [scaling_group_name]})
    until 0 == sg.auto_scaling_groups.count
      i += 1
      scaling_group_name = "#{CONFIG_NAME_BASE}#{Date.today.iso8601}_#{i}"
      sg = @@client.autoscale.describe_auto_scaling_groups({auto_scaling_group_names: [scaling_group_name]})
    end

    return scaling_group_name
  end

  def configure_autoscale_policies(group_name)
    scale_up_arn = @@client.autoscale.put_scaling_policy({
      auto_scaling_group_name: group_name,
      policy_name: "#{CONFIG_NAME_BASE}_scale_up_policy",
      scaling_adjustment: 3,
      adjustment_type: "ChangeInCapacity",
      cooldown: 60
    })[:policy_arn]

    scale_down_arn = @@client.autoscale.put_scaling_policy({
      auto_scaling_group_name: group_name,
      policy_name: "#{CONFIG_NAME_BASE}_scale_down_policy",
      scaling_adjustment: -2,
      adjustment_type: "ChangeInCapacity",
      cooldown: 60
    })[:policy_arn]

    @@client.cloudwatch.put_metric_alarm({
      :alarm_name => "#{CONFIG_NAME_BASE}_scale_up_policy_alarm",
      :actions_enabled => true,
      :alarm_actions => [scale_up_arn],
      :metric_name => "CPUUtilization",
      :namespace => "AWS/EC2",
      :statistic => "Average",
      :dimensions => [{:name => "AutoScalingGroupName",:value => group_name}],
      :evaluation_periods=>2,
      :period=>300,
      :threshold=>50.0,
      :comparison_operator=>"GreaterThanOrEqualToThreshold"
    })

    @@client.cloudwatch.put_metric_alarm({
      :alarm_name => "#{CONFIG_NAME_BASE}_scale_down_policy_alarm",
      :actions_enabled => true,
      :alarm_actions => [scale_down_arn],
      :metric_name => "CPUUtilization",
      :namespace => "AWS/EC2",
      :statistic => "Average",
      :dimensions => [{:name => "AutoScalingGroupName",:value => group_name}],
      :period=>300,
      :evaluation_periods=>1,
      :threshold=>20.0,
      :comparison_operator=>"LessThanOrEqualToThreshold"
    })
  end

  def verbose_sleep(seconds)
    if STDOUT.isatty
      for i in 0..INSTANCE_STARTUP_TIME
        print "\r#{i}..."
        sleep 1
      end
    else
      sleep INSTANCE_STARTUP_TIME
    end
  end

end
